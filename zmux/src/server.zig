const std = @import("std");
const builtin = @import("builtin");

const mux = @import("mux.zig");
const native_mod = @import("native.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const NativeSession = native_mod.NativeSession;
const Value = std.json.Value;
const posix = std.posix;

const max_request_bytes = 1024 * 1024;

/// Cap the raw scrollback replay delivered on attach. 256 KiB comfortably
/// covers a TUI's visible state + a few screenfuls of history while keeping
/// the attach payload bounded. When scrollback is larger, only the tail
/// (most recent bytes) is replayed.
const attach_replay_max_bytes: usize = 256 * 1024;

const ClientConnection = struct {
    allocator: Allocator,
    fd: posix.fd_t,
    write_mutex: std.Thread.Mutex = .{},
    attachment_mutex: std.Thread.Mutex = .{},
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    attached_mux_clients: std.ArrayList([]u8) = .empty,

    fn create(allocator: Allocator, fd: posix.fd_t) !*ClientConnection {
        const connection = try allocator.create(ClientConnection);
        connection.* = .{
            .allocator = allocator,
            .fd = fd,
        };
        return connection;
    }

    fn retain(self: *ClientConnection) *ClientConnection {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        return self;
    }

    fn release(self: *ClientConnection) void {
        const prev = self.ref_count.fetchSub(1, .seq_cst);
        if (prev == 1) {
            var mux_clients = self.takeMuxClients();
            defer mux_clients.deinit(self.allocator);
            for (mux_clients.items) |client_id| self.allocator.free(client_id);
            self.allocator.destroy(self);
        }
    }

    fn isClosed(self: *const ClientConnection) bool {
        return self.closed.load(.seq_cst);
    }

    fn close(self: *ClientConnection) void {
        if (!self.closed.swap(true, .seq_cst)) {
            posix.close(self.fd);
        }
    }

    fn write(self: *ClientConnection, bytes: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        if (self.isClosed()) return error.ConnectionClosed;
        writeAll(self.fd, bytes) catch |err| {
            self.close();
            return err;
        };
    }

    fn trackMuxClient(self: *ClientConnection, client_id: []const u8) !void {
        self.attachment_mutex.lock();
        defer self.attachment_mutex.unlock();

        for (self.attached_mux_clients.items) |active| {
            if (std.mem.eql(u8, active, client_id)) return;
        }

        const owned = try self.allocator.dupe(u8, client_id);
        errdefer self.allocator.free(owned);
        try self.attached_mux_clients.append(self.allocator, owned);
    }

    fn untrackMuxClient(self: *ClientConnection, client_id: []const u8) bool {
        self.attachment_mutex.lock();
        defer self.attachment_mutex.unlock();

        for (self.attached_mux_clients.items, 0..) |active, index| {
            if (std.mem.eql(u8, active, client_id)) {
                const removed = self.attached_mux_clients.swapRemove(index);
                self.allocator.free(removed);
                return true;
            }
        }
        return false;
    }

    fn takeMuxClients(self: *ClientConnection) std.ArrayList([]u8) {
        self.attachment_mutex.lock();
        defer self.attachment_mutex.unlock();

        const attached = self.attached_mux_clients;
        self.attached_mux_clients = .empty;
        return attached;
    }
};

pub const Server = struct {
    pub const ShutdownProbe = *const fn () bool;

    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    socket_path: []u8,
    listener_fd: posix.fd_t,
    manager: mux.Manager,
    connections: std.ArrayList(*ClientConnection) = .empty,
    pending_events: std.ArrayList([]u8) = .empty,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    last_activity_seconds: std.atomic.Value(i64),
    idle_timeout_seconds: i64,
    shutdown_probe: ?ShutdownProbe = null,

    pub fn init(allocator: Allocator, socket_path: []const u8, idle_timeout_seconds: i64) !Server {
        try ensureSocketParent(socket_path);
        std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const address = try std.net.Address.initUnix(socket_path);
        const listener = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(listener);
        try posix.bind(listener, &address.any, address.getOsSockLen());

        // Set socket permissions to owner-only (0600) for security
        try setSocketPermissions(allocator, socket_path);

        try posix.listen(listener, 64);

        return .{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
            .listener_fd = listener,
            .manager = mux.Manager.init(allocator, null),
            .last_activity_seconds = std.atomic.Value(i64).init(std.time.timestamp()),
            .idle_timeout_seconds = idle_timeout_seconds,
        };
    }

    pub fn deinit(self: *Server) void {
        self.running.store(false, .seq_cst);
        posix.close(self.listener_fd);
        self.closeConnections();
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
        self.manager.event_sink = null;
        self.manager.deinit();
        self.freePendingEvents();
        self.connections.deinit(self.allocator);
        self.pending_events.deinit(self.allocator);
        self.allocator.free(self.socket_path);
    }

    pub fn run(self: *Server) !void {
        self.manager.event_sink = .{
            .context = self,
            .emit = Server.handleNativeEvent,
        };
        while (!self.shouldStop()) {
            if (self.shouldExitForIdle()) break;

            try self.flushPendingEvents();

            var fds = [_]posix.pollfd{.{
                .fd = self.listener_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&fds, 250);
            if (ready == 0) continue;
            if ((fds[0].revents & posix.POLL.IN) == 0) continue;

            const client_fd = posix.accept(self.listener_fd, null, null, posix.SOCK.CLOEXEC) catch continue;
            if (!peerHasSameEuid(client_fd)) {
                posix.close(client_fd);
                continue;
            }
            self.touch();
            _ = self.active_connections.fetchAdd(1, .seq_cst);
            const thread = std.Thread.spawn(.{}, Server.handleClientThread, .{ self, client_fd }) catch {
                _ = self.active_connections.fetchSub(1, .seq_cst);
                posix.close(client_fd);
                continue;
            };
            thread.detach();
        }

        var spins: usize = 0;
        while (self.active_connections.load(.seq_cst) > 0 and spins < 100) : (spins += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        try self.flushPendingEvents();
    }

    fn shouldExitForIdle(self: *Server) bool {
        if (self.idle_timeout_seconds <= 0) return false;
        if (self.manager.count() > 0) return false;
        const idle_for = std.time.timestamp() - self.last_activity_seconds.load(.seq_cst);
        return idle_for >= self.idle_timeout_seconds;
    }

    fn shouldStop(self: *Server) bool {
        if (!self.running.load(.seq_cst)) return true;
        if (self.shutdown_probe) |probe| return probe();
        return false;
    }

    fn touch(self: *Server) void {
        self.last_activity_seconds.store(std.time.timestamp(), .seq_cst);
    }

    fn handleClientThread(self: *Server, client_fd: posix.fd_t) void {
        defer _ = self.active_connections.fetchSub(1, .seq_cst);

        const connection = ClientConnection.create(self.allocator, client_fd) catch {
            posix.close(client_fd);
            return;
        };
        defer connection.release();
        defer connection.close();

        self.registerConnection(connection);
        defer self.unregisterConnection(connection);

        self.handleClient(connection);
    }

    fn handleClient(self: *Server, connection: *ClientConnection) void {
        while (self.running.load(.seq_cst)) {
            const line = readLine(self.allocator, connection.fd, max_request_bytes) catch |err| {
                if (connection.isClosed()) return;
                self.writeError(connection, "null", protocol.ErrorCode.parse_error, @errorName(err)) catch {};
                return;
            } orelse return;
            defer self.allocator.free(line);
            if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;

            self.touch();
            var req = protocol.parseRequest(self.allocator, line) catch |err| {
                self.writeError(connection, "null", protocol.ErrorCode.invalid_request, @errorName(err)) catch {};
                continue;
            };
            defer req.deinit();

            self.dispatch(connection, &req) catch |err| {
                self.writeError(connection, req.id_json, protocol.ErrorCode.internal_error, @errorName(err)) catch {};
            };
        }
    }

    fn dispatch(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        if (std.mem.eql(u8, req.method, "daemon.ping")) {
            const response = try protocol.result(self.allocator, req.id_json, .{
                .version = protocol.version,
                .pid = std.c.getpid(),
                .socketPath = self.socket_path,
                .sessions = self.manager.count(),
            });
            defer self.allocator.free(response);
            return connection.write(response);
        }

        if (std.mem.eql(u8, req.method, "daemon.shutdown")) {
            const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
            defer self.allocator.free(response);
            try connection.write(response);
            self.manager.terminateAll();
            self.running.store(false, .seq_cst);
            return;
        }

        if (std.mem.eql(u8, req.method, "session.create")) return self.createSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.terminate")) return self.terminateSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.list")) return self.listSessions(connection, req);
        if (std.mem.eql(u8, req.method, "session.info")) return self.infoSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.resize")) return self.resizeSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.capture")) return self.captureSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.send")) return self.sendSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.sendKey")) return self.sendKeySession(connection, req);
        if (std.mem.eql(u8, req.method, "mux.snapshot")) return self.snapshotMux(connection, req);
        if (std.mem.eql(u8, req.method, "window.new")) return self.newWindow(connection, req);
        if (std.mem.eql(u8, req.method, "window.select")) return self.selectWindow(connection, req);
        if (std.mem.eql(u8, req.method, "window.rename")) return self.renameWindow(connection, req);
        if (std.mem.eql(u8, req.method, "pane.split")) return self.splitPane(connection, req);
        if (std.mem.eql(u8, req.method, "pane.select")) return self.selectPane(connection, req);
        if (std.mem.eql(u8, req.method, "pane.rename")) return self.renamePane(connection, req);
        if (std.mem.eql(u8, req.method, "pane.respawn")) return self.respawnPane(connection, req);
        if (std.mem.eql(u8, req.method, "session.rename")) return self.renameSession(connection, req);
        if (std.mem.eql(u8, req.method, "client.attach")) return self.attachMuxClient(connection, req);
        if (std.mem.eql(u8, req.method, "client.detach")) return self.detachMuxClient(connection, req);
        if (std.mem.eql(u8, req.method, "client.switch")) return self.switchMuxClient(connection, req);
        if (std.mem.eql(u8, req.method, "client.list")) return self.listMuxClients(connection, req);
        if (std.mem.eql(u8, req.method, "key.bind")) return self.bindKey(connection, req);
        if (std.mem.eql(u8, req.method, "key.dispatch")) return self.dispatchKey(connection, req);
        if (std.mem.eql(u8, req.method, "key.list")) return self.listKeys(connection, req);
        if (std.mem.eql(u8, req.method, "command.exec")) return self.execCommand(connection, req);

        try self.writeError(connection, req.id_json, protocol.ErrorCode.method_not_found, "unknown method");
    }

    fn createSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        var create_args = try muxCreateArgsFromParams(self.allocator, req.params());
        defer create_args.deinit();

        const created = try self.manager.create(create_args.opts);

        const info = try created.infoJson(self.allocator);
        defer self.allocator.free(info);
        const response = try protocol.resultRaw(self.allocator, req.id_json, info);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn snapshotMux(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn newWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const session_id = sessionIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        var create_args = try muxCreateArgsFromParams(self.allocator, req.params());
        defer create_args.deinit();
        _ = try self.manager.newWindow(session_id, create_args.opts);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn splitPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        var create_args = try muxCreateArgsFromParams(self.allocator, req.params());
        defer create_args.deinit();
        _ = try self.manager.splitPane(pane_id, axisParam(req.params()), create_args.opts);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn selectPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        try self.manager.selectPane(pane_id);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn selectWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const window_id = windowIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "windowId is required");
        };
        try self.manager.selectWindow(window_id);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn renameSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const session_id = sessionIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        const name = firstStringParam(req.params(), &.{ "name", "title" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "name is required");
        };
        try self.manager.renameSession(session_id, name);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn renameWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const window_id = windowIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "windowId is required");
        };
        const name = firstStringParam(req.params(), &.{ "name", "title" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "name is required");
        };
        try self.manager.renameWindow(window_id, name);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn renamePane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const title = firstStringParam(req.params(), &.{ "title", "name" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "title is required");
        };
        try self.manager.renamePane(pane_id, title, boolParam(req.params(), "custom", true));
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn respawnPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const active = try self.manager.respawnPane(pane_id);
        defer active.release();
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn attachMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const client = try self.manager.attachClient(
            pane_id,
            intParam(u16, req.params(), "rows", 24),
            intParam(u16, req.params(), "cols", 80),
        );
        errdefer _ = self.manager.detachClient(client.id);
        try connection.trackMuxClient(client.id);
        errdefer _ = connection.untrackMuxClient(client.id);
        const scrollback = try self.manager.paneScrollbackSnapshot(self.allocator, client.pane_id);
        defer self.allocator.free(scrollback);
        const replay_bytes = truncatedReplay(scrollback, attach_replay_max_bytes);
        const replay_b64 = try base64Encode(self.allocator, replay_bytes);
        defer self.allocator.free(replay_b64);
        const response = try protocol.result(self.allocator, req.id_json, .{
            .clientId = client.id,
            .sessionId = client.session_id,
            .windowId = client.window_id,
            .paneId = client.pane_id,
            .rows = client.rows,
            .cols = client.cols,
            .replayBase64 = replay_b64,
        });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn detachMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const client_id = clientIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "clientId is required");
        };
        _ = connection.untrackMuxClient(client_id);
        if (!self.manager.detachClient(client_id)) {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, "client not found");
        }
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn switchMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const client_id = clientIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "clientId is required");
        };
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        try self.manager.switchClient(client_id, pane_id);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn listMuxClients(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.clientsJson(self.allocator);
        defer self.allocator.free(list);
        const response = try protocol.resultRaw(self.allocator, req.id_json, list);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn bindKey(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const key = stringParam(req.params(), "key") orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "key is required");
        };
        const command = firstStringParam(req.params(), &.{ "command", "cmd" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "command is required");
        };
        try self.manager.bindKey(stringParam(req.params(), "table") orelse "prefix", key, command, boolParam(req.params(), "repeat", false));
        const list = try self.manager.keysJson(self.allocator);
        defer self.allocator.free(list);
        const response = try protocol.resultRaw(self.allocator, req.id_json, list);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn dispatchKey(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const key = stringParam(req.params(), "key") orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "key is required");
        };
        const command = try self.manager.executeBinding(stringParam(req.params(), "table") orelse "prefix", key, pane_id);
        defer if (command) |owned| self.allocator.free(owned);
        if (command == null) {
            const response = try protocol.result(self.allocator, req.id_json, .{ .handled = false });
            defer self.allocator.free(response);
            return connection.write(response);
        }
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn listKeys(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.keysJson(self.allocator);
        defer self.allocator.free(list);
        const response = try protocol.resultRaw(self.allocator, req.id_json, list);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn execCommand(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const command = firstStringParam(req.params(), &.{ "command", "line" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "command is required");
        };
        try self.manager.executeCommandLine(command, pane_id);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn terminateSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const id = sessionIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        if (!self.manager.terminate(id)) {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, "session not found");
        }
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn listSessions(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.listJson(self.allocator);
        defer self.allocator.free(list);
        const response = try protocol.resultRaw(self.allocator, req.id_json, list);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn infoSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        const info = try active.infoJson(self.allocator);
        defer self.allocator.free(info);
        const response = try protocol.resultRaw(self.allocator, req.id_json, info);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn resizeSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        try active.resize(intParam(u16, req.params(), "cols", 80), intParam(u16, req.params(), "rows", 24));
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn captureSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        const text = try active.capture(self.allocator, intParam(usize, req.params(), "lines", 200));
        defer self.allocator.free(text);
        const response = try protocol.result(self.allocator, req.id_json, .{
            .sessionId = active.id,
            .text = text,
        });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn sendSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        if (firstStringParam(req.params(), &.{ "dataBase64", "data_base64" })) |encoded| {
            const bytes = try base64Decode(self.allocator, encoded);
            defer self.allocator.free(bytes);
            try active.writeInput(bytes);
        } else {
            try active.send(stringParam(req.params(), "text") orelse "", boolParam(req.params(), "enter", false));
        }
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn sendKeySession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        const key = stringParam(req.params(), "key") orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "key is required");
        };
        active.sendKey(key) catch |err| {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, @errorName(err));
        };
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    /// Get a required session by ID. Caller MUST call release() on the returned session.
    fn requiredSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !?*NativeSession {
        const id = sessionIdParam(req.params()) orelse {
            try self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
            return null;
        };
        return self.manager.find(id) orelse {
            try self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, "session not found");
            return null;
        };
    }

    fn writeSnapshotResponse(self: *Server, connection: *ClientConnection, id_json: []const u8) !void {
        const snapshot = try self.manager.snapshotJson(self.allocator);
        defer self.allocator.free(snapshot);
        const response = try protocol.resultRaw(self.allocator, id_json, snapshot);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn writeError(self: *Server, connection: *ClientConnection, id_json: []const u8, code: i32, message: []const u8) !void {
        const response = try protocol.@"error"(self.allocator, id_json, code, message);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn registerConnection(self: *Server, connection: *ClientConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connections.append(self.allocator, connection.retain()) catch {
            connection.close();
            connection.release();
        };
    }

    fn unregisterConnection(self: *Server, connection: *ClientConnection) void {
        self.detachConnectionClients(connection);

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.connections.items, 0..) |active, index| {
            if (active == connection) {
                const removed = self.connections.swapRemove(index);
                removed.release();
                break;
            }
        }
    }

    fn detachConnectionClients(self: *Server, connection: *ClientConnection) void {
        var mux_clients = connection.takeMuxClients();
        defer mux_clients.deinit(self.allocator);
        for (mux_clients.items) |client_id| {
            _ = self.manager.detachClient(client_id);
            self.allocator.free(client_id);
        }
    }

    fn closeConnections(self: *Server) void {
        self.mutex.lock();
        var connections = self.connections;
        self.connections = .empty;
        self.mutex.unlock();

        defer connections.deinit(self.allocator);
        for (connections.items) |connection| {
            connection.close();
            connection.release();
        }
    }

    fn freePendingEvents(self: *Server) void {
        self.mutex.lock();
        var pending = self.pending_events;
        self.pending_events = .empty;
        self.mutex.unlock();

        defer pending.deinit(self.allocator);
        for (pending.items) |payload| self.allocator.free(payload);
    }

    fn enqueueNotification(self: *Server, payload: []u8) void {
        self.mutex.lock();
        self.pending_events.append(self.allocator, payload) catch {
            self.mutex.unlock();
            self.allocator.free(payload);
            return;
        };
        self.mutex.unlock();
    }

    fn flushPendingEvents(self: *Server) !void {
        self.mutex.lock();
        var pending = self.pending_events;
        self.pending_events = .empty;
        self.mutex.unlock();

        defer pending.deinit(self.allocator);

        for (pending.items) |payload| {
            defer self.allocator.free(payload);
            try self.broadcast(payload);
        }
    }

    fn broadcast(self: *Server, payload: []const u8) !void {
        self.mutex.lock();
        const snapshot = self.allocator.alloc(*ClientConnection, self.connections.items.len) catch |err| {
            self.mutex.unlock();
            return err;
        };
        for (self.connections.items, 0..) |connection, index| {
            snapshot[index] = connection.retain();
        }
        self.mutex.unlock();
        defer self.allocator.free(snapshot);

        for (snapshot) |connection| {
            defer connection.release();
            connection.write(payload) catch {
                self.unregisterConnection(connection);
            };
        }
    }

    fn handleNativeEvent(context: *anyopaque, event: native_mod.Event) void {
        const self: *Server = @ptrCast(@alignCast(context));
        const payload = switch (event) {
            .foreground_changed => |params| protocol.notification(
                self.allocator,
                protocol.foreground_changed_method,
                params,
            ),
            .session_exited => |params| blk: {
                self.manager.markExited(params.session_id);
                break :blk protocol.notification(
                    self.allocator,
                    protocol.session_exited_method,
                    params,
                );
            },
            .pane_output => |params| blk: {
                self.manager.markActivity(params.pane_id);
                const encoded = base64Encode(self.allocator, params.data) catch return;
                defer self.allocator.free(encoded);
                break :blk protocol.notification(
                    self.allocator,
                    protocol.pane_output_method,
                    protocol.PaneOutputParams{
                        .pane_id = params.pane_id,
                        .data_base64 = encoded,
                    },
                );
            },
            .pane_activity => |params| blk: {
                self.manager.markActivity(params.pane_id);
                break :blk protocol.notification(
                    self.allocator,
                    protocol.pane_activity_method,
                    protocol.PaneActivityParams{
                        .pane_id = params.pane_id,
                        .last_activity_ms = params.last_activity_ms,
                    },
                );
            },
            .pane_bell => |params| blk: {
                self.manager.markBell(params.pane_id);
                break :blk protocol.notification(
                    self.allocator,
                    protocol.pane_bell_method,
                    protocol.PaneBellParams{
                        .pane_id = params.pane_id,
                        .last_bell_ms = params.last_bell_ms,
                    },
                );
            },
        } catch return;

        self.enqueueNotification(payload);
    }
};

