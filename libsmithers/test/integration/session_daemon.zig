const std = @import("std");
const builtin = @import("builtin");

const server_mod = @import("session_server");

const posix = std.posix;

const CmsgLen = if (builtin.os.tag == .linux) usize else posix.socklen_t;

const Cmsghdr = extern struct {
    cmsg_len: CmsgLen,
    cmsg_level: c_int,
    cmsg_type: c_int,
};

fn solSocket() c_int {
    return switch (builtin.os.tag) {
        .linux => 1,
        .macos, .ios, .tvos, .watchos, .visionos => 0xffff,
        else => @compileError("SCM_RIGHTS is only implemented for Linux and Darwin targets"),
    };
}

/// Recvmsg that captures both the attach response payload and the passed
/// PTY fd (if any), so the test doesn't leak the fd after verifying the
/// payload. Returns an allocated payload slice trimmed at the first newline.
fn recvAttachResponse(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    max_payload: usize,
) !struct { payload: []u8, pty_fd: ?posix.fd_t } {
    const buf = try allocator.alloc(u8, max_payload);
    errdefer allocator.free(buf);

    var iov = [_]posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var control: [64]u8 align(@alignOf(Cmsghdr)) = undefined;
    @memset(&control, 0);

    var msg: posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @intCast(control.len),
        .flags = 0,
    };

    const rc = posix.system.recvmsg(fd, &msg, 0);
    if (posix.errno(rc) != .SUCCESS) return error.RecvMsgFailed;
    const n: usize = @intCast(rc);
    if (n == 0) return error.EndOfStream;

    var pty_fd: ?posix.fd_t = null;
    if (msg.controllen >= @sizeOf(Cmsghdr)) {
        const header: *const Cmsghdr = @ptrCast(@alignCast(&control[0]));
        if (header.cmsg_level == solSocket() and header.cmsg_type == 0x01) {
            const data_offset = (@sizeOf(Cmsghdr) + @sizeOf(CmsgLen) - 1) & ~(@as(usize, @sizeOf(CmsgLen)) - 1);
            const fd_ptr: *const posix.fd_t = @ptrCast(@alignCast(&control[data_offset]));
            pty_fd = fd_ptr.*;
        }
    }

    const end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    const payload = try allocator.dupe(u8, buf[0..end]);
    allocator.free(buf);
    return .{ .payload = payload, .pty_fd = pty_fd };
}

fn tempSocketPath(allocator: std.mem.Allocator) ![]u8 {
    // Use the system tmp dir for the UNIX domain socket. sun_path has a
    // ~104 byte limit on Darwin, so we keep the path short.
    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    return std.fmt.allocPrint(allocator, "/tmp/smt-test-{x:0>16}.sock", .{nonce});
}

fn connectClient(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    const address = try std.net.Address.initUnix(path);
    try posix.connect(fd, &address.any, address.getOsSockLen());
    return fd;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try posix.write(fd, bytes[offset..]);
    }
}

fn readLineAlloc(allocator: std.mem.Allocator, fd: posix.fd_t, max_len: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var byte: [1]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &byte);
        if (n == 0) {
            if (out.items.len == 0) return error.EndOfStream;
            return try out.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') return try out.toOwnedSlice(allocator);
        try out.append(allocator, byte[0]);
        if (out.items.len > max_len) return error.ResponseTooLarge;
    }
}

fn waitForSocket(path: []const u8, timeout_ms: i64) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer posix.close(fd);
        const address = std.net.Address.initUnix(path) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        if (posix.connect(fd, &address.any, address.getOsSockLen())) |_| {
            return;
        } else |_| {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    return error.SocketNotReady;
}

