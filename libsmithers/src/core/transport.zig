//! Transport coordinator — the event-loop layer between the Session and
//! the outside world.
//!
//! Promotion status (ticket 0140):
//!   * `FakeTransport` — kept for unit/integration tests that assert
//!     session-lifecycle semantics independently of the network. These
//!     are the original 0120 tests.
//!   * `RealTransport` — replaces the 0120 skeleton. Spawns:
//!       - one Electric long-poll thread per subscription
//!       - one HTTP POST worker thread per session (for writes)
//!       - one WebSocket reader thread per attached PTY
//!     and funnels results through a shared `Delta` queue that
//!     `tick()` drains. Cursor persistence is backed by `cache.zig`;
//!     token refresh is handed to `Core.fetchCredentials()`.
//!
//! Threading model: every worker thread pushes onto `pending`
//! (mutex-protected) and is interrupted via a per-worker atomic
//! `cancel` flag. `destroy()` signals + joins all workers.

const std = @import("std");
const builtin = @import("builtin");
const electric = @import("electric/mod.zig");
const wspty = @import("wspty/mod.zig");
const CacheMod = @import("cache.zig");

/// Forward declarations for types we reference from core.zig / session.zig.
/// We can't import those directly without circular imports, so RealTransport
/// takes opaque pointers + trampolines from the factory.
const Allocator = std.mem.Allocator;

/// Control messages the transport delivers back to the session. The
/// session translates these into public events (SHAPE_DELTA, WRITE_ACK,
/// PTY_DATA, AUTH_EXPIRED, ...).
pub const Delta = union(enum) {
    row_upsert: struct { shape: []const u8, pk: []const u8, row_json: []const u8 },
    row_delete: struct { shape: []const u8, pk: []const u8 },
    up_to_date: struct { shape: []const u8, handle: []const u8, offset: []const u8 },
    must_refetch: struct { shape: []const u8 },
    auth_expired,
    write_ack: struct { future: u64, ok: bool, status: u16, body: []const u8 },
    pty_data: struct { handle: u64, bytes: []const u8 },
    pty_closed: struct { handle: u64 },
};

/// The transport's contract. Production wires this to `RealTransport`;
/// tests wire it to `FakeTransport`.
pub const VTable = struct {
    subscribe: *const fn (ctx: ?*anyopaque, shape: []const u8, params_json: []const u8) anyerror!u64,
    unsubscribe: *const fn (ctx: ?*anyopaque, sub_id: u64) anyerror!void,
    write: *const fn (ctx: ?*anyopaque, action: []const u8, payload_json: []const u8) anyerror!u64,
    attachPty: *const fn (ctx: ?*anyopaque, session_id: []const u8) anyerror!u64,
    ptyWrite: *const fn (ctx: ?*anyopaque, handle: u64, bytes: []const u8) anyerror!void,
    ptyResize: *const fn (ctx: ?*anyopaque, handle: u64, cols: u16, rows: u16) anyerror!void,
    ptyDetach: *const fn (ctx: ?*anyopaque, handle: u64) anyerror!void,
    tick: *const fn (ctx: ?*anyopaque, out: *std.ArrayList(Delta), allocator: Allocator) anyerror!void,
    destroy: *const fn (ctx: ?*anyopaque, allocator: Allocator) void,
};

pub const Transport = struct {
    vtable: *const VTable,
    ctx: ?*anyopaque,

    pub fn subscribe(self: Transport, shape: []const u8, params_json: []const u8) !u64 {
        return self.vtable.subscribe(self.ctx, shape, params_json);
    }
    pub fn unsubscribe(self: Transport, id: u64) !void {
        return self.vtable.unsubscribe(self.ctx, id);
    }
    pub fn write(self: Transport, action: []const u8, payload_json: []const u8) !u64 {
        return self.vtable.write(self.ctx, action, payload_json);
    }
    pub fn attachPty(self: Transport, session_id: []const u8) !u64 {
        return self.vtable.attachPty(self.ctx, session_id);
    }
    pub fn ptyWrite(self: Transport, handle: u64, bytes: []const u8) !void {
        return self.vtable.ptyWrite(self.ctx, handle, bytes);
    }
    pub fn ptyResize(self: Transport, handle: u64, cols: u16, rows: u16) !void {
        return self.vtable.ptyResize(self.ctx, handle, cols, rows);
    }
    pub fn ptyDetach(self: Transport, handle: u64) !void {
        return self.vtable.ptyDetach(self.ctx, handle);
    }
    pub fn tick(self: Transport, out: *std.ArrayList(Delta), allocator: Allocator) !void {
        return self.vtable.tick(self.ctx, out, allocator);
    }
    pub fn destroy(self: Transport, allocator: Allocator) void {
        self.vtable.destroy(self.ctx, allocator);
    }
};

// -----------------------------------------------------------------------
// Delta ownership helpers — shared between Fake + Real transports.
// -----------------------------------------------------------------------

pub fn dupDelta(a: Allocator, d: Delta) !Delta {
    return switch (d) {
        .row_upsert => |v| Delta{ .row_upsert = .{
            .shape = try a.dupe(u8, v.shape),
            .pk = try a.dupe(u8, v.pk),
            .row_json = try a.dupe(u8, v.row_json),
        } },
        .row_delete => |v| Delta{ .row_delete = .{
            .shape = try a.dupe(u8, v.shape),
            .pk = try a.dupe(u8, v.pk),
        } },
        .up_to_date => |v| Delta{ .up_to_date = .{
            .shape = try a.dupe(u8, v.shape),
            .handle = try a.dupe(u8, v.handle),
            .offset = try a.dupe(u8, v.offset),
        } },
        .must_refetch => |v| Delta{ .must_refetch = .{
            .shape = try a.dupe(u8, v.shape),
        } },
        .auth_expired => Delta.auth_expired,
        .write_ack => |v| Delta{ .write_ack = .{
            .future = v.future,
            .ok = v.ok,
            .status = v.status,
            .body = try a.dupe(u8, v.body),
        } },
        .pty_data => |v| Delta{ .pty_data = .{
            .handle = v.handle,
            .bytes = try a.dupe(u8, v.bytes),
        } },
        .pty_closed => |v| Delta{ .pty_closed = .{ .handle = v.handle } },
    };
}