fn ensureSocketParent(socket_path: []const u8) !void {
    const parent = std.fs.path.dirname(socket_path) orelse return;
    var created = false;
    std.fs.accessAbsolute(parent, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fs.makeDirAbsolute(parent);
            created = true;
        },
        else => return err,
    };

    if (!created) return;

    var dir = std.fs.openDirAbsolute(parent, .{}) catch return;
    defer dir.close();
    _ = std.c.fchmod(dir.fd, 0o700);
}

fn setSocketPermissions(allocator: Allocator, socket_path: []const u8) !void {
    // Set socket file permissions to owner-only (0600) for security
    const path_z = try allocator.dupeZ(u8, socket_path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, 0o600) != 0) {
        return error.PermissionDenied;
    }
}

fn readLine(allocator: Allocator, fd: posix.fd_t, max_len: usize) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var byte: [1]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &byte);
        if (n == 0) {
            if (out.items.len == 0) {
                out.deinit(allocator);
                return null;
            }
            return try out.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') {
            try out.append(allocator, '\n');
            return try out.toOwnedSlice(allocator);
        }
        try out.append(allocator, byte[0]);
        if (out.items.len > max_len) return error.RequestTooLarge;
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try posix.write(fd, bytes[offset..]);
    }
}

fn sessionIdParam(params: ?Value) ?[]const u8 {
    return firstStringParam(params, &.{ "sessionId", "id" });
}