fn waitForSessionState(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    session_id: []const u8,
    expected_state: []const u8,
    timeout_ms: i64,
) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        const client = connectClient(socket_path) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer posix.close(client);

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":99,\"method\":\"session.info\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id},
        );
        defer allocator.free(req);
        try writeAll(client, req);

        const line = readLineAlloc(allocator, client, 64 * 1024) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        const state_val = result_val.object.get("state") orelse {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        if (state_val == .string and std.mem.eql(u8, state_val.string, expected_state)) {
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.SessionStateTimeout;
}

const RunServerCtx = struct {
    server: *server_mod.Server,
    run_error: ?anyerror = null,

    fn run(self: *RunServerCtx) void {
        self.server.run() catch |err| {
            self.run_error = err;
        };
    }
};

test "native session daemon end-to-end: ping, create, send, capture, terminate, shutdown" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    // idle_timeout=0 means the server never self-exits due to idle; we drive
    // shutdown explicitly via daemon.shutdown.
    var server = try server_mod.Server.init(allocator, socket_path, 0);

    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});

    // If anything below fails, make sure we still stop the server so the
    // thread joins before we deinit it.
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    // --- daemon.ping ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        try writeAll(client, "{\"id\":1,\"method\":\"daemon.ping\",\"params\":{}}\n");
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        try std.testing.expect(parsed.value == .object);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expect(result_val == .object);

        const version = result_val.object.get("version") orelse return error.MissingVersion;
        try std.testing.expect(version == .string);
        try std.testing.expect(result_val.object.get("pid") != null);
        try std.testing.expect(result_val.object.get("socketPath") != null);

        const sessions_val = result_val.object.get("sessions") orelse return error.MissingSessions;
        try std.testing.expect(sessions_val == .integer);
        try std.testing.expectEqual(@as(i64, 0), sessions_val.integer);
    }

    // --- session.create ---
    var session_id_owned: []u8 = &.{};
    defer if (session_id_owned.len > 0) allocator.free(session_id_owned);
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        // Pass a shell + command so pty.spawn builds argv = [shell, "-lc", command].
        // A bare `shell` alone currently trips an internal unreachable in pty.zig
        // (tracked as part of 0091 wave 2); this exercises the working path.
        try writeAll(
            client,
            "{\"id\":2,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"exec /bin/sh\",\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );

        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("error")) |_| {
            std.debug.print("session.create returned error: {s}\n", .{line});
            return error.SessionCreateFailed;
        }
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expect(result_val == .object);
        const id_val = result_val.object.get("id") orelse return error.MissingSessionId;
        try std.testing.expect(id_val == .string);
        try std.testing.expect(id_val.string.len > 0);
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    // --- session.send "echo hi\n" ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"echo hi\\n\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);

        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    // Give the shell a moment to echo.
    std.Thread.sleep(600 * std.time.ns_per_ms);

    // --- session.capture, expect "hi" to appear in the scrollback. ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"lines\":10}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);

        const line = try readLineAlloc(allocator, client, 1024 * 1024);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const text_val = result_val.object.get("text") orelse return error.MissingText;
        try std.testing.expect(text_val == .string);
        // The shell should have echoed "hi" (either in the echoed command or
        // in the command's output). We look for the substring "hi".
        try std.testing.expect(std.mem.indexOf(u8, text_val.string, "hi") != null);
    }

    // --- session.terminate ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);

        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    // --- daemon.shutdown: the server's run loop should exit. ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        try writeAll(client, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    thread.join();
    server.deinit();
    server_stopped = true;

    try std.testing.expect(ctx.run_error == null);
}