pub fn freeDelta(a: Allocator, d: Delta) void {
    switch (d) {
        .row_upsert => |v| {
            a.free(v.shape);
            a.free(v.pk);
            a.free(v.row_json);
        },
        .row_delete => |v| {
            a.free(v.shape);
            a.free(v.pk);
        },
        .up_to_date => |v| {
            a.free(v.shape);
            a.free(v.handle);
            a.free(v.offset);
        },
        .must_refetch => |v| a.free(v.shape),
        .auth_expired => {},
        .write_ack => |v| a.free(v.body),
        .pty_data => |v| a.free(v.bytes),
        .pty_closed => {},
    }
}

// -----------------------------------------------------------------------
// FakeTransport — unchanged from 0120. Kept so every existing session
// test (116+ assertions) continues to pass and so `core.transport_override`
// remains a supported hook for integration tests that want deterministic
// delta injection.
// -----------------------------------------------------------------------

pub const FakeTransport = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    next_sub_id: u64 = 1,
    next_future: u64 = 1,
    next_pty: u64 = 1,
    pending: std.ArrayList(Delta) = .empty,
    writes: std.ArrayList(Write) = .empty,
    pty_writes: std.ArrayList(PtyWrite) = .empty,
    resizes: std.ArrayList(Resize) = .empty,

    pub const Write = struct { future: u64, action: []const u8, payload: []const u8 };
    pub const PtyWrite = struct { handle: u64, bytes: []const u8 };
    pub const Resize = struct { handle: u64, cols: u16, rows: u16 };

    pub fn create(allocator: Allocator) !*FakeTransport {
        const self = try allocator.create(FakeTransport);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn transport(self: *FakeTransport) Transport {
        return .{ .vtable = &vtable, .ctx = @ptrCast(self) };
    }

    pub fn enqueue(self: *FakeTransport, d: Delta) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pending.append(self.allocator, d);
    }

    fn destroyImpl(ctx_opt: ?*anyopaque, allocator: Allocator) void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        _ = allocator;
        self.mutex.lock();
        for (self.pending.items) |d| freeDelta(self.allocator, d);
        self.pending.deinit(self.allocator);
        for (self.writes.items) |w| {
            self.allocator.free(w.action);
            self.allocator.free(w.payload);
        }
        self.writes.deinit(self.allocator);
        for (self.pty_writes.items) |w| self.allocator.free(w.bytes);
        self.pty_writes.deinit(self.allocator);
        self.resizes.deinit(self.allocator);
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    fn subscribeImpl(ctx_opt: ?*anyopaque, shape: []const u8, params_json: []const u8) !u64 {
        _ = shape;
        _ = params_json;
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_sub_id;
        self.next_sub_id += 1;
        return id;
    }

    fn unsubscribeImpl(_: ?*anyopaque, _: u64) !void {}

    fn writeImpl(ctx_opt: ?*anyopaque, action: []const u8, payload_json: []const u8) !u64 {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const f = self.next_future;
        self.next_future += 1;
        try self.writes.append(self.allocator, .{
            .future = f,
            .action = try self.allocator.dupe(u8, action),
            .payload = try self.allocator.dupe(u8, payload_json),
        });
        return f;
    }

    fn attachPtyImpl(ctx_opt: ?*anyopaque, _: []const u8) !u64 {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const h = self.next_pty;
        self.next_pty += 1;
        return h;
    }

    fn ptyWriteImpl(ctx_opt: ?*anyopaque, handle: u64, bytes: []const u8) !void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pty_writes.append(self.allocator, .{
            .handle = handle,
            .bytes = try self.allocator.dupe(u8, bytes),
        });
    }

    fn ptyResizeImpl(ctx_opt: ?*anyopaque, handle: u64, cols: u16, rows: u16) !void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.resizes.append(self.allocator, .{ .handle = handle, .cols = cols, .rows = rows });
    }

    fn ptyDetachImpl(_: ?*anyopaque, _: u64) !void {}

    fn tickImpl(ctx_opt: ?*anyopaque, out: *std.ArrayList(Delta), allocator: Allocator) !void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.pending.items) |d| {
            try out.append(allocator, try dupDelta(allocator, d));
            freeDelta(self.allocator, d);
        }
        self.pending.clearRetainingCapacity();
    }

    pub const vtable: VTable = .{
        .subscribe = subscribeImpl,
        .unsubscribe = unsubscribeImpl,
        .write = writeImpl,
        .attachPty = attachPtyImpl,
        .ptyWrite = ptyWriteImpl,
        .ptyResize = ptyResizeImpl,
        .ptyDetach = ptyDetachImpl,
        .tick = tickImpl,
        .destroy = destroyImpl,
    };
};

// -----------------------------------------------------------------------
// RealTransport — promoted Electric + WebSocket PTY + HTTP-writes
// implementation. Replaces the 0120 skeleton.
// -----------------------------------------------------------------------

/// Action-kind → plue REST route mapping. The action kind is what Swift
/// sends into `smithers_core_write`; this table translates into the HTTP
/// method + path (a `{owner}/{repo}` pair is interpolated from the payload,
/// which must carry `repo_owner` + `repo_name` fields).
///
/// Unknown action kinds are rejected explicitly. There is no
/// `/api/actions/<kind>` fallback.
const RouteTemplate = struct {
    method: electric.http.WriteMethod = .POST,
    /// Path with `{id}` placeholders to be substituted from payload fields.
    path: []const u8,
    /// Payload field names to substitute into `{id}` / `{id2}` placeholders,
    /// in order. Empty for routes without placeholders.
    placeholders: []const []const u8 = &.{},
};

