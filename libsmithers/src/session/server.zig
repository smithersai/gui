const std = @import("std");

const fd_passing = @import("fd_passing.zig");
const native_mod = @import("native.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const NativeSession = native_mod.NativeSession;
const NativeSessionOptions = native_mod.NativeSessionOptions;
const Value = std.json.Value;
const posix = std.posix;

const max_request_bytes = 1024 * 1024;

const ClientConnection = struct {
    allocator: Allocator,
    fd: posix.fd_t,
    write_mutex: std.Thread.Mutex = .{},
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
        if (prev == 1) self.allocator.destroy(self);
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

    fn sendJsonWithFd(self: *ClientConnection, fd: posix.fd_t, payload: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        if (self.isClosed()) return error.ConnectionClosed;
        fd_passing.sendJsonWithFd(self.fd, fd, payload) catch |err| {
            self.close();
            return err;
        };
    }
};

pub const CreateOptions = struct {
    title: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = @import("buffer.zig").default_capacity,
};

pub const SessionManager = struct {
    allocator: Allocator,
    event_sink: ?native_mod.EventSink = null,
    mutex: std.Thread.Mutex = .{},
    sessions: std.ArrayList(*NativeSession) = .empty,
    next_id: usize = 0,

    pub fn init(allocator: Allocator, event_sink: ?native_mod.EventSink) SessionManager {
        return .{
            .allocator = allocator,
            .event_sink = event_sink,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.terminateAll();
        self.sessions.deinit(self.allocator);
    }

    pub fn count(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.items.len;
    }

    pub fn create(self: *SessionManager, opts: CreateOptions) !*NativeSession {
        self.mutex.lock();
        self.next_id += 1;
        const sequence = self.next_id;
        self.mutex.unlock();

        const id = try std.fmt.allocPrint(self.allocator, "sess-{d}-{x}", .{ sequence, std.time.nanoTimestamp() });
        defer self.allocator.free(id);

        const created = try NativeSession.create(self.allocator, NativeSessionOptions{
            .id = id,
            .title = opts.title,
            .shell = opts.shell,
            .command = opts.command,
            .cwd = opts.cwd,
            .env = opts.env,
            .rows = opts.rows,
            .cols = opts.cols,
            .scrollback_bytes = opts.scrollback_bytes,
            .event_sink = self.event_sink,
        });
        errdefer created.destroy();

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.sessions.append(self.allocator, created);
        return created;
    }

    /// Find a session by ID. Caller MUST call release() when done with the session.
    pub fn find(self: *SessionManager, id: []const u8) ?*NativeSession {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |active| {
            if (std.mem.eql(u8, active.id, id)) {
                active.retain();
                return active;
            }
        }
        return null;
    }

    pub fn terminate(self: *SessionManager, id: []const u8) bool {
        self.mutex.lock();
        var found: ?*NativeSession = null;
        for (self.sessions.items, 0..) |active, i| {
            if (std.mem.eql(u8, active.id, id)) {
                found = active;
                _ = self.sessions.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock();

        if (found) |active| {
            active.terminate();
            active.destroy();
            return true;
        }
        return false;
    }

    pub fn terminateAll(self: *SessionManager) void {
        self.mutex.lock();
        var sessions = self.sessions;
        self.sessions = .empty;
        self.mutex.unlock();

        for (sessions.items) |active| {
            active.terminate();
            active.destroy();
        }
        sessions.deinit(self.allocator);
    }

    pub fn listJson(self: *SessionManager, allocator: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeByte('[');
        for (self.sessions.items, 0..) |active, index| {
            if (index > 0) try out.writer.writeByte(',');
            const info = try active.infoJson(allocator);
            defer allocator.free(info);
            try out.writer.writeAll(info);
        }
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }
};

pub const Server = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    socket_path: []u8,
    listener_fd: posix.fd_t,
    manager: SessionManager,
    connections: std.ArrayList(*ClientConnection) = .empty,
    pending_events: std.ArrayList([]u8) = .empty,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    last_activity_seconds: std.atomic.Value(i64),
    idle_timeout_seconds: i64,

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
            .manager = SessionManager.init(allocator, null),
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
        while (self.running.load(.seq_cst)) {
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
        if (std.mem.eql(u8, req.method, "session.attach")) return self.attachSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.detach")) return self.detachSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.terminate")) return self.terminateSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.list")) return self.listSessions(connection, req);
        if (std.mem.eql(u8, req.method, "session.info")) return self.infoSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.resize")) return self.resizeSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.capture")) return self.captureSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.send")) return self.sendSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.sendKey")) return self.sendKeySession(connection, req);

        try self.writeError(connection, req.id_json, protocol.ErrorCode.method_not_found, "unknown method");
    }

    fn createSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const params = req.params();
        const env_entries = try envEntriesFromParams(self.allocator, params);
        defer if (env_entries) |entries| freeStringSlice(self.allocator, entries);

        const created = try self.manager.create(.{
            .title = stringParam(params, "title"),
            .shell = stringParam(params, "shell"),
            .command = stringParam(params, "command"),
            .cwd = firstStringParam(params, &.{ "cwd", "workingDirectory" }),
            .env = if (env_entries) |entries| entries else null,
            .rows = intParam(u16, params, "rows", 24),
            .cols = intParam(u16, params, "cols", 80),
            .scrollback_bytes = intParam(usize, params, "scrollbackBytes", @import("buffer.zig").default_capacity),
        });

        const info = try created.infoJson(self.allocator);
        defer self.allocator.free(info);
        const response = try protocol.resultRaw(self.allocator, req.id_json, info);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn attachSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const id = sessionIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        const active = self.manager.find(id) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, "session not found");
        };
        defer active.release();

        const fd = active.attachFd() catch |err| {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, @errorName(err));
        };

        const info = try active.infoJson(self.allocator);
        defer self.allocator.free(info);
        const response = try protocol.resultRaw(self.allocator, req.id_json, info);
        defer self.allocator.free(response);
        connection.sendJsonWithFd(fd, response) catch |err| {
            active.detach() catch {};
            return err;
        };
    }

    fn detachSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        active.detach() catch |err| {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, @errorName(err));
        };
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true, .state = "detached" });
        defer self.allocator.free(response);
        try connection.write(response);
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

        try active.send(stringParam(req.params(), "text") orelse "", boolParam(req.params(), "enter", false));
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
            .session_exited => |params| protocol.notification(
                self.allocator,
                protocol.session_exited_method,
                params,
            ),
        } catch return;

        self.enqueueNotification(payload);
    }
};

fn ensureSocketParent(socket_path: []const u8) !void {
    const parent = std.fs.path.dirname(socket_path) orelse return;
    std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // Set directory to owner-only (0700) using fchmod on the dir handle
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

test "server parses aliases for session id" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"id\":\"sess-1\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sess-1", sessionIdParam(parsed.value).?);
}