// Regression: after removing tmux, reopening a session dropped the prior
// terminal state — e.g. Claude Code would appear as a fresh chat instead
// of showing the previous conversation. The daemon was buffering scrollback
// while detached but never delivering it on reattach. This test drives an
// attach, detaches, lets the shell emit more output, then re-attaches and
// verifies the attach response carries the captured scrollback under
// `replayBase64` so the client can redraw prior state (tmux-style).
test "session.attach replays scrollback on reattach so reopened sessions keep their state" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    // Create a long-lived session that emits a known sentinel and then
    // stays alive so the PTY doesn't close before we reattach. `cat`
    // (with no args) blocks on stdin forever after the echo, giving us a
    // stable target for reattach.
    var session_id_owned: []u8 = &.{};
    defer if (session_id_owned.len > 0) allocator.free(session_id_owned);
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        try writeAll(
            client,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"echo REOPEN_SENTINEL_ONE; cat\"," ++
                "\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const id_val = result_val.object.get("id") orelse return error.MissingSessionId;
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    // Give the child a moment to emit the sentinel into the scrollback.
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // First attach: the replay should already contain the initial sentinel.
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"session.attach\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const resp = try recvAttachResponse(allocator, client, 1024 * 1024);
        defer allocator.free(resp.payload);
        if (resp.pty_fd) |pfd| posix.close(pfd);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.payload, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const replay_val = result_val.object.get("replayBase64") orelse
            return error.MissingReplayField;
        try std.testing.expect(replay_val == .string);
        const decoded = try decodeBase64(allocator, replay_val.string);
        defer allocator.free(decoded);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "REOPEN_SENTINEL_ONE") != null);
    }

    // Detach, then write more output to the PTY so scrollback keeps growing
    // while we're detached (this simulates a long-running Claude Code
    // session continuing to stream while the UI is closed).
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const detach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.detach\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(detach_req);
        try writeAll(client, detach_req);
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
    }

    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const send_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.send\",\"params\":" ++
                "{{\"sessionId\":\"{s}\",\"text\":\"REOPEN_SENTINEL_TWO\\n\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(send_req);
        try writeAll(client, send_req);
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
    }

    // Let `cat` echo the input back to the PTY so the daemon captures it.
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Second attach: the replay must now carry BOTH sentinels. Before this
    // fix, the attach payload had no replay at all and the client saw a
    // blank terminal on reopen.
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"session.attach\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const resp = try recvAttachResponse(allocator, client, 1024 * 1024);
        defer allocator.free(resp.payload);
        if (resp.pty_fd) |pfd| posix.close(pfd);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.payload, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const replay_val = result_val.object.get("replayBase64") orelse
            return error.MissingReplayField;
        const decoded = try decodeBase64(allocator, replay_val.string);
        defer allocator.free(decoded);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "REOPEN_SENTINEL_ONE") != null);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "REOPEN_SENTINEL_TWO") != null);
    }

    // Clean up: terminate the session and shut the server down.
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":6,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        try writeAll(client, "{\"id\":7,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "session auto-detaches when attached client disconnects so a reopened tab can reattach" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var session_id_owned: []u8 = &.{};
    defer if (session_id_owned.len > 0) allocator.free(session_id_owned);
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        try writeAll(
            client,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"echo AUTO_DETACH_SENTINEL; cat\"," ++
                "\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const id_val = result_val.object.get("id") orelse return error.MissingSessionId;
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    std.Thread.sleep(500 * std.time.ns_per_ms);

    {
        const client = try connectClient(socket_path);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"session.attach\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const resp = try recvAttachResponse(allocator, client, 1024 * 1024);
        defer allocator.free(resp.payload);
        try std.testing.expect(resp.pty_fd != null);
        if (resp.pty_fd) |pfd| posix.close(pfd);

        // Simulate app/process death without an explicit detach RPC.
        posix.close(client);
    }

    try waitForSessionState(allocator, socket_path, session_id_owned, "detached", 2_000);

    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.attach\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const resp = try recvAttachResponse(allocator, client, 1024 * 1024);
        defer allocator.free(resp.payload);
        try std.testing.expect(resp.pty_fd != null);
        if (resp.pty_fd) |pfd| posix.close(pfd);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.payload, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const replay_val = result_val.object.get("replayBase64") orelse return error.MissingReplayField;
        const decoded = try decodeBase64(allocator, replay_val.string);
        defer allocator.free(decoded);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "AUTO_DETACH_SENTINEL") != null);
    }

    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        try writeAll(client, "{\"id\":5,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try decoder.decode(out, encoded);
    return out;
}