pub const ResolveActionPathError = error{
    UnknownActionKind,
    MissingField,
    InvalidPayload,
    OutOfMemory,
};

pub const ResolvedActionPath = struct {
    method: electric.http.WriteMethod,
    path: []u8,
};

const routes = std.StaticStringMap(RouteTemplate).initComptime(.{
    .{ "approval.decide", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/approvals/{id}/decide",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "approval_id" },
    } },
    .{ "agent_session.create", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/agent/sessions",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name" },
    } },
    .{ "agent_session.delete", RouteTemplate{
        .method = .DELETE,
        .path = "/api/repos/{owner}/{repo}/agent/sessions/{id}",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "session_id" },
    } },
    .{ "agent_session.append_message", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/agent/sessions/{id}/messages",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "session_id" },
    } },
    .{ "workspace.create", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/workspaces",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name" },
    } },
    .{ "workspace.fork", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/workspaces/{id}/fork",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "workspace_id" },
    } },
    .{ "workspace.delete", RouteTemplate{
        .method = .DELETE,
        .path = "/api/repos/{owner}/{repo}/workspaces/{id}",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "workspace_id" },
    } },
    .{ "workspace.suspend", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/workspaces/{id}/suspend",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "workspace_id" },
    } },
    .{ "workspace.resume", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/workspaces/{id}/resume",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "workspace_id" },
    } },
    .{ "workspace_snapshot.create", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/workspaces/{id}/snapshot",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "workspace_id" },
    } },
    .{ "workspace_snapshot.delete", RouteTemplate{
        .method = .DELETE,
        .path = "/api/repos/{owner}/{repo}/workspace-snapshots/{id}",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "snapshot_id" },
    } },
    .{ "workflow_run.cancel", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/runs/{id}/cancel",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "run_id" },
    } },
    .{ "workflow_run.rerun", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/runs/{id}/rerun",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "run_id" },
    } },
    .{ "workflow_run.resume", RouteTemplate{
        .path = "/api/repos/{owner}/{repo}/runs/{id}/resume",
        .placeholders = &[_][]const u8{ "repo_owner", "repo_name", "run_id" },
    } },
});