fn firstStringParam(params: ?Value, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (stringParam(params, key)) |value| return value;
    }
    return null;
}

fn stringParam(params: ?Value, key: []const u8) ?[]const u8 {
    const params_value = params orelse return null;
    if (params_value != .object) return null;
    const value = params_value.object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolParam(params: ?Value, key: []const u8, default: bool) bool {
    const params_value = params orelse return default;
    if (params_value != .object) return default;
    const value = params_value.object.get(key) orelse return default;
    return switch (value) {
        .bool => |flag| flag,
        else => default,
    };
}

fn intParam(comptime T: type, params: ?Value, key: []const u8, default: T) T {
    const params_value = params orelse return default;
    if (params_value != .object) return default;
    const value = params_value.object.get(key) orelse return default;
    const integer = switch (value) {
        .integer => |n| n,
        else => return default,
    };
    if (integer < 0) return default;
    return std.math.cast(T, integer) orelse default;
}

const MuxCreateArgs = struct {
    allocator: Allocator,
    env_entries: ?[][]const u8 = null,
    opts: mux.CreateOptions,

    fn deinit(self: *MuxCreateArgs) void {
        if (self.env_entries) |entries| freeStringSlice(self.allocator, entries);
        self.env_entries = null;
        self.opts = .{};
    }
};

fn muxCreateArgsFromParams(allocator: Allocator, params: ?Value) !MuxCreateArgs {
    const env_entries = try envEntriesFromParams(allocator, params);
    errdefer if (env_entries) |entries| freeStringSlice(allocator, entries);
    return .{
        .allocator = allocator,
        .env_entries = env_entries,
        .opts = .{
            .title = firstStringParam(params, &.{ "title", "name" }),
            .shell = stringParam(params, "shell"),
            .command = stringParam(params, "command"),
            .cwd = firstStringParam(params, &.{ "cwd", "workingDirectory" }),
            .env = if (env_entries) |entries| entries else null,
            .rows = intParam(u16, params, "rows", 24),
            .cols = intParam(u16, params, "cols", 80),
            .scrollback_bytes = intParam(usize, params, "scrollbackBytes", @import("buffer.zig").default_capacity),
        },
    };
}

fn paneIdParam(params: ?Value) ?[]const u8 {
    return firstStringParam(params, &.{ "paneId", "targetPaneId", "target", "sessionId", "id" });
}

fn windowIdParam(params: ?Value) ?[]const u8 {
    return firstStringParam(params, &.{ "windowId", "targetWindowId", "target", "id" });
}

fn clientIdParam(params: ?Value) ?[]const u8 {
    return firstStringParam(params, &.{ "clientId", "targetClientId", "id" });
}

fn axisParam(params: ?Value) mux.Axis {
    const axis = stringParam(params, "axis") orelse return if (boolParam(params, "horizontal", false)) .horizontal else .vertical;
    if (std.mem.eql(u8, axis, "horizontal") or std.mem.eql(u8, axis, "h") or std.mem.eql(u8, axis, "-h")) {
        return .horizontal;
    }
    return .vertical;
}

fn envEntriesFromParams(allocator: Allocator, params: ?Value) !?[][]const u8 {
    const params_value = params orelse return null;
    if (params_value != .object) return null;
    const env_value = params_value.object.get("env") orelse params_value.object.get("environment") orelse return null;
    if (env_value != .object) return null;

    var entries = std.ArrayList([]const u8).empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    var it = env_value.object.iterator();
    while (it.next()) |entry| {
        const value_text = try envValueString(allocator, entry.value_ptr.*);
        defer allocator.free(value_text);
        const env_entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, value_text });
        try entries.append(allocator, env_entry);
    }

    return try entries.toOwnedSlice(allocator);
}

