//! Connection-scoped Session — the core primitive of the new runtime.
//!
//! Replaces the responsibilities of `src/session/session.zig`'s local-chat
//! fabrication (which is kept for the desktop-local compatibility shim,
//! REMOVE-AFTER-0126). One Session per engine connection. It owns:
//!   - Credentials (re-fetched from the Core on demand / 401).
//!   - A transport (Electric + WS + HTTP, or a test fake).
//!   - A bounded SQLite cache (schema.zig).
//!   - A subscription registry.
//!   - The event callback bridge to the host.
//!
//! Scope for this landing — see the module header in `core.zig`.

const std = @import("std");
const schema = @import("schema.zig");
const transport = @import("transport.zig");
const CacheMod = @import("cache.zig");

const core_mod = @import("core.zig");
const Core = core_mod.Core;
const Credentials = core_mod.Credentials;
const CoreError = core_mod.Error;

pub const EventTag = enum(i32) {
    state_changed = 0,
    auth_expired = 1,
    reconnect = 2,
    shape_delta = 3,
    write_ack = 4,
    pty_data = 5,
    pty_closed = 6,
};

pub const EventFn = *const fn (
    userdata: ?*anyopaque,
    tag: EventTag,
    payload_json_or_null: ?[*:0]const u8,
) callconv(.c) void;

pub const EngineConfig = struct {
    engine_id: []const u8,
    base_url: []const u8,
    shape_proxy_url: ?[]const u8 = null,
    ws_pty_url: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    cache_max_mb: u32 = 0,
};

pub const ConnectionState = enum { disconnected, connecting, connected, reconnecting };

/// Session-level subscription record — maps the public handle (monotonic
/// id we hand to the Swift side) to the cache row id + transport sub id.
const Subscription = struct {
    public_id: u64,
    cache_sub_id: i64,
    transport_sub_id: u64,
    shape: schema.Shape,
    shape_name_owned: []u8,
};

const PtyAttachment = struct {
    public_handle: u64,
    transport_handle: u64,
};

/// URL parse helper: split "scheme://host:port" into host + port. Defaults
/// to port 80 for `http://`, 443 for `https://`, 4000 if unspecified.
fn parseHostPort(url: []const u8, default_port: u16) !struct { host: []const u8, port: u16 } {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "ws://")) {
        rest = rest[5..];
    } else if (std.mem.startsWith(u8, rest, "wss://")) {
        rest = rest[6..];
    }
    // Trim trailing path.
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest = rest[0..i];
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        const host = rest[0..i];
        const port = try std.fmt.parseInt(u16, rest[i + 1 ..], 10);
        return .{ .host = host, .port = port };
    }
    return .{ .host = rest, .port = default_port };
}

/// Derive a `RealConfig` from the engine config strings. The engine
/// config carries full URLs; the real transport needs host + port
/// pairs for each of {shape proxy, API, WS PTY}.
fn derivedRealCfg(cfg_in: EngineConfig) !transport.RealConfig {
    const api = try parseHostPort(cfg_in.base_url, 4000);
    const shape = if (cfg_in.shape_proxy_url) |u|
        try parseHostPort(u, 3001)
    else
        api;
    const ws = if (cfg_in.ws_pty_url) |u|
        try parseHostPort(u, api.port)
    else
        api;
    return .{
        .shape_host = shape.host,
        .shape_port = shape.port,
        .api_host = api.host,
        .api_port = api.port,
        .ws_host = ws.host,
        .ws_port = ws.port,
        .origin = cfg_in.base_url,
    };
}

/// Credentials fetch trampoline for RealTransport. Turns
/// `Core.fetchCredentials()` into a `CredentialsRefresher.BearerSnapshot`
/// with an allocator-owned bearer.
fn coreCredsRefreshTrampoline(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) anyerror!transport.CredentialsRefresher.BearerSnapshot {
    const core: *Core = @ptrCast(@alignCast(ctx.?));
    const creds = core.fetchCredentials() catch return error.AuthExpired;
    return .{ .bearer = try allocator.dupe(u8, creds.bearer) };
}

