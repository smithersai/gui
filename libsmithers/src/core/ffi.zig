//! C ABI bridge for the 0120 core runtime.
//!
//! Exports the `smithers_core_*` functions declared in smithers.h.
//! Kept deliberately narrow — the Swift wrapper (SmithersRuntime) is a
//! thin adapter; anything richer should be added here explicitly, not
//! generated.
//!
//! The old `smithers_app_*` / `smithers_client_*` / `smithers_session_*`
//! compatibility ABI has been removed; this file is now the only runtime
//! entrypoint surface.

const std = @import("std");
const core_mod = @import("core.zig");
const Session = @import("session.zig").Session;
const EngineConfig = @import("session.zig").EngineConfig;
const EventFn = @import("session.zig").EventFn;
const parent_ffi = @import("../ffi.zig");
const structs = @import("../apprt/structs.zig");

const allocator = std.heap.c_allocator;

// --- ABI-facing structs (keep in sync with smithers.h) -----------------

/// keep in sync: smithers_credentials_s
pub const CCredentials = extern struct {
    bearer: ?[*:0]const u8,
    expires_unix_ms: i64,
    refresh_token: ?[*:0]const u8,
};

/// keep in sync: smithers_core_engine_config_s
pub const CEngineConfig = extern struct {
    engine_id: ?[*:0]const u8,
    base_url: ?[*:0]const u8,
    shape_proxy_url: ?[*:0]const u8,
    ws_pty_url: ?[*:0]const u8,
    cache_dir: ?[*:0]const u8,
    cache_max_mb: u32,
};

pub const CCredentialsFn = *const fn (ud: ?*anyopaque, out: *CCredentials) callconv(.c) bool;

// --- Trampoline: convert C credentials callback to Zig Credentials -----

const TrampolineCtx = struct {
    c_cb: CCredentialsFn,
    c_ud: ?*anyopaque,
};

fn trampolineCreds(ud: ?*anyopaque, out: *core_mod.Credentials) callconv(.c) bool {
    const ctx: *TrampolineCtx = @ptrCast(@alignCast(ud.?));
    var c_out: CCredentials = .{ .bearer = null, .expires_unix_ms = 0, .refresh_token = null };
    const ok = ctx.c_cb(ctx.c_ud, &c_out);
    if (!ok) return false;
    const bearer_ptr = c_out.bearer orelse return false;
    out.* = .{
        .bearer = std.mem.sliceTo(bearer_ptr, 0),
        .expires_unix_ms = c_out.expires_unix_ms,
        .refresh_token = if (c_out.refresh_token) |r| std.mem.sliceTo(r, 0) else null,
    };
    return true;
}

/// Opaque wrapper that owns both the Zig Core and the trampoline ctx.
const CoreWrapper = struct {
    core: *core_mod.Core,
    trampoline: *TrampolineCtx,
};

/// Opaque C handle for a connected Session.
///
/// Lifetime model:
///   - connect() returns a SessionBox with one strong ref (the API-level
///     `smithers_core_session_t` handle).
///   - PTY attach takes an extra strong ref so disconnect cannot destroy the
///     underlying Session while PTY wrappers still exist.
///   - disconnect() marks closed + drops the API-level strong ref; actual
///     Session.destroy() is deferred until the last outstanding ref releases.
const SessionBox = struct {
    session: ?*Session,
    mutex: std.Thread.Mutex = .{},
    ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn retain(self: *SessionBox) *SessionBox {
        const prev = self.ref_count.fetchAdd(1, .monotonic);
        std.debug.assert(prev > 0);
        return self;
    }

    fn release(self: *SessionBox) void {
        const prev = self.ref_count.fetchSub(1, .release);
        std.debug.assert(prev > 0);
        if (prev != 1) return;

        _ = self.ref_count.load(.acquire);
        self.mutex.lock();
        const session_opt = self.session;
        self.session = null;
        self.mutex.unlock();

        if (session_opt) |session| session.destroy();
        allocator.destroy(self);
    }

    fn close(self: *SessionBox) void {
        self.closed.store(true, .release);
        self.release();
    }

    fn acquireSession(self: *SessionBox, comptime require_open: bool) ?*Session {
        const prev = self.ref_count.fetchAdd(1, .monotonic);
        if (prev == 0) return null;

        if (require_open and self.closed.load(.acquire)) {
            self.release();
            return null;
        }

        self.mutex.lock();
        const session_opt = self.session;
        self.mutex.unlock();
        if (session_opt == null) {
            self.release();
            return null;
        }
        return session_opt;
    }
};

