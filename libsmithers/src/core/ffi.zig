//! C ABI bridge for the 0120 core runtime.
//!
//! Exports the `smithers_core_*` functions declared in smithers.h.
//! Kept deliberately narrow — the Swift wrapper (SmithersRuntime) is a
//! thin adapter; anything richer should be added here explicitly, not
//! generated.
//!
//! NOTE: the old `smithers_app_*` / `smithers_client_*` / `smithers_session_*`
//! FFI in apprt/embedded.zig stays intact as a compatibility shim
//! (REMOVE-AFTER-0126) so desktop-local keeps compiling while the
//! production remote path migrates.

const std = @import("std");
const core_mod = @import("core.zig");
const Session = @import("session.zig").Session;
const EngineConfig = @import("session.zig").EngineConfig;
const EventTag = @import("session.zig").EventTag;
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
) ?*Session {
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
    const s = w.core.connect(engine) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_connect", err);
        return null;
    };
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return s;
}

pub export fn smithers_core_disconnect(s: ?*Session) void {
    if (s) |ptr| ptr.destroy();
}

pub export fn smithers_core_register_callback(
    s_opt: ?*Session,
    cb: ?EventFn,
    userdata: ?*anyopaque,
) void {
    const s = s_opt orelse return;
    const c = cb orelse return;
    s.registerCallback(c, userdata);
}

pub export fn smithers_core_subscribe(
    s_opt: ?*Session,
    shape_name: ?[*:0]const u8,
    params_json: ?[*:0]const u8,
    out_err: ?*structs.Error,
) u64 {
    const s = s_opt orelse return 0;
    const name = if (shape_name) |p| std.mem.sliceTo(p, 0) else "";
    const params = if (params_json) |p| std.mem.sliceTo(p, 0) else "";
    const id = s.subscribe(name, params) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_subscribe", err);
        return 0;
    };
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return id;
}

pub export fn smithers_core_unsubscribe(s_opt: ?*Session, handle: u64) void {
    const s = s_opt orelse return;
    s.unsubscribe(handle) catch {};
}

pub export fn smithers_core_pin(s_opt: ?*Session, handle: u64) void {
    const s = s_opt orelse return;
    s.setPinned(handle, true) catch {};
}

pub export fn smithers_core_unpin(s_opt: ?*Session, handle: u64) void {
    const s = s_opt orelse return;
    s.setPinned(handle, false) catch {};
}

pub export fn smithers_core_cache_query(
    s_opt: ?*Session,
    table: ?[*:0]const u8,
    where_sql: ?[*:0]const u8,
    limit: i32,
    offset: i32,
    out_err: ?*structs.Error,
) structs.String {
    _ = where_sql; // TODO(0120-followup): safely bind WHERE substring.
    const s = s_opt orelse return parent_ffi.emptyString();
    const t = if (table) |p| std.mem.sliceTo(p, 0) else "";
    const rows = s.queryCache(t, limit, offset) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_cache_query", err);
        return parent_ffi.emptyString();
    };
    defer allocator.free(rows);
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return parent_ffi.stringDup(rows);
}

pub export fn smithers_core_write(
    s_opt: ?*Session,
    action: ?[*:0]const u8,
    payload_json: ?[*:0]const u8,
    out_err: ?*structs.Error,
) u64 {
    const s = s_opt orelse return 0;
    const a = if (action) |p| std.mem.sliceTo(p, 0) else "";
    const payload = if (payload_json) |p| std.mem.sliceTo(p, 0) else "";
    const fut = s.write(a, payload) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_write", err);
        return 0;
    };
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    return fut;
}

pub export fn smithers_core_attach_pty(
    s_opt: ?*Session,
    session_id: ?[*:0]const u8,
    out_err: ?*structs.Error,
) ?*anyopaque {
    const s = s_opt orelse return null;
    const sid = if (session_id) |p| std.mem.sliceTo(p, 0) else "";
    const h = s.attachPty(sid) catch |err| {
        if (out_err) |e| e.* = parent_ffi.errorFrom("smithers_core_attach_pty", err);
        return null;
    };
    if (out_err) |e| e.* = parent_ffi.errorSuccess();
    // Box the u64 handle so the C side treats it as an opaque pointer.
    const boxed = allocator.create(PtyBox) catch return null;
    boxed.* = .{ .session = s, .handle = h };
    return @ptrCast(boxed);
}

const PtyBox = struct { session: *Session, handle: u64 };

pub export fn smithers_core_pty_write(
    h_opt: ?*PtyBox,
    bytes: ?[*]const u8,
    len: usize,
) structs.Error {
    const h = h_opt orelse return parent_ffi.errorMessage(1, "null handle");
    const b = bytes orelse return parent_ffi.errorMessage(1, "null bytes");
    h.session.ptyWrite(h.handle, b[0..len]) catch |err| return parent_ffi.errorFrom("pty_write", err);
    return parent_ffi.errorSuccess();
}

pub export fn smithers_core_pty_resize(
    h_opt: ?*PtyBox,
    cols: u16,
    rows: u16,
) structs.Error {
    const h = h_opt orelse return parent_ffi.errorMessage(1, "null handle");
    h.session.ptyResize(h.handle, cols, rows) catch |err| return parent_ffi.errorFrom("pty_resize", err);
    return parent_ffi.errorSuccess();
}

pub export fn smithers_core_detach_pty(h_opt: ?*PtyBox) void {
    const h = h_opt orelse return;
    h.session.detachPty(h.handle);
    allocator.destroy(h);
}

pub export fn smithers_core_cache_wipe(s_opt: ?*Session) structs.Error {
    const s = s_opt orelse return parent_ffi.errorMessage(1, "null session");
    s.wipeCache() catch |err| return parent_ffi.errorFrom("cache_wipe", err);
    return parent_ffi.errorSuccess();
}

/// Test hook — not exported through smithers.h. Drives the event pump so
/// integration tests can run deterministically from Swift.
pub export fn smithers_core_tick_for_test(s_opt: ?*Session) void {
    const s = s_opt orelse return;
    s.tick() catch {};
}