pub const Session = struct {
    core: *Core,
    allocator: std.mem.Allocator,
    config: EngineConfig,
    config_storage: ConfigStorage,
    cache: *CacheMod.Cache,
    transport_impl: transport.Transport,
    // Owns the transport ctx — cleaned up on destroy.
    owns_transport: bool = true,

    mutex: std.Thread.Mutex = .{},
    state: ConnectionState = .disconnected,
    subscriptions: std.ArrayList(Subscription) = .empty,
    pty_attachments: std.ArrayList(PtyAttachment) = .empty,

    next_public_sub: u64 = 1,
    next_public_pty: u64 = 1,

    event_cb: ?EventFn = null,
    event_userdata: ?*anyopaque = null,

    tick_mutex: std.Thread.Mutex = .{},
    pump_thread: ?std.Thread = null,
    pump_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    auto_pump_enabled: bool = false,

    const ConfigStorage = struct {
        engine_id: []u8,
        base_url: []u8,
        shape_proxy_url: ?[]u8,
        ws_pty_url: ?[]u8,
        cache_dir: ?[]u8,
    };

    const pump_sleep_ns = 5 * std.time.ns_per_ms;

    pub fn create(core: *Core, cfg_in: EngineConfig) !*Session {
        const a = core.allocator;
        const self = try a.create(Session);
        errdefer a.destroy(self);

        const storage: ConfigStorage = .{
            .engine_id = try a.dupe(u8, cfg_in.engine_id),
            .base_url = try a.dupe(u8, cfg_in.base_url),
            .shape_proxy_url = if (cfg_in.shape_proxy_url) |v| try a.dupe(u8, v) else null,
            .ws_pty_url = if (cfg_in.ws_pty_url) |v| try a.dupe(u8, v) else null,
            .cache_dir = if (cfg_in.cache_dir) |v| try a.dupe(u8, v) else null,
        };
        errdefer {
            a.free(storage.engine_id);
            a.free(storage.base_url);
            if (storage.shape_proxy_url) |v| a.free(v);
            if (storage.ws_pty_url) |v| a.free(v);
            if (storage.cache_dir) |v| a.free(v);
        }

        const c = try CacheMod.Cache.openInMemory(a);
        errdefer c.close();
        // TODO(0120-followup): honour cfg_in.cache_dir for persistent path
        // once the macOS/iOS sandbox story for cache files is pinned in
        // 0121/0133.

        // Default to the real-transport path (0140). Tests opt into a
        // FakeTransport via `core.testing_use_fake_transport = true`, or
        // pass a full vtable via `core.transport_override`.
        var owns: bool = true;
        const t_impl: transport.Transport = blk: {
            if (core.transport_override) |vt| {
                owns = false;
                break :blk .{ .vtable = vt, .ctx = null };
            }
            if (core.testing_use_fake_transport) {
                const ft = try transport.FakeTransport.create(a);
                break :blk ft.transport();
            }
            // Production path: spin up the RealTransport with shape
            // proxy / API / WS hosts derived from the engine config.
            // Missing shape_proxy_url falls back to base_url. Parsing
            // failures surface as CoreError.TransportError and land the
            // session in `state=disconnected`.
            const real_cfg = derivedRealCfg(cfg_in) catch return CoreError.TransportError;
            const refresher = transport.CredentialsRefresher{
                .ctx = @ptrCast(core),
                .fetch_fn = coreCredsRefreshTrampoline,
            };
            const rt = transport.RealTransport.create(a, c, real_cfg, refresher) catch return CoreError.TransportError;
            break :blk rt.transport();
        };
        errdefer if (owns) t_impl.destroy(a);

        self.* = .{
            .core = core,
            .allocator = a,
            .config = .{
                .engine_id = storage.engine_id,
                .base_url = storage.base_url,
                .shape_proxy_url = storage.shape_proxy_url,
                .ws_pty_url = storage.ws_pty_url,
                .cache_dir = storage.cache_dir,
                .cache_max_mb = cfg_in.cache_max_mb,
            },
            .config_storage = storage,
            .cache = c,
            .transport_impl = t_impl,
            .owns_transport = owns,
            .state = .connecting,
            .auto_pump_enabled = core.shouldAutoPumpSessions(),
        };

        // Probe credentials once to catch the "sign in required" case
        // synchronously. If the callback returns false we fire auth_expired
        // and leave the session in state=disconnected — the host must
        // retry after the platform refreshes the token.
        if (core.fetchCredentials()) |_| {
            self.state = .connected;
        } else |_| {
            self.state = .disconnected;
        }
        if (self.auto_pump_enabled) {
            self.startPump() catch return CoreError.TransportError;
        }
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.stopPump();

        self.mutex.lock();
        for (self.subscriptions.items) |sub| self.allocator.free(sub.shape_name_owned);
        self.subscriptions.deinit(self.allocator);
        self.pty_attachments.deinit(self.allocator);
        self.mutex.unlock();

        if (self.owns_transport) self.transport_impl.destroy(self.allocator);
        self.cache.close();

        self.allocator.free(self.config_storage.engine_id);
        self.allocator.free(self.config_storage.base_url);
        if (self.config_storage.shape_proxy_url) |v| self.allocator.free(v);
        if (self.config_storage.ws_pty_url) |v| self.allocator.free(v);
        if (self.config_storage.cache_dir) |v| self.allocator.free(v);

        self.core.removeSession(self);
        self.allocator.destroy(self);
    }

    pub fn registerCallback(self: *Session, cb: EventFn, userdata: ?*anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.event_cb = cb;
        self.event_userdata = userdata;
    }

    // --- Shape subscriptions --------------------------------------------

    pub fn subscribe(
        self: *Session,
        shape_name: []const u8,
        params_json: []const u8,
    ) !u64 {
        const shape = schema.Shape.parse(shape_name) orelse return CoreError.UnknownShape;

        const cache_sub = self.cache.registerSubscription(shape_name, params_json) catch return CoreError.CacheError;
        errdefer self.cache.unregisterSubscription(cache_sub) catch {};

        const t_sub = self.transport_impl.subscribe(shape_name, params_json) catch return CoreError.TransportError;

        self.mutex.lock();
        defer self.mutex.unlock();
        const public = self.next_public_sub;
        self.next_public_sub += 1;
        try self.subscriptions.append(self.allocator, .{
            .public_id = public,
            .cache_sub_id = cache_sub,
            .transport_sub_id = t_sub,
            .shape = shape,
            .shape_name_owned = try self.allocator.dupe(u8, shape_name),
        });
        return public;
    }

    pub fn unsubscribe(self: *Session, public_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.subscriptions.items.len) : (i += 1) {
            if (self.subscriptions.items[i].public_id == public_id) {
                const sub = self.subscriptions.items[i];
                _ = self.subscriptions.swapRemove(i);
                self.allocator.free(sub.shape_name_owned);
                _ = self.transport_impl.unsubscribe(sub.transport_sub_id) catch {};
                _ = self.cache.unregisterSubscription(sub.cache_sub_id) catch {};
                return;
            }
        }
        return CoreError.InvalidArgument;
    }

    pub fn setPinned(self: *Session, public_id: u64, pinned: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscriptions.items) |sub| {
            if (sub.public_id == public_id) {
                self.cache.setPinned(sub.cache_sub_id, pinned) catch return CoreError.CacheError;
                return;
            }
        }
        return CoreError.InvalidArgument;
    }

    // --- Cache reads ----------------------------------------------------

    pub fn queryCache(
        self: *Session,
        table: []const u8,
        limit: i32,
        offset: i32,
    ) ![]u8 {
        const shape = schema.Shape.parse(table) orelse return CoreError.UnknownShape;
        return self.cache.queryJson(shape, limit, offset) catch CoreError.CacheError;
    }

    pub fn wipeCache(self: *Session) !void {
        self.cache.wipe() catch return CoreError.CacheError;
    }

    // --- Writes ---------------------------------------------------------

    pub fn write(
        self: *Session,
        action: []const u8,
        payload_json: []const u8,
    ) !u64 {
        return self.transport_impl.write(action, payload_json) catch CoreError.TransportError;
    }

    // --- PTY ------------------------------------------------------------

    pub fn attachPty(self: *Session, session_id: []const u8) !u64 {
        const th = self.transport_impl.attachPty(session_id) catch return CoreError.TransportError;
        self.mutex.lock();
        defer self.mutex.unlock();
        const public = self.next_public_pty;
        self.next_public_pty += 1;
        try self.pty_attachments.append(self.allocator, .{
            .public_handle = public,
            .transport_handle = th,
        });
        return public;
    }

    fn resolvePty(self: *Session, public: u64) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.pty_attachments.items) |att| {
            if (att.public_handle == public) return att.transport_handle;
        }
        return null;
    }

    pub fn ptyWrite(self: *Session, public: u64, bytes: []const u8) !void {
        const th = self.resolvePty(public) orelse return CoreError.InvalidArgument;
        self.transport_impl.ptyWrite(th, bytes) catch return CoreError.TransportError;
    }

    pub fn ptyResize(self: *Session, public: u64, cols: u16, rows: u16) !void {
        const th = self.resolvePty(public) orelse return CoreError.InvalidArgument;
        self.transport_impl.ptyResize(th, cols, rows) catch return CoreError.TransportError;
    }

    pub fn detachPty(self: *Session, public: u64) void {
        self.mutex.lock();
        var th_opt: ?u64 = null;
        var i: usize = 0;
        while (i < self.pty_attachments.items.len) : (i += 1) {
            if (self.pty_attachments.items[i].public_handle == public) {
                th_opt = self.pty_attachments.items[i].transport_handle;
                _ = self.pty_attachments.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock();
        if (th_opt) |th| _ = self.transport_impl.ptyDetach(th) catch {};
    }

    // --- Event pump -----------------------------------------------------

    /// Single event-pump step. Production sessions run this from an
    /// internal background pump; tests may call it inline for
    /// deterministic stepping.
    pub fn tick(self: *Session) !void {
        self.tick_mutex.lock();
        defer self.tick_mutex.unlock();

        var drained: std.ArrayList(transport.Delta) = .empty;
        defer {
            for (drained.items) |d| transport.freeDelta(self.allocator, d);
            drained.deinit(self.allocator);
        }
        self.transport_impl.tick(&drained, self.allocator) catch {};

        for (drained.items) |d| {
            switch (d) {
                .row_upsert => |v| {
                    const shape = schema.Shape.parse(v.shape) orelse continue;
                    const sub_id = self.cacheSubForShape(shape) orelse continue;
                    if (shape.hasLiveAdapter()) {
                        self.cache.upsertRow(shape, sub_id, v.pk, v.row_json) catch continue;
                    }
                    // Emit a SHAPE_DELTA event with a compact JSON payload.
                    self.emitDeltaEvent(v.shape, v.pk, "upsert");
                },
                .row_delete => |v| {
                    const shape = schema.Shape.parse(v.shape) orelse continue;
                    if (shape.hasLiveAdapter()) {
                        self.cache.deleteRow(shape, v.pk) catch continue;
                    }
                    self.emitDeltaEvent(v.shape, v.pk, "delete");
                },
                .up_to_date => |v| {
                    const shape = schema.Shape.parse(v.shape) orelse continue;
                    const sub_id = self.cacheSubForShape(shape) orelse continue;
                    self.cache.updateCursor(sub_id, v.handle, v.offset) catch {};
                },
                .must_refetch => |_| {
                    // TODO(0120-followup): implement local wipe + resubscribe.
                },
                .auth_expired => {
                    self.emitSimpleEvent(.auth_expired, null);
                },
                .write_ack => |v| {
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(self.allocator);
                    buf.print(self.allocator, "{{\"future\":{d},\"ok\":{},\"status\":{d},\"body\":", .{ v.future, v.ok, v.status }) catch continue;
                    appendJsonString(&buf, self.allocator, v.body) catch continue;
                    buf.append(self.allocator, '}') catch continue;
                    const z = self.allocator.dupeZ(u8, buf.items) catch continue;
                    defer self.allocator.free(z);
                    self.emitSimpleEvent(.write_ack, z.ptr);
                },
                .pty_data => |v| {
                    // Translate transport handle to public handle.
                    const public = self.publicForTransportPty(v.handle) orelse continue;
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(self.allocator);
                    buf.print(self.allocator, "{{\"handle\":{d},\"bytes\":", .{public}) catch continue;
                    appendJsonString(&buf, self.allocator, v.bytes) catch continue;
                    buf.append(self.allocator, '}') catch continue;
                    const z = self.allocator.dupeZ(u8, buf.items) catch continue;
                    defer self.allocator.free(z);
                    self.emitSimpleEvent(.pty_data, z.ptr);
                },
                .pty_closed => |v| {
                    const public = self.publicForTransportPty(v.handle) orelse continue;
                    var buf: [64]u8 = undefined;
                    const s = std.fmt.bufPrintZ(&buf, "{{\"handle\":{d}}}", .{public}) catch continue;
                    self.emitSimpleEvent(.pty_closed, s.ptr);
                },
            }
        }
    }

    fn startPump(self: *Session) !void {
        self.pump_stop.store(false, .release);
        self.pump_thread = try std.Thread.spawn(.{}, pumpThreadMain, .{self});
    }

    fn stopPump(self: *Session) void {
        const thread = self.pump_thread orelse return;
        self.pump_stop.store(true, .release);
        self.pump_thread = null;
        thread.join();
    }

    fn pumpThreadMain(self: *Session) void {
        while (!self.pump_stop.load(.acquire)) {
            self.tick() catch {};
            if (self.pump_stop.load(.acquire)) break;
            std.Thread.sleep(pump_sleep_ns);
        }
    }

    fn cacheSubForShape(self: *Session, shape: schema.Shape) ?i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscriptions.items) |sub| {
            if (sub.shape == shape) return sub.cache_sub_id;
        }
        return null;
    }

    fn publicForTransportPty(self: *Session, th: u64) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.pty_attachments.items) |att| {
            if (att.transport_handle == th) return att.public_handle;
        }
        return null;
    }

    fn emitDeltaEvent(self: *Session, shape: []const u8, pk: []const u8, op: []const u8) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        buf.appendSlice(self.allocator, "{\"shape\":") catch return;
        appendJsonString(&buf, self.allocator, shape) catch return;
        buf.appendSlice(self.allocator, ",\"pk\":") catch return;
        appendJsonString(&buf, self.allocator, pk) catch return;
        buf.appendSlice(self.allocator, ",\"op\":") catch return;
        appendJsonString(&buf, self.allocator, op) catch return;
        buf.append(self.allocator, '}') catch return;
        const z = self.allocator.dupeZ(u8, buf.items) catch return;
        defer self.allocator.free(z);
        self.emitSimpleEvent(.shape_delta, z.ptr);
    }

    fn emitSimpleEvent(self: *Session, tag: EventTag, payload: ?[*:0]const u8) void {
        self.mutex.lock();
        const cb = self.event_cb;
        const userdata = self.event_userdata;
        self.mutex.unlock();

        const f = cb orelse return;
        f(userdata, tag, payload);
    }
};