/// Resolve a concrete HTTP method + URL path from an action kind + payload
/// JSON. Caller owns the returned path slice. Returns an error if the kind
/// is unknown or a required placeholder is missing — the write future is
/// NACK'd with status 400.
pub fn resolveActionPath(
    allocator: Allocator,
    action_kind: []const u8,
    payload_json: []const u8,
) ResolveActionPathError!ResolvedActionPath {
    const template = routes.get(action_kind) orelse return error.UnknownActionKind;

    if (template.placeholders.len == 0) {
        return .{
            .method = template.method,
            .path = allocator.dupe(u8, template.path) catch return error.OutOfMemory,
        };
    }

    // Parse payload to pull field values.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        return error.InvalidPayload;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Substitute `{owner}` → repo_owner, `{repo}` → repo_name, `{id}` → first
    // non-repo placeholder. Template patterns are fixed strings so this
    // substitution is simple search/replace.
    var remaining = template.path;
    // Simple tokenizer: walk placeholders in order, substituting the first
    // occurrence of each.
    for (template.placeholders, 0..) |field, idx| {
        const tok: []const u8 = switch (idx) {
            0 => "{owner}",
            1 => "{repo}",
            else => "{id}",
        };
        const v = obj.get(field) orelse return error.MissingField;
        // Resolve `val` into a buffer that outlives the appendSlice call.
        // For string values that's the parsed-json-owned slice; for ints we
        // stash into a fixed-size stack buffer.
        var int_buf: [32]u8 = undefined;
        const val: []const u8 = switch (v) {
            .string => |s| s,
            .integer => |n| std.fmt.bufPrint(&int_buf, "{d}", .{n}) catch return error.InvalidPayload,
            else => return error.InvalidPayload,
        };
        const pos = std.mem.indexOf(u8, remaining, tok) orelse return error.MissingField;
        out.appendSlice(allocator, remaining[0..pos]) catch return error.OutOfMemory;
        out.appendSlice(allocator, val) catch return error.OutOfMemory;
        remaining = remaining[pos + tok.len ..];
    }
    out.appendSlice(allocator, remaining) catch return error.OutOfMemory;
    return .{
        .method = template.method,
        .path = out.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

/// Opaque hook used by RealTransport to fetch a fresh bearer. Ultimately
/// backed by `Core.fetchCredentials`. Returns owned bearer + refresh_token
/// duped into the transport allocator.
pub const CredentialsRefresher = struct {
    ctx: ?*anyopaque,
    fetch_fn: *const fn (ctx: ?*anyopaque, allocator: Allocator) anyerror!BearerSnapshot,

    pub const BearerSnapshot = struct {
        bearer: []u8, // allocator-owned
    };
};

/// Configuration the Session hands to RealTransport at create-time.
pub const RealConfig = struct {
    /// Host for Electric shape proxy (e.g. plue's `/v1/shape` endpoint).
    shape_host: []const u8,
    shape_port: u16,
    /// Host for plue HTTP REST API (writes).
    api_host: []const u8,
    api_port: u16,
    /// Host for WebSocket PTY.
    ws_host: []const u8,
    ws_port: u16,
    /// Origin header value. plue's proxy rejects mismatched Origins.
    origin: []const u8,
};

const SubscriptionWorker = struct {
    parent: *RealTransport,
    sub_id: u64,
    shape_owned: []u8,
    params_owned: []u8,
    shape_key_owned: []u8,
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const PtyWorker = struct {
    parent: *RealTransport,
    handle: u64,
    client: ?wspty.Client = null,
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_mutex: std.Thread.Mutex = .{},
};

pub const RealTransport = struct {
    allocator: Allocator,
    cfg: RealConfig,
    cfg_storage: CfgStorage,
    cache: *CacheMod.Cache,
    creds: CredentialsRefresher,

    mutex: std.Thread.Mutex = .{},
    pending: std.ArrayList(Delta) = .empty,

    next_sub_id: u64 = 1,
    next_future: u64 = 1,
    next_pty: u64 = 1,

    subscriptions: std.ArrayList(*SubscriptionWorker) = .empty,
    pty_workers: std.ArrayList(*PtyWorker) = .empty,
    write_threads: std.ArrayList(std.Thread) = .empty,
    /// Tripped on destroy; write threads observe it and bail before
    /// touching any pending-queue state that destroy has already torn
    /// down.
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const CfgStorage = struct {
        shape_host: []u8,
        api_host: []u8,
        ws_host: []u8,
        origin: []u8,
    };

    pub fn create(
        allocator: Allocator,
        cache: *CacheMod.Cache,
        cfg_in: RealConfig,
        creds: CredentialsRefresher,
    ) !*RealTransport {
        const self = try allocator.create(RealTransport);
        errdefer allocator.destroy(self);

        const storage: CfgStorage = .{
            .shape_host = try allocator.dupe(u8, cfg_in.shape_host),
            .api_host = try allocator.dupe(u8, cfg_in.api_host),
            .ws_host = try allocator.dupe(u8, cfg_in.ws_host),
            .origin = try allocator.dupe(u8, cfg_in.origin),
        };

        self.* = .{
            .allocator = allocator,
            .cfg = .{
                .shape_host = storage.shape_host,
                .shape_port = cfg_in.shape_port,
                .api_host = storage.api_host,
                .api_port = cfg_in.api_port,
                .ws_host = storage.ws_host,
                .ws_port = cfg_in.ws_port,
                .origin = storage.origin,
            },
            .cfg_storage = storage,
            .cache = cache,
            .creds = creds,
        };
        return self;
    }

    pub fn transport(self: *RealTransport) Transport {
        return .{ .vtable = &vtable, .ctx = @ptrCast(self) };
    }

    pub const vtable: VTable = .{
        .subscribe = subscribeImpl,
        .unsubscribe = unsubscribeImpl,
        .write = writeImpl,
        .attachPty = attachPtyImpl,
        .ptyWrite = ptyWriteImpl,
        .ptyResize = ptyResizeImpl,
        .ptyDetach = ptyDetachImpl,
        .tick = tickImpl,
        .destroy = destroyImpl,
    };

    // --- Pending queue helpers ---------------------------------------

    fn enqueueDelta(self: *RealTransport, d: Delta) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending.append(self.allocator, d) catch {
            // Best-effort: drop on OOM rather than crashing the worker.
            freeDelta(self.allocator, d);
        };
    }

    // --- Subscribe ---------------------------------------------------

    fn subscribeImpl(ctx_opt: ?*anyopaque, shape: []const u8, params_json: []const u8) !u64 {
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        const sub_id = self.next_sub_id;
        self.next_sub_id += 1;
        self.mutex.unlock();

        const shape_owned = try self.allocator.dupe(u8, shape);
        errdefer self.allocator.free(shape_owned);
        const params_owned = try self.allocator.dupe(u8, params_json);
        errdefer self.allocator.free(params_owned);
        const shape_key = try std.fmt.allocPrint(self.allocator, "{s}:{x}", .{ shape, std.hash.Wyhash.hash(0, params_json) });
        errdefer self.allocator.free(shape_key);

        const worker = try self.allocator.create(SubscriptionWorker);
        errdefer self.allocator.destroy(worker);
        worker.* = .{
            .parent = self,
            .sub_id = sub_id,
            .shape_owned = shape_owned,
            .params_owned = params_owned,
            .shape_key_owned = shape_key,
        };

        self.mutex.lock();
        try self.subscriptions.append(self.allocator, worker);
        self.mutex.unlock();

        worker.thread = try std.Thread.spawn(.{}, subscriptionThread, .{worker});
        return sub_id;
    }

    fn unsubscribeImpl(ctx_opt: ?*anyopaque, sub_id: u64) !void {
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));

        var worker_opt: ?*SubscriptionWorker = null;
        self.mutex.lock();
        var i: usize = 0;
        while (i < self.subscriptions.items.len) : (i += 1) {
            if (self.subscriptions.items[i].sub_id == sub_id) {
                worker_opt = self.subscriptions.items[i];
                _ = self.subscriptions.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock();

        const worker = worker_opt orelse return;
        worker.cancel.store(true, .release);
        if (worker.thread) |t| t.join();
        self.destroySubWorker(worker);
    }

    fn destroySubWorker(self: *RealTransport, worker: *SubscriptionWorker) void {
        self.allocator.free(worker.shape_owned);
        self.allocator.free(worker.params_owned);
        self.allocator.free(worker.shape_key_owned);
        self.allocator.destroy(worker);
    }

    // --- Write -------------------------------------------------------

    const WriteJob = struct {
        parent: *RealTransport,
        future: u64,
        action: []u8,
        payload: []u8,
    };

    fn writeImpl(ctx_opt: ?*anyopaque, action: []const u8, payload_json: []const u8) !u64 {
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        const fut = self.next_future;
        self.next_future += 1;
        self.mutex.unlock();

        const job = try self.allocator.create(WriteJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .parent = self,
            .future = fut,
            .action = try self.allocator.dupe(u8, action),
            .payload = try self.allocator.dupe(u8, payload_json),
        };
        errdefer self.allocator.free(job.action);
        errdefer self.allocator.free(job.payload);

        // One-shot worker. We keep the join handle so destroy() can
        // block on in-flight writes; acks arrive via the pending queue.
        const thread = try std.Thread.spawn(.{}, writeThread, .{job});
        self.mutex.lock();
        self.write_threads.append(self.allocator, thread) catch {
            self.mutex.unlock();
            thread.detach(); // fall back; destroy will race, shutting_down saves us.
            return fut;
        };
        self.mutex.unlock();
        return fut;
    }

    // --- PTY ---------------------------------------------------------

    fn attachPtyImpl(ctx_opt: ?*anyopaque, session_id: []const u8) !u64 {
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));

        self.mutex.lock();
        const handle = self.next_pty;
        self.next_pty += 1;
        self.mutex.unlock();

        const worker = try self.allocator.create(PtyWorker);
        errdefer self.allocator.destroy(worker);
        worker.* = .{ .parent = self, .handle = handle };

        // Fetch bearer once for handshake; refreshes are out of scope per
        // 0094 — a WS reconnect path (0140 follow-up) will re-handshake.
        const snap = self.creds.fetch_fn(self.creds.ctx, self.allocator) catch {
            return error.TransportError;
        };
        defer self.allocator.free(snap.bearer);

        const path = try std.fmt.allocPrint(
            self.allocator,
            "/api/workspace/sessions/{s}/terminal",
            .{session_id},
        );
        defer self.allocator.free(path);

        const client = wspty.Client.connect(self.allocator, .{
            .host = self.cfg.ws_host,
            .port = self.cfg.ws_port,
            .path = path,
            .origin = self.cfg.origin,
            .bearer = snap.bearer,
            .subprotocol = "terminal",
        }) catch {
            return error.TransportError;
        };
        worker.client = client;

        self.mutex.lock();
        try self.pty_workers.append(self.allocator, worker);
        self.mutex.unlock();

        worker.thread = try std.Thread.spawn(.{}, ptyReaderThread, .{worker});
        return handle;
    }

    fn findPtyWorker(self: *RealTransport, handle: u64) ?*PtyWorker {
        for (self.pty_workers.items) |w| {
            if (w.handle == handle) return w;
        }
        return null;
    }

    fn ptyWriteImpl(ctx_opt: ?*anyopaque, handle: u64, bytes: []const u8) !void {
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        const worker = self.findPtyWorker(handle) orelse {
            self.mutex.unlock();
            return error.InvalidArgument;
        };
        self.mutex.unlock();
        worker.write_mutex.lock();
        defer worker.write_mutex.unlock();
        if (worker.client) |*c| {
            c.writeBinary(bytes) catch return error.TransportError;
        }
    }

    fn ptyResizeImpl(ctx_opt: ?*anyopaque, handle: u64, cols: u16, rows: u16) !void {
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        const worker = self.findPtyWorker(handle) orelse {
            self.mutex.unlock();
            return error.InvalidArgument;
        };
        self.mutex.unlock();
        worker.write_mutex.lock();
        defer worker.write_mutex.unlock();
        if (worker.client) |*c| {
            c.sendResize(cols, rows) catch return error.TransportError;
        }
    }

    fn ptyDetachImpl(ctx_opt: ?*anyopaque, handle: u64) !void {
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));

        var worker_opt: ?*PtyWorker = null;
        self.mutex.lock();
        var i: usize = 0;
        while (i < self.pty_workers.items.len) : (i += 1) {
            if (self.pty_workers.items[i].handle == handle) {
                worker_opt = self.pty_workers.items[i];
                _ = self.pty_workers.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock();

        const worker = worker_opt orelse return;
        worker.cancel.store(true, .release);
        // Send a close frame so the reader thread exits cleanly.
        worker.write_mutex.lock();
        if (worker.client) |*c| c.close(1000, "detach") catch {};
        worker.write_mutex.unlock();
        if (worker.thread) |t| t.join();
        if (worker.client) |*c| c.deinit();
        self.allocator.destroy(worker);
    }

    // --- Tick / Destroy ----------------------------------------------

    fn tickImpl(ctx_opt: ?*anyopaque, out: *std.ArrayList(Delta), allocator: Allocator) !void {
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.pending.items) |d| {
            try out.append(allocator, try dupDelta(allocator, d));
            freeDelta(self.allocator, d);
        }
        self.pending.clearRetainingCapacity();
    }

    fn destroyImpl(ctx_opt: ?*anyopaque, allocator: Allocator) void {
        _ = allocator;
        const self: *RealTransport = @ptrCast(@alignCast(ctx_opt.?));

        self.shutting_down.store(true, .release);

        // Signal + join all workers.
        self.mutex.lock();
        const subs = self.subscriptions.toOwnedSlice(self.allocator) catch &[_]*SubscriptionWorker{};
        const ptys = self.pty_workers.toOwnedSlice(self.allocator) catch &[_]*PtyWorker{};
        const writes = self.write_threads.toOwnedSlice(self.allocator) catch &[_]std.Thread{};
        self.mutex.unlock();

        for (writes) |t| t.join();
        self.allocator.free(writes);

        for (subs) |w| w.cancel.store(true, .release);
        for (ptys) |w| {
            w.cancel.store(true, .release);
            w.write_mutex.lock();
            if (w.client) |*c| c.close(1000, "shutdown") catch {};
            w.write_mutex.unlock();
        }
        for (subs) |w| {
            if (w.thread) |t| t.join();
            self.destroySubWorker(w);
        }
        for (ptys) |w| {
            if (w.thread) |t| t.join();
            if (w.client) |*c| c.deinit();
            self.allocator.destroy(w);
        }
        self.allocator.free(subs);
        self.allocator.free(ptys);

        // Drain any leftover deltas.
        self.mutex.lock();
        for (self.pending.items) |d| freeDelta(self.allocator, d);
        self.pending.deinit(self.allocator);
        self.subscriptions.deinit(self.allocator);
        self.pty_workers.deinit(self.allocator);
        self.write_threads.deinit(self.allocator);
        self.mutex.unlock();

        self.allocator.free(self.cfg_storage.shape_host);
        self.allocator.free(self.cfg_storage.api_host);
        self.allocator.free(self.cfg_storage.ws_host);
        self.allocator.free(self.cfg_storage.origin);
        self.allocator.destroy(self);
    }
};

