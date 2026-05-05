const std = @import("std");
const builtin = @import("builtin");

const server_mod = @import("server.zig");

const default_idle_timeout_seconds: i64 = 60 * 60;
var shutdown_requested = std.atomic.Value(bool).init(false);

const StartLock = struct {
    file: std.fs.File,
    path: []u8,
    allocator: std.mem.Allocator,

    fn release(self: *StartLock) void {
        self.file.close();
        std.fs.deleteFileAbsolute(self.path) catch {};
        self.allocator.free(self.path);
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var idle_timeout_seconds = default_idle_timeout_seconds;
    var explicit_socket_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--socket")) {
            i += 1;
            if (i >= argv.len) return error.MissingSocketPath;
            explicit_socket_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--idle-seconds")) {
            i += 1;
            if (i >= argv.len) return error.MissingIdleSeconds;
            idle_timeout_seconds = try std.fmt.parseInt(i64, argv[i], 10);
        } else if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) {
            try printUsage();
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    const path = if (explicit_socket_path) |value|
        try allocator.dupe(u8, value)
    else
        try socketPath(allocator);
    defer allocator.free(path);

    var start_lock: ?StartLock = try acquireStartLock(allocator, path);
    defer if (start_lock) |*lock| lock.release();

    // If a server came up while we waited for the lock, this daemon instance
    // has nothing to do. Exiting successfully mirrors tmux's start-server
    // race behavior without unlinking another server's live socket.
    if (socketAcceptsConnection(path)) return;

    var server = try server_mod.Server.init(allocator, path, idle_timeout_seconds);
    if (start_lock) |*lock| {
        lock.release();
        start_lock = null;
    }
    try writePidFile(allocator);
    defer server.deinit();
    server.shutdown_probe = shutdownRequested;
    installShutdownHandlers();
    try server.run();
}

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("ZMUX_SOCKET")) |value| {
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    if (std.posix.getenv("SMITHERS_SESSION_SOCKET")) |value| {
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(allocator, &.{ xdg, "smithers-sessions.sock" });
    }
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ home, ".smithers", "sessions.sock" });
}

fn pidPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ home, ".smithers", "session-daemon.pid" });
}

fn writePidFile(allocator: std.mem.Allocator) !void {
    const path = try pidPath(allocator);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    const text = try std.fmt.allocPrint(allocator, "{}\n", .{std.c.getpid()});
    defer allocator.free(text);
    try file.writeAll(text);
}

fn acquireStartLock(allocator: std.mem.Allocator, socket_path: []const u8) !StartLock {
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{socket_path});
    errdefer allocator.free(lock_path);

    try ensureParent(lock_path);
    const file = try std.fs.createFileAbsolute(lock_path, .{
        .truncate = false,
        .mode = 0o600,
        .lock = .exclusive,
    });
    errdefer file.close();

    return .{
        .file = file,
        .path = lock_path,
        .allocator = allocator,
    };
}

fn ensureParent(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn socketAcceptsConnection(socket_path: []const u8) bool {
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return false;
    defer std.posix.close(fd);

    const address = std.net.Address.initUnix(socket_path) catch return false;
    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch return false;
    return true;
}

fn printUsage() !void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buffer);
    try stderr.interface.writeAll(
        \\Usage: zmuxd [--socket PATH] [--idle-seconds SECONDS]
        \\       smithers-session-daemon [--socket PATH] [--idle-seconds SECONDS]
        \\
    );
    try stderr.interface.flush();
}

fn shutdownRequested() bool {
    return shutdown_requested.load(.seq_cst);
}

fn shutdownSignalHandler(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn installShutdownHandlers() void {
    var act: std.posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&act), 0);
    act.handler = .{ .handler = shutdownSignalHandler };
    act.mask = std.mem.zeroes(std.posix.sigset_t);
    act.flags = 0;
    std.posix.sigaction(std.c.SIG.TERM, &act, null);
    std.posix.sigaction(std.c.SIG.INT, &act, null);
    std.posix.sigaction(std.c.SIG.HUP, &act, null);
}

test "socket path falls back to smithers directory" {
    const path = try socketPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "smithers-sessions.sock") or
        std.mem.endsWith(u8, path, ".smithers/sessions.sock"));
}

test "socketAcceptsConnection detects a listening unix socket" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/zmx-live-{x:0>16}.sock", .{nonce});
    defer std.testing.allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    const listener = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(listener);
    try std.posix.bind(listener, &address.any, address.getOsSockLen());
    try std.posix.listen(listener, 1);

    try std.testing.expect(socketAcceptsConnection(path));
}

test {
    std.testing.refAllDecls(@import("buffer.zig"));
    std.testing.refAllDecls(@import("foreground.zig"));
    std.testing.refAllDecls(@import("native.zig"));
    std.testing.refAllDecls(@import("protocol.zig"));
    std.testing.refAllDecls(@import("pty.zig"));
    std.testing.refAllDecls(@import("server.zig"));
}