/// Minimal JSON string escaper sufficient for shape names, pks, and
/// opaque bodies treated as text. Not a full RFC 8259 implementation —
/// do not reuse for untrusted input. For our purposes (ids + bodies that
/// never contain control bytes or non-ASCII unless the caller sent them),
/// this handles the common escapes and falls back to `\u00XX` for low
/// control bytes.
fn appendJsonString(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |b| {
        switch (b) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            0...8, 11, 12, 14...31 => {
                var hex: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{b}) catch unreachable;
                try buf.appendSlice(a, &hex);
            },
            else => try buf.append(a, b),
        }
    }
    try buf.append(a, '"');
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

fn credsOk(_: ?*anyopaque, out: *Credentials) callconv(.c) bool {
    out.* = .{ .bearer = "test-token" };
    return true;
}

fn credsExpired(_: ?*anyopaque, out: *Credentials) callconv(.c) bool {
    _ = out;
    return false;
}

const EventLog = struct {
    mutex: std.Thread.Mutex = .{},
    events: std.ArrayList(Entry) = .empty,
    allocator: std.mem.Allocator,
    const Entry = struct { tag: EventTag, payload: ?[]u8 };

    fn deinit(self: *EventLog) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.events.items) |e| if (e.payload) |p| self.allocator.free(p);
        self.events.deinit(self.allocator);
    }
};