const PtyBox = struct {
    session_box: *SessionBox,
    handle: u64,
    detached: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn setSessionClosedError(out_err: ?*structs.Error, comptime prefix: []const u8) void {
    if (out_err) |e| e.* = parent_ffi.errorFrom(prefix, core_mod.Error.AlreadyClosed);
}

// --- Exports -----------------------------------------------------------

pub export fn smithers_core_new(
    credentials_cb: ?CCredentialsFn,
    userdata: ?*anyopaque,
    out_err: ?*structs.Error,
) ?*CoreWrapper {
    const cb = credentials_cb orelse {
        if (out_err) |e| e.* = parent_ffi.errorMessage(1, "credentials_cb is required");
        return null;
    };
    const tramp = allocator.create(TrampolineCtx) catch {
        if (out_err) |e| e.* = parent_ffi.errorMessage(2, "oom");
        return null;
    };
    tramp.* = .{ .c_cb = cb, .c_ud = userdata };

    const c = core_mod.Core.create(allocator, trampolineCreds, @ptrCast(tramp)) catch |err| {
        allocator.destroy(tramp);
        if (out_err) |e| switch (err) {
            core_mod.Error.FeatureFlagDisabled => e.* = parent_ffi.errorMessage(3, "remote_sandbox_enabled off"),
            else => e.* = parent_ffi.errorFrom("smithers_core_new", err),
        };
        return null;
    };
    const w = allocator.create(CoreWrapper) catch {
        c.destroy();
        allocator.destroy(tramp);
        if (out_err) |e| e.* = parent_ffi.errorMessage(2, "oom");
        return null;
    };
    w.* = .{ .core = c, .trampoline = tramp };
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return w;
}

pub export fn smithers_core_free(w_opt: ?*CoreWrapper) void {
    const w = w_opt orelse return;
    w.core.destroy();
    allocator.destroy(w.trampoline);
    allocator.destroy(w);
}

pub export fn smithers_core_connect(
    w_opt: ?*CoreWrapper,
    cfg_opt: ?*const CEngineConfig,
    out_err: ?*structs.Error,
) ?*SessionBox {
    const w = w_opt orelse {
        if (out_err) |e| e.* = parent_ffi.errorMessage(1, "core is null");
        return null;
    };
    const c = cfg_opt orelse {
        if (out_err) |e| e.* = parent_ffi.errorMessage(1, "cfg is null");
        return null;
    };
    const engine = EngineConfig{
        .engine_id = if (c.engine_id) |p| std.mem.sliceTo(p, 0) else "",
        .base_url = if (c.base_url) |p| std.mem.sliceTo(p, 0) else "",
        .shape_proxy_url = if (c.shape_proxy_url) |p| std.mem.sliceTo(p, 0) else null,
        .ws_pty_url = if (c.ws_pty_url) |p| std.mem.sliceTo(p, 0) else null,
        .cache_dir = if (c.cache_dir) |p| std.mem.sliceTo(p, 0) else null,
        .cache_max_mb = c.cache_max_mb,
    };
    const session = w.core.connect(engine) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_connect", err);
        return null;
    };

    const boxed = allocator.create(SessionBox) catch {
        session.destroy();
        if (out_err) |e| e.* = parent_ffi.errorMessage(2, "oom");
        return null;
    };
    boxed.* = .{ .session = session };

    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return boxed;
}

pub export fn smithers_core_disconnect(s_opt: ?*SessionBox) void {
    const session_box = s_opt orelse return;
    session_box.close();
}

pub export fn smithers_core_register_callback(
    s_opt: ?*SessionBox,
    cb: ?EventFn,
    userdata: ?*anyopaque,
) void {
    const session_box = s_opt orelse return;
    const c = cb orelse return;
    const session = session_box.acquireSession(true) orelse return;
    defer session_box.release();
    session.registerCallback(c, userdata);
}

pub export fn smithers_core_subscribe(
    s_opt: ?*SessionBox,
    shape_name: ?[*:0]const u8,
    params_json: ?[*:0]const u8,
    out_err: ?*structs.Error,
) u64 {
    const session_box = s_opt orelse {
        if (out_err) |e| e.* = parent_ffi.errorMessage(1, "null session");
        return 0;
    };
    const session = session_box.acquireSession(true) orelse {
        setSessionClosedError(out_err, "smithers_core_subscribe");
        return 0;
    };
    defer session_box.release();

    const name = if (shape_name) |p| std.mem.sliceTo(p, 0) else "";
    const params = if (params_json) |p| std.mem.sliceTo(p, 0) else "";
    const id = session.subscribe(name, params) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_subscribe", err);
        return 0;
    };
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return id;
}

