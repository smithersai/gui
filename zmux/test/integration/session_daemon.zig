const std = @import("std");
const builtin = @import("builtin");

const server_mod = @import("zmux_server");

const posix = std.posix;

fn tempSocketPath(allocator: std.mem.Allocator) ![]u8 {
    // Use the system tmp dir for the UNIX domain socket. sun_path has a
    // ~104 byte limit on Darwin, so we keep the path short.
    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    return std.fmt.allocPrint(allocator, "/tmp/zmx-test-{x:0>16}.sock", .{nonce});
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

fn rpcLine(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request: []const u8,
    max_len: usize,
) ![]u8 {
    const client = try connectClient(socket_path);
    defer posix.close(client);
    try writeAll(client, request);
    return readLineAlloc(allocator, client, max_len);
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

fn waitForClientCount(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    expected_count: usize,
    timeout_ms: i64,
) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        const client = connectClient(socket_path) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer posix.close(client);

        try writeAll(client, "{\"id\":99,\"method\":\"client.list\",\"params\":{}}\n");

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
        if (result_val == .array and result_val.array.items.len == expected_count) {
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.ClientCountTimeout;
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

        // Pass a shell + command so pty.spawn builds a login-shell command
        // argv. This exercises RPC wiring plus PTY fd passing.
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

// Regression: reopening a GUI terminal used to drop the prior terminal state;
// Claude Code could appear as a fresh chat instead of showing the previous
// conversation. The daemon owns scrollback, and logical client attachment must
// replay it so thin GUI clients can redraw prior state.
test "client.attach replays scrollback on reattach so reopened sessions keep their state" {
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

    // First logical attach: the replay should already contain the initial sentinel.
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const line = try readLineAlloc(allocator, client, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const replay_val = result_val.object.get("replayBase64") orelse
            return error.MissingReplayField;
        try std.testing.expect(replay_val == .string);
        const decoded = try decodeBase64(allocator, replay_val.string);
        defer allocator.free(decoded);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "REOPEN_SENTINEL_ONE") != null);
    }

    // With the logical client connection closed, write more output to the PTY
    // so scrollback keeps growing while the UI is gone.
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const send_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.send\",\"params\":" ++
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

    // Second attach: the replay must now carry BOTH sentinels.
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const line = try readLineAlloc(allocator, client, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
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
            "{{\"id\":5,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
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
        try writeAll(client, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "logical client auto-detaches when connection closes so a reopened tab can reattach" {
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
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const line = try readLineAlloc(allocator, client, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);

        // Simulate app/process death without an explicit client.detach RPC.
        posix.close(client);
    }

    try waitForClientCount(allocator, socket_path, 0, 2_000);

    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const line = try readLineAlloc(allocator, client, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
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

test "mux model API owns windows panes clients key bindings and respawn state" {
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

    var first_pane_id: []u8 = &.{};
    defer if (first_pane_id.len > 0) allocator.free(first_pane_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"cat\",\"title\":\"root\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const id_val = result_val.object.get("id") orelse return error.MissingSessionId;
        first_pane_id = try allocator.dupe(u8, id_val.string);
    }

    var session_id: []u8 = &.{};
    defer if (session_id.len > 0) allocator.free(session_id);
    var window_id: []u8 = &.{};
    defer if (window_id.len > 0) allocator.free(window_id);
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":2,\"method\":\"mux.snapshot\",\"params\":{}}\n", 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const sessions = result_val.object.get("sessions") orelse return error.MissingSessions;
        try std.testing.expectEqual(@as(usize, 1), sessions.array.items.len);
        const session = sessions.array.items[0];
        session_id = try allocator.dupe(u8, (session.object.get("id") orelse return error.MissingSessionId).string);
        const windows = session.object.get("windows") orelse return error.MissingWindows;
        try std.testing.expectEqual(@as(usize, 1), windows.array.items.len);
        const window = windows.array.items[0];
        window_id = try allocator.dupe(u8, (window.object.get("id") orelse return error.MissingWindowId).string);
        const panes = window.object.get("panes") orelse return error.MissingPanes;
        try std.testing.expectEqual(@as(usize, 1), panes.array.items.len);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"window.new\",\"params\":{{\"sessionId\":\"{s}\",\"title\":\"second\",\"shell\":\"/bin/sh\",\"command\":\"cat\"}}}}\n",
            .{session_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"name\":\"second\"") != null);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"pane.split\",\"params\":{{\"paneId\":\"{s}\",\"axis\":\"horizontal\",\"shell\":\"/bin/sh\",\"command\":\"cat\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"split\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"axis\":\"horizontal\"") != null);
    }

    var client_one: []u8 = &.{};
    defer if (client_one.len > 0) allocator.free(client_one);
    var client_one_fd: ?posix.fd_t = null;
    defer if (client_one_fd) |fd| posix.close(fd);
    var client_two_fd: ?posix.fd_t = null;
    defer if (client_two_fd) |fd| posix.close(fd);
    {
        const client = try connectClient(socket_path);
        client_one_fd = client;
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":30,\"cols\":100}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        client_one = try allocator.dupe(u8, (result_val.object.get("clientId") orelse return error.MissingClientId).string);
    }

    {
        const client = try connectClient(socket_path);
        client_two_fd = client;
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":6,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readLineAlloc(allocator, client, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":7,\"method\":\"client.list\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expectEqual(@as(usize, 2), result_val.array.items.len);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":8,\"method\":\"key.bind\",\"params\":{{\"table\":\"prefix\",\"key\":\"%\",\"command\":\"split-window -h\"}}}}\n",
            .{},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "split-window -h") != null);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":9,\"method\":\"key.dispatch\",\"params\":{{\"table\":\"prefix\",\"key\":\"%\",\"paneId\":\"{s}\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"keyBindings\"") != null);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":10,\"method\":\"pane.rename\",\"params\":{{\"paneId\":\"{s}\",\"title\":\"renamed-pane\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "renamed-pane") != null);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":11,\"method\":\"window.rename\",\"params\":{{\"windowId\":\"{s}\",\"name\":\"renamed-window\"}}}}\n",
            .{window_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "renamed-window") != null);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":12,\"method\":\"session.rename\",\"params\":{{\"sessionId\":\"{s}\",\"name\":\"renamed-session\"}}}}\n",
            .{session_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "renamed-session") != null);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":13,\"method\":\"pane.respawn\",\"params\":{{\"paneId\":\"{s}\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"sessions\"") != null);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":14,\"method\":\"client.detach\",\"params\":{{\"clientId\":\"{s}\"}}}}\n",
            .{client_one},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"ok\":true") != null);
        if (client_one_fd) |fd| {
            posix.close(fd);
            client_one_fd = null;
        }
        if (client_two_fd) |fd| {
            posix.close(fd);
            client_two_fd = null;
        }
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":15,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":16,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
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