fn recordEvent(ud: ?*anyopaque, tag: EventTag, payload: ?[*:0]const u8) callconv(.c) void {
    const log: *EventLog = @ptrCast(@alignCast(ud.?));
    const owned: ?[]u8 = blk: {
        if (payload) |p| {
            const s = std.mem.sliceTo(p, 0);
            const dup = log.allocator.dupe(u8, s) catch break :blk null;
            break :blk dup;
        }
        break :blk null;
    };
    log.mutex.lock();
    defer log.mutex.unlock();
    log.events.append(log.allocator, .{ .tag = tag, .payload = owned }) catch {};
}

fn noopEvent(_: ?*anyopaque, _: EventTag, _: ?[*:0]const u8) callconv(.c) void {}

test "Session: subscribe agent_sessions + apply delta via tick" {
    const core = try Core.create(testing.allocator, credsOk, null);
    defer core.destroy();
    core.testing_use_fake_transport = true;

    const s = try core.connect(.{
        .engine_id = "e1",
        .base_url = "http://localhost",
    });

    // Pull the fake transport back out so we can enqueue deltas.
    const ft: *transport.FakeTransport = @ptrCast(@alignCast(s.transport_impl.ctx.?));

    const sub = try s.subscribe("agent_sessions", "{}");
    try testing.expect(sub != 0);

    var log = EventLog{ .allocator = testing.allocator };
    defer log.deinit();
    s.registerCallback(recordEvent, @ptrCast(&log));

    try ft.enqueue(.{ .row_upsert = .{
        .shape = try testing.allocator.dupe(u8, "agent_sessions"),
        .pk = try testing.allocator.dupe(u8, "as_1"),
        .row_json = try testing.allocator.dupe(u8, "{\"id\":\"as_1\",\"title\":\"hi\"}"),
    } });
    try ft.enqueue(.{ .up_to_date = .{
        .shape = try testing.allocator.dupe(u8, "agent_sessions"),
        .handle = try testing.allocator.dupe(u8, "h-1"),
        .offset = try testing.allocator.dupe(u8, "0_7"),
    } });

    try s.tick();

    // Cache populated.
    const rows = try s.queryCache("agent_sessions", 0, 0);
    defer testing.allocator.free(rows);
    try testing.expect(std.mem.indexOf(u8, rows, "as_1") != null);

    // One SHAPE_DELTA event dispatched.
    try testing.expect(log.events.items.len >= 1);
    try testing.expectEqual(EventTag.shape_delta, log.events.items[0].tag);
}