pub export fn smithers_core_unsubscribe(s_opt: ?*SessionBox, handle: u64) void {
    const session_box = s_opt orelse return;
    const session = session_box.acquireSession(true) orelse return;
    defer session_box.release();
    session.unsubscribe(handle) catch {};
}

pub export fn smithers_core_pin(s_opt: ?*SessionBox, handle: u64) void {
    const session_box = s_opt orelse return;
    const session = session_box.acquireSession(true) orelse return;
    defer session_box.release();
    session.setPinned(handle, true) catch {};
}

pub export fn smithers_core_unpin(s_opt: ?*SessionBox, handle: u64) void {
    const session_box = s_opt orelse return;
    const session = session_box.acquireSession(true) orelse return;
    defer session_box.release();
    session.setPinned(handle, false) catch {};
}

pub export fn smithers_core_cache_query(
    s_opt: ?*SessionBox,
    table: ?[*:0]const u8,
    where_sql: ?[*:0]const u8,
    limit: i32,
    offset: i32,
    out_err: ?*structs.Error,
) structs.String {
    _ = where_sql; // TODO(0120-followup): safely bind WHERE substring.
    const session_box = s_opt orelse {
        if (out_err) |e| e.* = parent_ffi.errorMessage(1, "null session");
        return parent_ffi.emptyString();
    };
    const session = session_box.acquireSession(true) orelse {
        setSessionClosedError(out_err, "smithers_core_cache_query");
        return parent_ffi.emptyString();
    };
    defer session_box.release();

    const t = if (table) |p| std.mem.sliceTo(p, 0) else "";
    const rows = session.queryCache(t, limit, offset) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_cache_query", err);
        return parent_ffi.emptyString();
    };
    defer allocator.free(rows);
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return parent_ffi.stringDup(rows);
}

pub export fn smithers_core_write(
    s_opt: ?*SessionBox,
    action: ?[*:0]const u8,
    payload_json: ?[*:0]const u8,
    out_err: ?*structs.Error,
) u64 {
    const session_box = s_opt orelse {
        if (out_err) |e| e.* = parent_ffi.errorMessage(1, "null session");
        return 0;
    };
    const session = session_box.acquireSession(true) orelse {
        setSessionClosedError(out_err, "smithers_core_write");
        return 0;
    };
    defer session_box.release();

    const a = if (action) |p| std.mem.sliceTo(p, 0) else "";
    const payload = if (payload_json) |p| std.mem.sliceTo(p, 0) else "";
    const fut = session.write(a, payload) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_write", err);
        return 0;
    };
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return fut;
}

pub export fn smithers_core_attach_pty(
    s_opt: ?*SessionBox,
    session_id: ?[*:0]const u8,
    out_err: ?*structs.Error,
) ?*anyopaque {
    const session_box = s_opt orelse {
        if (out_err) |e| e.* = parent_ffi.errorMessage(1, "null session");
        return null;
    };
    const session = session_box.acquireSession(true) orelse {
        setSessionClosedError(out_err, "smithers_core_attach_pty");
        return null;
    };
    defer session_box.release();

    const sid = if (session_id) |p| std.mem.sliceTo(p, 0) else "";
    const h = session.attachPty(sid) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_attach_pty", err);
        return null;
    };

    const boxed = allocator.create(PtyBox) catch {
        session.detachPty(h);
        if (out_err) |e| e.* = parent_ffi.errorMessage(2, "oom");
        return null;
    };
    boxed.* = .{ .session_box = session_box.retain(), .handle = h };

    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return @ptrCast(boxed);
}

pub export fn smithers_core_pty_public_handle(h_opt: ?*PtyBox) u64 {
    const h = h_opt orelse return 0;
    return h.handle;
}

