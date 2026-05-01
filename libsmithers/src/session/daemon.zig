const std = @import("std");

const server_mod = @import("server.zig");

const default_idle_timeout_seconds: i64 = 60 * 60;

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

    try writePidFile(allocator);

    var server = try server_mod.Server.init(allocator, path, idle_timeout_seconds);
    defer server.deinit();
    try server.run();
}

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
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

fn printUsage() !void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buffer);
    try stderr.interface.writeAll(
        \\Usage: smithers-session-daemon [--socket PATH] [--idle-seconds SECONDS]
        \\
    );
    try stderr.interface.flush();
}

test "socket path falls back to smithers directory" {
    const path = try socketPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "smithers-sessions.sock") or
        std.mem.endsWith(u8, path, ".smithers/sessions.sock"));
}

test {
    std.testing.refAllDecls(@import("buffer.zig"));
    std.testing.refAllDecls(@import("fd_passing.zig"));
    std.testing.refAllDecls(@import("foreground.zig"));
    std.testing.refAllDecls(@import("native.zig"));
    std.testing.refAllDecls(@import("protocol.zig"));
    std.testing.refAllDecls(@import("pty.zig"));
    std.testing.refAllDecls(@import("server.zig"));
}