fn envValueString(allocator: Allocator, value: Value) ![]u8 {
    return switch (value) {
        .string => |text| allocator.dupe(u8, text),
        .integer => |n| std.fmt.allocPrint(allocator, "{}", .{n}),
        .float => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .bool => |flag| allocator.dupe(u8, if (flag) "true" else "false"),
        .null => allocator.dupe(u8, ""),
        else => protocol.jsonValueAlloc(allocator, value),
    };
}

fn freeStringSlice(allocator: Allocator, entries: []const []const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

fn truncatedReplay(scrollback: []const u8, max_bytes: usize) []const u8 {
    if (scrollback.len <= max_bytes) return scrollback;
    return scrollback[scrollback.len - max_bytes ..];
}

fn base64Encode(allocator: Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

fn base64Decode(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try decoder.decode(out, encoded);
    return out;
}

fn peerHasSameEuid(fd: posix.fd_t) bool {
    return switch (builtin.os.tag) {
        .linux => linuxPeerUid(fd) == posix.geteuid(),
        .macos, .ios, .tvos, .watchos, .visionos => darwinPeerUid(fd) == posix.geteuid(),
        else => true,
    };
}

fn linuxPeerUid(fd: posix.fd_t) std.c.uid_t {
    const linux = std.os.linux;
    const UCred = extern struct {
        pid: posix.pid_t,
        uid: std.c.uid_t,
        gid: std.c.gid_t,
    };
    var cred: UCred = undefined;
    posix.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        std.mem.asBytes(&cred),
    ) catch return std.math.maxInt(std.c.uid_t);
    return cred.uid;
}

fn darwinPeerUid(fd: posix.fd_t) std.c.uid_t {
    var uid: std.c.uid_t = undefined;
    var gid: std.c.gid_t = undefined;
    if (getpeereid(fd, &uid, &gid) != 0) return std.math.maxInt(std.c.uid_t);
    return uid;
}

extern "c" fn getpeereid(socket: c_int, euid: *std.c.uid_t, egid: *std.c.gid_t) c_int;

test "server parses aliases for session id" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"id\":\"sess-1\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sess-1", sessionIdParam(parsed.value).?);
}