// -----------------------------------------------------------------------
// Worker thread bodies.
// -----------------------------------------------------------------------

fn subscriptionThread(worker: *SubscriptionWorker) void {
    const self = worker.parent;

    // Fetch initial bearer.
    const snap0 = self.creds.fetch_fn(self.creds.ctx, self.allocator) catch {
        self.enqueueDelta(.auth_expired);
        return;
    };
    var bearer: []u8 = snap0.bearer;
    defer self.allocator.free(bearer);

    const cursor_store_vt = electricCursorStore();
    const sink_vt = electricSink();

    var ec = electric.Client.init(
        self.allocator,
        .{
            .host = self.cfg.shape_host,
            .port = self.cfg.shape_port,
            .table = worker.shape_owned,
            .where = worker.params_owned,
            .bearer = bearer,
            .shape_key = worker.shape_key_owned,
        },
        .{
            .ctx = @ptrCast(self),
            .load_fn = cursor_store_vt.load_fn,
            .save_fn = cursor_store_vt.save_fn,
            .delete_fn = cursor_store_vt.delete_fn,
        },
        .{
            .ctx = @ptrCast(self),
            .on_upsert = sink_vt.on_upsert,
            .on_delete = sink_vt.on_delete,
            .on_up_to_date = sink_vt.on_up_to_date,
            .on_must_refetch = sink_vt.on_must_refetch,
        },
    ) catch {
        self.enqueueDelta(.auth_expired);
        return;
    };
    defer ec.deinit();

    // Long-poll loop. First iteration is non-live (snapshot fetch);
    // thereafter live=true with server-side 20s timeout.
    var live = false;
    while (!worker.cancel.load(.acquire)) {
        _ = ec.pollOnce(live) catch |e| switch (e) {
            electric.Error.Unauthorized => {
                // Token refresh: fetch once; retry this iteration.
                const snap = self.creds.fetch_fn(self.creds.ctx, self.allocator) catch {
                    self.enqueueDelta(.auth_expired);
                    return;
                };
                self.allocator.free(bearer);
                bearer = snap.bearer;
                ec.setBearer(bearer);
                continue;
            },
            electric.Error.AlreadyClosed => return,
            else => {
                // Any other error: back off in ~50ms ticks so cancel
                // interrupts within at most one tick.
                var waited: u32 = 0;
                while (waited < 10 and !worker.cancel.load(.acquire)) : (waited += 1) {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                }
                continue;
            },
        };
        live = true;
    }
}