test "Session: background pump drains FakeTransport without manual tick" {
    const core = try Core.create(testing.allocator, credsOk, null);
    defer core.destroy();
    core.testing_use_fake_transport = true;
    core.testing_enable_background_event_pump = true;

    const s = try core.connect(.{
        .engine_id = "e1",
        .base_url = "http://localhost",
    });

    const ft: *transport.FakeTransport = @ptrCast(@alignCast(s.transport_impl.ctx.?));
    _ = try s.subscribe("agent_sessions", "{}");

    var log = EventLog{ .allocator = testing.allocator };
    defer log.deinit();
    s.registerCallback(recordEvent, @ptrCast(&log));
    defer s.registerCallback(noopEvent, null);

    try ft.enqueue(.{ .row_upsert = .{
        .shape = try testing.allocator.dupe(u8, "agent_sessions"),
        .pk = try testing.allocator.dupe(u8, "as_bg"),
        .row_json = try testing.allocator.dupe(u8, "{\"id\":\"as_bg\",\"title\":\"pump\"}"),
    } });

    var saw_delta = false;
    var saw_row = false;
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        log.mutex.lock();
        for (log.events.items) |e| {
            if (e.tag == .shape_delta) {
                saw_delta = true;
                break;
            }
        }
        log.mutex.unlock();

        const rows = try s.queryCache("agent_sessions", 0, 0);
        saw_row = std.mem.indexOf(u8, rows, "as_bg") != null;
        testing.allocator.free(rows);

        if (saw_delta and saw_row) break;
        std.Thread.sleep(std.time.ns_per_ms);
    }

    try testing.expect(saw_delta);
    try testing.expect(saw_row);
}