test "truncatedReplay keeps tail when larger than cap" {
    const full = "abcdefghij";
    try std.testing.expectEqualStrings("ghij", truncatedReplay(full, 4));
    try std.testing.expectEqualStrings("abcdefghij", truncatedReplay(full, 128));
}

test "peer credential check accepts same-user unix socket peer" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) return error.SkipZigTest;
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    try std.testing.expect(peerHasSameEuid(sockets[0]));
}

test "existing socket parent permissions are left unchanged" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-existing-parent");
    defer allocator.free(parent);
    defer std.fs.deleteTreeAbsolute(parent) catch {};

    try std.fs.makeDirAbsolute(parent);
    try chmodAbsolute(allocator, parent, 0o755);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    var server = try Server.init(allocator, socket_path, 0);
    defer server.deinit();

    try std.testing.expectEqual(@as(u32, 0o755), try dirMode(parent));
}

test "new socket parent is private" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-new-parent");
    defer allocator.free(parent);
    defer std.fs.deleteTreeAbsolute(parent) catch {};

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    try ensureSocketParent(socket_path);
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(parent));
}

fn tempPath(allocator: Allocator, prefix: []const u8) ![]u8 {
    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    return std.fmt.allocPrint(allocator, "/tmp/{s}-{x:0>16}", .{ prefix, nonce });
}

fn chmodAbsolute(allocator: Allocator, path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ChmodFailed;
}

fn dirMode(path: []const u8) !u32 {
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    const stat = try posix.fstat(dir.fd);
    return @intCast(stat.mode & 0o7777);
}