fn writeThread(job: *RealTransport.WriteJob) void {
    const self = job.parent;
    defer {
        self.allocator.free(job.action);
        self.allocator.free(job.payload);
        self.allocator.destroy(job);
    }

    // Fetch bearer.
    const bearer_snap = self.creds.fetch_fn(self.creds.ctx, self.allocator) catch {
        const body = self.allocator.dupe(u8, "{\"error\":\"auth_expired\"}") catch return;
        self.enqueueDelta(.{ .write_ack = .{ .future = job.future, .ok = false, .status = 401, .body = body } });
        self.enqueueDelta(.auth_expired);
        return;
    };
    var owned_bearer = bearer_snap.bearer;
    defer self.allocator.free(owned_bearer);

    const resolved = resolveActionPath(self.allocator, job.action, job.payload) catch |e| {
        const msg = switch (e) {
            error.UnknownActionKind => "{\"error\":\"unknown_action_kind\"}",
            error.MissingField => "{\"error\":\"missing_field\"}",
            error.InvalidPayload => "{\"error\":\"invalid_payload\"}",
            else => "{\"error\":\"route_resolution_failed\"}",
        };
        const body = self.allocator.dupe(u8, msg) catch return;
        self.enqueueDelta(.{ .write_ack = .{ .future = job.future, .ok = false, .status = 400, .body = body } });
        return;
    };
    defer self.allocator.free(resolved.path);

    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        var resp = switch (resolved.method) {
            .POST => electric.http.post(self.allocator, .{
                .host = self.cfg.api_host,
                .port = self.cfg.api_port,
                .path_and_query = resolved.path,
                .bearer = owned_bearer,
            }, job.payload),
            .DELETE => electric.http.delete(self.allocator, .{
                .host = self.cfg.api_host,
                .port = self.cfg.api_port,
                .path_and_query = resolved.path,
                .bearer = owned_bearer,
            }, job.payload),
        } catch {
            const body = self.allocator.dupe(u8, "{\"error\":\"io_error\"}") catch return;
            self.enqueueDelta(.{ .write_ack = .{ .future = job.future, .ok = false, .status = 0, .body = body } });
            return;
        };
        defer resp.deinit();

        if (resp.status == 401 and attempt == 0) {
            // Retry once after a creds refresh.
            const snap = self.creds.fetch_fn(self.creds.ctx, self.allocator) catch {
                const body = self.allocator.dupe(u8, "{\"error\":\"auth_expired\"}") catch return;
                self.enqueueDelta(.{ .write_ack = .{ .future = job.future, .ok = false, .status = 401, .body = body } });
                self.enqueueDelta(.auth_expired);
                return;
            };
            self.allocator.free(owned_bearer);
            owned_bearer = snap.bearer;
            continue;
        }

        const ok = resp.status >= 200 and resp.status < 300;
        const body_dup = self.allocator.dupe(u8, resp.body) catch return;
        self.enqueueDelta(.{ .write_ack = .{
            .future = job.future,
            .ok = ok,
            .status = resp.status,
            .body = body_dup,
        } });
        if (resp.status == 401) self.enqueueDelta(.auth_expired);
        return;
    }
}