test "Session: unsubscribe drops rows + allows resubscribe" {
    const core = try Core.create(testing.allocator, credsOk, null);
    defer core.destroy();
    core.testing_use_fake_transport = true;
    const s = try core.connect(.{ .engine_id = "e1", .base_url = "http://x" });
    const ft: *transport.FakeTransport = @ptrCast(@alignCast(s.transport_impl.ctx.?));

    const sub = try s.subscribe("agent_sessions", "{}");
    try ft.enqueue(.{ .row_upsert = .{
        .shape = try testing.allocator.dupe(u8, "agent_sessions"),
        .pk = try testing.allocator.dupe(u8, "as_1"),
        .row_json = try testing.allocator.dupe(u8, "{\"v\":1}"),
    } });
    try s.tick();
    try s.unsubscribe(sub);
    const rows = try s.queryCache("agent_sessions", 0, 0);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("[]", rows);
}

test "Session: cache wipe clears rows (sign-out path)" {
    const core = try Core.create(testing.allocator, credsOk, null);
    defer core.destroy();
    core.testing_use_fake_transport = true;
    const s = try core.connect(.{ .engine_id = "e1", .base_url = "http://x" });
    const ft: *transport.FakeTransport = @ptrCast(@alignCast(s.transport_impl.ctx.?));

    _ = try s.subscribe("agent_sessions", "{}");
    try ft.enqueue(.{ .row_upsert = .{
        .shape = try testing.allocator.dupe(u8, "agent_sessions"),
        .pk = try testing.allocator.dupe(u8, "as_1"),
        .row_json = try testing.allocator.dupe(u8, "{\"v\":1}"),
    } });
    try s.tick();
    try s.wipeCache();
    const rows = try s.queryCache("agent_sessions", 0, 0);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("[]", rows);
}

