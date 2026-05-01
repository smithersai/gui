const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const poll_interval_ms: i64 = 500;

pub const ProcessInfo = struct {
    allocator: Allocator,
    pid: posix.pid_t,
    comm: []u8,
    argv: [][]u8,

    pub fn deinit(self: *ProcessInfo) void {
        self.allocator.free(self.comm);
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        self.* = undefined;
    }
};

pub const Tracker = struct {
    shell_pid: posix.pid_t,
    last_pgid: ?posix.pid_t = null,

    pub fn init(shell_pid: posix.pid_t) Tracker {
        return .{ .shell_pid = shell_pid };
    }

    pub fn shouldEmitForPgid(self: *Tracker, pgid: posix.pid_t) bool {
        if (pgid <= 0) return false;
        if (self.last_pgid) |last| {
            if (last == pgid) return false;
        }
        self.last_pgid = pgid;
        return pgid != self.shell_pid;
    }

    pub fn poll(self: *Tracker, allocator: Allocator, master_fd: posix.fd_t) !?ProcessInfo {
        const pgid = terminalForegroundPgrp(master_fd) catch |err| switch (err) {
            error.NotATerminal => return null,
            else => return err,
        };
        if (!self.shouldEmitForPgid(pgid)) return null;
        return try resolveProcessInfo(allocator, pgid);
    }
};

pub fn resolveProcessInfo(allocator: Allocator, pid: posix.pid_t) !ProcessInfo {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => try resolveDarwinProcessInfo(allocator, pid),
        else => try resolveFallbackProcessInfo(allocator, pid),
    };
}

fn resolveDarwinProcessInfo(allocator: Allocator, pid: posix.pid_t) !ProcessInfo {
    var path_buffer: [4 * std.posix.PATH_MAX]u8 = undefined;
    const path = procPath(pid, &path_buffer);
    const argv = try procArgsDarwin(allocator, pid, path);
    errdefer freeArgv(allocator, argv);

    const comm_source = if (path.len > 0)
        path
    else if (argv.len > 0)
        argv[0]
    else
        "";
    const comm = if (comm_source.len > 0)
        try allocator.dupe(u8, std.fs.path.basename(comm_source))
    else
        try std.fmt.allocPrint(allocator, "pid-{d}", .{pid});
    errdefer allocator.free(comm);

    return .{
        .allocator = allocator,
        .pid = pid,
        .comm = comm,
        .argv = argv,
    };
}

fn resolveFallbackProcessInfo(allocator: Allocator, pid: posix.pid_t) !ProcessInfo {
    const comm = try std.fmt.allocPrint(allocator, "pid-{d}", .{pid});
    errdefer allocator.free(comm);

    const argv = try allocator.alloc([]u8, 0);
    return .{
        .allocator = allocator,
        .pid = pid,
        .comm = comm,
        .argv = argv,
    };
}

fn procPath(pid: posix.pid_t, buffer: []u8) []const u8 {
    if (!builtin.os.tag.isDarwin()) return "";

    const rc = proc_pidpath(@intCast(pid), buffer.ptr, @intCast(buffer.len));
    if (rc <= 0) return "";

    const used: usize = @intCast(rc);
    const path_slice = buffer[0..used];
    const nul_index = std.mem.indexOfScalar(u8, path_slice, 0) orelse path_slice.len;
    return path_slice[0..nul_index];
}

fn procArgsDarwin(allocator: Allocator, pid: posix.pid_t, fallback_path: []const u8) ![][]u8 {
    var argmax: c_int = 0;
    var argmax_len: usize = @sizeOf(c_int);
    try posix.sysctl(&.{ ctl_kern, kern_argmax }, &argmax, &argmax_len, null, 0);
    if (argmax <= 0) return fallbackArgv(allocator, fallback_path);

    const buffer = try allocator.alloc(u8, @intCast(argmax));
    defer allocator.free(buffer);

    var procargs_len: usize = buffer.len;
    try posix.sysctl(
        &.{ ctl_kern, kern_procargs2, @as(c_int, @intCast(pid)) },
        buffer.ptr,
        &procargs_len,
        null,
        0,
    );

    return try parseProcArgsBuffer(allocator, buffer[0..procargs_len], fallback_path);
}