fn ptyReaderThread(worker: *PtyWorker) void {
    const self = worker.parent;
    while (!worker.cancel.load(.acquire)) {
        // readEvent is blocking. When close() was called on another
        // thread, the server should emit its own close frame and our
        // read will return PeerClosed / AbruptDisconnect, breaking the
        // loop.
        const ev = if (worker.client) |*c| blk: {
            const r = c.readEvent() catch {
                self.enqueueDelta(.{ .pty_closed = .{ .handle = worker.handle } });
                return;
            };
            break :blk r;
        } else return;

        switch (ev.kind) {
            .binary => {
                const bytes = self.allocator.dupe(u8, ev.payload) catch continue;
                self.enqueueDelta(.{ .pty_data = .{ .handle = worker.handle, .bytes = bytes } });
            },
            .text => {
                // Plue occasionally emits text status messages; forward as
                // bytes for now.
                const bytes = self.allocator.dupe(u8, ev.payload) catch continue;
                self.enqueueDelta(.{ .pty_data = .{ .handle = worker.handle, .bytes = bytes } });
            },
            .close => {
                self.enqueueDelta(.{ .pty_closed = .{ .handle = worker.handle } });
                return;
            },
            .ping, .pong => {
                // Auto-ponged inside wspty; no delta needed.
            },
        }
    }
}

// -----------------------------------------------------------------------
// Electric CursorStore + Sink vtables — glue between electric/ and
// RealTransport's cache + pending queue.
// -----------------------------------------------------------------------

fn electricCursorStore() struct {
    load_fn: *const fn (ctx: ?*anyopaque, shape_key: []const u8, allocator: Allocator) anyerror!?electric.CursorStore.Cursor,
    save_fn: *const fn (ctx: ?*anyopaque, shape_key: []const u8, handle: []const u8, offset: []const u8) anyerror!void,
    delete_fn: *const fn (ctx: ?*anyopaque, shape_key: []const u8) anyerror!void,
} {
    return .{
        .load_fn = cursorLoad,
        .save_fn = cursorSave,
        .delete_fn = cursorDelete,
    };
}

fn cursorLoad(ctx: ?*anyopaque, shape_key: []const u8, allocator: Allocator) anyerror!?electric.CursorStore.Cursor {
    // For 0140 we don't persist the Electric shape cursor separately —
    // it lives on the cache's subscription row, but RealTransport doesn't
    // know the cache subscription id (session.zig registers that). So we
    // always return null; the long-poll starts from offset=-1 on each
    // session boot. Resuming across process restarts is a 0140-followup.
    _ = ctx;
    _ = shape_key;
    _ = allocator;
    return null;
}

fn cursorSave(ctx: ?*anyopaque, shape_key: []const u8, handle: []const u8, offset: []const u8) anyerror!void {
    // The session receives `up_to_date` deltas and persists cursors via
    // `cache.updateCursor` keyed by subscription_id. No-op here.
    _ = ctx;
    _ = shape_key;
    _ = handle;
    _ = offset;
}

fn cursorDelete(ctx: ?*anyopaque, shape_key: []const u8) anyerror!void {
    _ = ctx;
    _ = shape_key;
}

fn electricSink() struct {
    on_upsert: *const fn (ctx: ?*anyopaque, shape: []const u8, pk: []const u8, row_json: []const u8) anyerror!void,
    on_delete: *const fn (ctx: ?*anyopaque, shape: []const u8, pk: []const u8) anyerror!void,
    on_up_to_date: *const fn (ctx: ?*anyopaque, shape: []const u8, handle: []const u8, offset: []const u8) anyerror!void,
    on_must_refetch: *const fn (ctx: ?*anyopaque, shape: []const u8) anyerror!void,
} {
    return .{
        .on_upsert = sinkUpsert,
        .on_delete = sinkDelete,
        .on_up_to_date = sinkUpToDate,
        .on_must_refetch = sinkMustRefetch,
    };
}

fn sinkUpsert(ctx: ?*anyopaque, shape: []const u8, pk: []const u8, row_json: []const u8) anyerror!void {
    const self: *RealTransport = @ptrCast(@alignCast(ctx.?));
    self.enqueueDelta(.{ .row_upsert = .{
        .shape = try self.allocator.dupe(u8, shape),
        .pk = try self.allocator.dupe(u8, pk),
        .row_json = try self.allocator.dupe(u8, row_json),
    } });
}

fn sinkDelete(ctx: ?*anyopaque, shape: []const u8, pk: []const u8) anyerror!void {
    const self: *RealTransport = @ptrCast(@alignCast(ctx.?));
    self.enqueueDelta(.{ .row_delete = .{
        .shape = try self.allocator.dupe(u8, shape),
        .pk = try self.allocator.dupe(u8, pk),
    } });
}

fn sinkUpToDate(ctx: ?*anyopaque, shape: []const u8, handle: []const u8, offset: []const u8) anyerror!void {
    const self: *RealTransport = @ptrCast(@alignCast(ctx.?));
    self.enqueueDelta(.{ .up_to_date = .{
        .shape = try self.allocator.dupe(u8, shape),
        .handle = try self.allocator.dupe(u8, handle),
        .offset = try self.allocator.dupe(u8, offset),
    } });
}

