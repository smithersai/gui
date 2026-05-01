const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const CmsgLen = if (builtin.os.tag == .linux) usize else posix.socklen_t;

const Cmsghdr = extern struct {
    cmsg_len: CmsgLen,
    cmsg_level: c_int,
    cmsg_type: c_int,
};

pub const ReceivedFd = struct {
    fd: posix.fd_t,
    payload: []u8,

    pub fn deinit(self: ReceivedFd, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

pub fn sendJsonWithFd(socket_fd: posix.fd_t, fd: posix.fd_t, json_payload: []const u8) !void {
    try sendFd(socket_fd, fd, json_payload);
}

pub fn sendFd(socket_fd: posix.fd_t, fd: posix.fd_t, payload: []const u8) !void {
    var iov = [_]posix.iovec_const{.{
        .base = payload.ptr,
        .len = payload.len,
    }};

    var control: [cmsgSpace(@sizeOf(posix.fd_t))]u8 align(@alignOf(Cmsghdr)) = undefined;
    @memset(&control, 0);

    const header: *Cmsghdr = @ptrCast(@alignCast(&control[0]));
    header.* = .{
        .cmsg_len = @intCast(cmsgLen(@sizeOf(posix.fd_t))),
        .cmsg_level = solSocket(),
        .cmsg_type = scmRights(),
    };

    const data_offset = cmsgAlign(@sizeOf(Cmsghdr));
    const fd_ptr: *posix.fd_t = @ptrCast(@alignCast(&control[data_offset]));
    fd_ptr.* = fd;

    const msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = @intCast(iov.len),
        .control = &control,
        .controllen = @intCast(control.len),
        .flags = 0,
    };
    _ = try posix.sendmsg(socket_fd, &msg, 0);
}

pub fn recvFd(allocator: std.mem.Allocator, socket_fd: posix.fd_t, max_payload: usize) !ReceivedFd {
    const payload = try allocator.alloc(u8, max_payload);
    errdefer allocator.free(payload);

    var iov = [_]posix.iovec{.{
        .base = payload.ptr,
        .len = payload.len,
    }};

    var control: [cmsgSpace(@sizeOf(posix.fd_t))]u8 align(@alignOf(Cmsghdr)) = undefined;
    @memset(&control, 0);

    var msg: posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = @intCast(iov.len),
        .control = &control,
        .controllen = @intCast(control.len),
        .flags = 0,
    };

    const read_len = while (true) {
        const rc = posix.system.recvmsg(socket_fd, &msg, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => unreachable,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .NOTSOCK => return error.FileDescriptorNotASocket,
            else => |err| return posix.unexpectedErrno(err),
        }
    };

    const header: *const Cmsghdr = @ptrCast(@alignCast(&control[0]));
    if (@as(usize, @intCast(header.cmsg_len)) < cmsgLen(@sizeOf(posix.fd_t)) or
        header.cmsg_level != solSocket() or
        header.cmsg_type != scmRights())
    {
        return error.MissingFileDescriptor;
    }

    const data_offset = cmsgAlign(@sizeOf(Cmsghdr));
    const fd_ptr: *const posix.fd_t = @ptrCast(@alignCast(&control[data_offset]));
    const exact_payload = try allocator.dupe(u8, payload[0..read_len]);
    allocator.free(payload);
    return .{
        .fd = fd_ptr.*,
        .payload = exact_payload,
    };
}

fn cmsgAlign(len: usize) usize {
    const alignment = @sizeOf(CmsgLen);
    const mask: usize = alignment - 1;
    return (len + mask) & ~mask;
}

fn cmsgLen(comptime len: usize) usize {
    return cmsgAlign(@sizeOf(Cmsghdr)) + len;
}

fn cmsgSpace(comptime len: usize) usize {
    return cmsgAlign(@sizeOf(Cmsghdr)) + cmsgAlign(len);
}

fn solSocket() c_int {
    return switch (builtin.os.tag) {
        .linux => 1,
        .macos, .ios, .tvos, .watchos, .visionos => 0xffff,
        else => @compileError("SCM_RIGHTS is only implemented for Linux and Darwin targets"),
    };
}

fn scmRights() c_int {
    return 0x01;
}

test "SCM_RIGHTS sends and receives a file descriptor" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) return error.SkipZigTest;
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const file = try std.fs.cwd().openFile("build.zig", .{});
    defer file.close();

    try sendFd(sockets[0], file.handle, "{\"ok\":true}\n");
    const received = try recvFd(std.testing.allocator, sockets[1], 128);
    defer received.deinit(std.testing.allocator);
    defer posix.close(received.fd);

    try std.testing.expectEqualStrings("{\"ok\":true}\n", received.payload);

    var byte: [1]u8 = undefined;
    const n = try posix.read(received.fd, &byte);
    try std.testing.expect(n > 0);
}