fn parseProcArgsBuffer(allocator: Allocator, buffer: []const u8, fallback_path: []const u8) ![][]u8 {
    if (buffer.len < @sizeOf(u32)) return fallbackArgv(allocator, fallback_path);

    const argc_u32 = std.mem.readInt(u32, buffer[0..@sizeOf(u32)], builtin.cpu.arch.endian());
    const argc = @as(usize, @intCast(argc_u32));
    if (argc == 0) return fallbackArgv(allocator, fallback_path);

    var offset: usize = @sizeOf(u32);
    while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
    while (offset < buffer.len and buffer[offset] == 0) : (offset += 1) {}

    var argv = std.ArrayList([]u8).empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    var remaining = argc;
    while (offset < buffer.len and remaining > 0) {
        const start = offset;
        while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
        if (offset == start) {
            while (offset < buffer.len and buffer[offset] == 0) : (offset += 1) {}
            continue;
        }

        try argv.append(allocator, try allocator.dupe(u8, buffer[start..offset]));
        remaining -= 1;

        while (offset < buffer.len and buffer[offset] == 0) : (offset += 1) {}
    }

    if (argv.items.len == 0) {
        argv.deinit(allocator);
        return fallbackArgv(allocator, fallback_path);
    }

    return try argv.toOwnedSlice(allocator);
}

fn fallbackArgv(allocator: Allocator, fallback_path: []const u8) ![][]u8 {
    if (fallback_path.len == 0) return allocator.alloc([]u8, 0);

    var argv = try allocator.alloc([]u8, 1);
    errdefer allocator.free(argv);
    argv[0] = try allocator.dupe(u8, fallback_path);
    return argv;
}

fn freeArgv(allocator: Allocator, argv: [][]u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

const ctl_kern: c_int = 1;
const kern_argmax: c_int = 8;
const kern_procargs2: c_int = 49;

extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
extern "c" fn tcgetpgrp(fd: c_int) c_int;

fn terminalForegroundPgrp(fd: posix.fd_t) posix.TermioGetPgrpError!posix.pid_t {
    while (true) {
        const rc = tcgetpgrp(fd);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => unreachable,
            .INVAL => unreachable,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

test "tracker deduplicates shell foreground and repeated pgids" {
    var tracker = Tracker.init(100);
    try std.testing.expect(!tracker.shouldEmitForPgid(100));
    try std.testing.expect(!tracker.shouldEmitForPgid(100));
    try std.testing.expect(tracker.shouldEmitForPgid(200));
    try std.testing.expect(!tracker.shouldEmitForPgid(200));
    try std.testing.expect(!tracker.shouldEmitForPgid(100));
    try std.testing.expect(tracker.shouldEmitForPgid(300));
}

test "parse proc args buffer extracts argv after exec path" {
    var buffer: [128]u8 = [_]u8{0} ** 128;
    std.mem.writeInt(u32, buffer[0..4], 3, builtin.cpu.arch.endian());

    var offset: usize = 4;
    @memcpy(buffer[offset .. offset + "/bin/zsh".len], "/bin/zsh");
    offset += "/bin/zsh".len + 1;
    buffer[offset] = 0;
    offset += 1;
    @memcpy(buffer[offset .. offset + "git".len], "git");
    offset += "git".len + 1;
    @memcpy(buffer[offset .. offset + "status".len], "status");
    offset += "status".len + 1;
    @memcpy(buffer[offset .. offset + "--short".len], "--short");
    offset += "--short".len + 1;

    const argv = try parseProcArgsBuffer(std.testing.allocator, buffer[0..offset], "/bin/zsh");
    defer freeArgv(std.testing.allocator, argv);

    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("status", argv[1]);
    try std.testing.expectEqualStrings("--short", argv[2]);
}