fn sinkMustRefetch(ctx: ?*anyopaque, shape: []const u8) anyerror!void {
    const self: *RealTransport = @ptrCast(@alignCast(ctx.?));
    self.enqueueDelta(.{ .must_refetch = .{
        .shape = try self.allocator.dupe(u8, shape),
    } });
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "FakeTransport: subscribe/unsubscribe" {
    const ft = try FakeTransport.create(testing.allocator);
    defer ft.transport().destroy(testing.allocator);
    const t = ft.transport();
    const sub = try t.subscribe("agent_sessions", "{\"repo\":1}");
    try testing.expect(sub != 0);
    try t.unsubscribe(sub);
}

test "FakeTransport: enqueue + tick surfaces deltas" {
    const ft = try FakeTransport.create(testing.allocator);
    defer ft.transport().destroy(testing.allocator);

    try ft.enqueue(.{ .row_upsert = .{
        .shape = try testing.allocator.dupe(u8, "agent_sessions"),
        .pk = try testing.allocator.dupe(u8, "as_1"),
        .row_json = try testing.allocator.dupe(u8, "{\"v\":1}"),
    } });

    var out: std.ArrayList(Delta) = .empty;
    defer {
        for (out.items) |d| freeDelta(testing.allocator, d);
        out.deinit(testing.allocator);
    }
    try ft.transport().tick(&out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    switch (out.items[0]) {
        .row_upsert => |v| try testing.expectEqualStrings("as_1", v.pk),
        else => try testing.expect(false),
    }
}

test "FakeTransport: write records action + fires via enqueued ack" {
    const ft = try FakeTransport.create(testing.allocator);
    defer ft.transport().destroy(testing.allocator);
    const t = ft.transport();
    const fut = try t.write("agent_session.create", "{\"title\":\"hi\"}");
    try testing.expect(fut != 0);
    try testing.expectEqual(@as(usize, 1), ft.writes.items.len);
    try testing.expectEqualStrings("agent_session.create", ft.writes.items[0].action);
}

test "FakeTransport: PTY attach/write/resize/detach flow" {
    const ft = try FakeTransport.create(testing.allocator);
    defer ft.transport().destroy(testing.allocator);
    const t = ft.transport();
    const h = try t.attachPty("session_abc");
    try testing.expect(h != 0);
    try t.ptyWrite(h, "ls\n");
    try t.ptyResize(h, 80, 24);
    try t.ptyDetach(h);
    try testing.expectEqual(@as(usize, 1), ft.pty_writes.items.len);
    try testing.expectEqualStrings("ls\n", ft.pty_writes.items[0].bytes);
    try testing.expectEqual(@as(u16, 80), ft.resizes.items[0].cols);
    try testing.expectEqual(@as(u16, 24), ft.resizes.items[0].rows);
}

fn expectResolved(
    action_kind: []const u8,
    payload_json: []const u8,
    expected_method: electric.http.WriteMethod,
    expected_path: []const u8,
) !void {
    const resolved = try resolveActionPath(testing.allocator, action_kind, payload_json);
    defer testing.allocator.free(resolved.path);
    try testing.expectEqual(expected_method, resolved.method);
    try testing.expectEqualStrings(expected_path, resolved.path);
}

test "resolveActionPath: workspace.create" {
    try expectResolved(
        "workspace.create",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\"}",
        .POST,
        "/api/repos/acme/widgets/workspaces",
    );
}

test "resolveActionPath: workspace.suspend" {
    try expectResolved(
        "workspace.suspend",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"workspace_id\":\"ws_1\"}",
        .POST,
        "/api/repos/acme/widgets/workspaces/ws_1/suspend",
    );
}

test "resolveActionPath: workspace.resume" {
    try expectResolved(
        "workspace.resume",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"workspace_id\":\"ws_1\"}",
        .POST,
        "/api/repos/acme/widgets/workspaces/ws_1/resume",
    );
}

test "resolveActionPath: workspace.delete" {
    try expectResolved(
        "workspace.delete",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"workspace_id\":\"ws_1\"}",
        .DELETE,
        "/api/repos/acme/widgets/workspaces/ws_1",
    );
}

test "resolveActionPath: workspace.fork" {
    try expectResolved(
        "workspace.fork",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"workspace_id\":\"ws_1\"}",
        .POST,
        "/api/repos/acme/widgets/workspaces/ws_1/fork",
    );
}

test "resolveActionPath: workspace_snapshot.create" {
    try expectResolved(
        "workspace_snapshot.create",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"workspace_id\":\"ws_1\"}",
        .POST,
        "/api/repos/acme/widgets/workspaces/ws_1/snapshot",
    );
}

test "resolveActionPath: workspace_snapshot.delete" {
    try expectResolved(
        "workspace_snapshot.delete",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"snapshot_id\":\"snap_1\"}",
        .DELETE,
        "/api/repos/acme/widgets/workspace-snapshots/snap_1",
    );
}

test "resolveActionPath: workflow_run.cancel" {
    try expectResolved(
        "workflow_run.cancel",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"run_id\":123}",
        .POST,
        "/api/repos/acme/widgets/runs/123/cancel",
    );
}

test "resolveActionPath: workflow_run.rerun" {
    try expectResolved(
        "workflow_run.rerun",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"run_id\":\"run_1\"}",
        .POST,
        "/api/repos/acme/widgets/runs/run_1/rerun",
    );
}

test "resolveActionPath: workflow_run.resume" {
    try expectResolved(
        "workflow_run.resume",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"run_id\":\"run_1\"}",
        .POST,
        "/api/repos/acme/widgets/runs/run_1/resume",
    );
}

test "resolveActionPath: approval.decide" {
    try expectResolved(
        "approval.decide",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"approval_id\":\"a_42\"}",
        .POST,
        "/api/repos/acme/widgets/approvals/a_42/decide",
    );
}

test "resolveActionPath: agent_session.create" {
    try expectResolved(
        "agent_session.create",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"title\":\"triage\"}",
        .POST,
        "/api/repos/acme/widgets/agent/sessions",
    );
}

test "resolveActionPath: agent_session.delete" {
    try expectResolved(
        "agent_session.delete",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"session_id\":\"sess_1\"}",
        .DELETE,
        "/api/repos/acme/widgets/agent/sessions/sess_1",
    );
}

test "resolveActionPath: agent_session.append_message" {
    try expectResolved(
        "agent_session.append_message",
        "{\"repo_owner\":\"acme\",\"repo_name\":\"widgets\",\"session_id\":\"sess_1\"}",
        .POST,
        "/api/repos/acme/widgets/agent/sessions/sess_1/messages",
    );
}

test "resolveActionPath: unknown kind errors" {
    const p = resolveActionPath(testing.allocator, "custom.thing", "{}");
    try testing.expectError(error.UnknownActionKind, p);
}

test "resolveActionPath: missing field errors" {
    const r = resolveActionPath(testing.allocator, "approval.decide",
        \\{"repo_owner":"a"}
    );
    try testing.expectError(error.MissingField, r);
}