test "Session: write issues future + ack fires WRITE_ACK" {
    const core = try Core.create(testing.allocator, credsOk, null);
    defer core.destroy();
    core.testing_use_fake_transport = true;
    const s = try core.connect(.{ .engine_id = "e1", .base_url = "http://x" });
    const ft: *transport.FakeTransport = @ptrCast(@alignCast(s.transport_impl.ctx.?));

    var log = EventLog{ .allocator = testing.allocator };
    defer log.deinit();
    s.registerCallback(recordEvent, @ptrCast(&log));

    const fut = try s.write("agent_sessions.create", "{\"title\":\"hi\"}");
    try testing.expect(fut != 0);

    try ft.enqueue(.{ .write_ack = .{
        .future = fut,
        .ok = true,
        .status = 200,
        .body = try testing.allocator.dupe(u8, "{\"id\":\"as_new\"}"),
    } });
    try s.tick();

    var saw = false;
    for (log.events.items) |e| if (e.tag == .write_ack) {
        saw = true;
    };
    try testing.expect(saw);
}

test "Session: attach / write / resize / detach PTY" {
    const core = try Core.create(testing.allocator, credsOk, null);
    defer core.destroy();
    core.testing_use_fake_transport = true;
    const s = try core.connect(.{ .engine_id = "e1", .base_url = "http://x" });

    const h = try s.attachPty("session_abc");
    try testing.expect(h != 0);
    try s.ptyWrite(h, "ls\n");
    try s.ptyResize(h, 120, 40);
    s.detachPty(h);
}

test "Session: auth-expired surfaces at connect time" {
    const core = try Core.create(testing.allocator, credsExpired, null);
    defer core.destroy();
    core.testing_use_fake_transport = true;
    const s = try core.connect(.{ .engine_id = "e1", .base_url = "http://x" });
    try testing.expectEqual(ConnectionState.disconnected, s.state);
}

test "Session: subscribe rejects unknown shape" {
    const core = try Core.create(testing.allocator, credsOk, null);
    defer core.destroy();
    core.testing_use_fake_transport = true;
    const s = try core.connect(.{ .engine_id = "e1", .base_url = "http://x" });
    try testing.expectError(CoreError.UnknownShape, s.subscribe("not_a_shape", "{}"));
}