pub export fn smithers_core_pty_write(
    h_opt: ?*PtyBox,
    bytes: ?[*]const u8,
    len: usize,
) structs.Error {
    const h = h_opt orelse return parent_ffi.errorMessage(1, "null handle");
    const b = bytes orelse return parent_ffi.errorMessage(1, "null bytes");
    if (h.detached.load(.acquire)) return parent_ffi.errorMessage(1, "pty detached");

    const session = h.session_box.acquireSession(true) orelse {
        return parent_ffi.errorFrom("pty_write", core_mod.Error.AlreadyClosed);
    };
    defer h.session_box.release();

    session.ptyWrite(h.handle, b[0..len]) catch |err| return parent_ffi.errorFrom("pty_write", err);
    return parent_ffi.errorSuccess();
}

pub export fn smithers_core_pty_resize(
    h_opt: ?*PtyBox,
    cols: u16,
    rows: u16,
) structs.Error {
    const h = h_opt orelse return parent_ffi.errorMessage(1, "null handle");
    if (h.detached.load(.acquire)) return parent_ffi.errorMessage(1, "pty detached");

    const session = h.session_box.acquireSession(true) orelse {
        return parent_ffi.errorFrom("pty_resize", core_mod.Error.AlreadyClosed);
    };
    defer h.session_box.release();

    session.ptyResize(h.handle, cols, rows) catch |err| return parent_ffi.errorFrom("pty_resize", err);
    return parent_ffi.errorSuccess();
}

pub export fn smithers_core_detach_pty(h_opt: ?*PtyBox) void {
    const h = h_opt orelse return;

    if (!h.detached.swap(true, .acq_rel)) {
        if (h.session_box.acquireSession(false)) |session| {
            defer h.session_box.release();
            session.detachPty(h.handle);
        }
        // Release the strong ref held by this PTY box.
        h.session_box.release();
    }

    allocator.destroy(h);
}

pub export fn smithers_core_cache_wipe(s_opt: ?*SessionBox) structs.Error {
    const session_box = s_opt orelse return parent_ffi.errorMessage(1, "null session");
    const session = session_box.acquireSession(true) orelse return parent_ffi.errorFrom("cache_wipe", core_mod.Error.AlreadyClosed);
    defer session_box.release();

    session.wipeCache() catch |err| return parent_ffi.errorFrom("cache_wipe", err);
    return parent_ffi.errorSuccess();
}

/// Test hook — not exported through smithers.h. Drives the event pump so
/// integration tests can run deterministically from Swift.
pub export fn smithers_core_tick_for_test(s_opt: ?*SessionBox) void {
    const session_box = s_opt orelse return;
    const session = session_box.acquireSession(true) orelse return;
    defer session_box.release();
    session.tick() catch {};
}

const testing = std.testing;

fn testCredsOk(_: ?*anyopaque, out: *CCredentials) callconv(.c) bool {
    out.* = .{
        .bearer = "test-bearer",
        .expires_unix_ms = 0,
        .refresh_token = null,
    };
    return true;
}

test "FFI: disconnect is safe with outstanding PTY wrapper" {
    var err = parent_ffi.errorSuccess();

    const core = smithers_core_new(testCredsOk, null, &err) orelse {
        if (err.code != 0) parent_ffi.errorFree(err);
        try testing.expect(false);
        return;
    };
    defer smithers_core_free(core);
    try testing.expectEqual(@as(i32, 0), err.code);

    core.core.testing_use_fake_transport = true;

    const cfg = CEngineConfig{
        .engine_id = "e1",
        .base_url = "http://localhost",
        .shape_proxy_url = null,
        .ws_pty_url = null,
        .cache_dir = null,
        .cache_max_mb = 0,
    };

    const session = smithers_core_connect(core, &cfg, &err) orelse {
        if (err.code != 0) parent_ffi.errorFree(err);
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(i32, 0), err.code);

    const pty_any = smithers_core_attach_pty(session, "session_abc", &err) orelse {
        if (err.code != 0) parent_ffi.errorFree(err);
        try testing.expect(false);
        return;
    };
    const pty: *PtyBox = @ptrCast(@alignCast(pty_any));
    try testing.expectEqual(@as(i32, 0), err.code);

    smithers_core_disconnect(session);

    const bytes: []const u8 = "ls\n";
    const write_err = smithers_core_pty_write(pty, bytes.ptr, bytes.len);
    try testing.expect(write_err.code != 0);
    if (write_err.code != 0) parent_ffi.errorFree(write_err);

    const resize_err = smithers_core_pty_resize(pty, 80, 24);
    try testing.expect(resize_err.code != 0);
    if (resize_err.code != 0) parent_ffi.errorFree(resize_err);

    smithers_core_detach_pty(pty);
}
