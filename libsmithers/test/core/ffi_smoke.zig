//! Smoke test for the 0120 core FFI surface.
//!
//! Drives the `smithers_core_*` C exports from Zig (treating them as
//! extern functions) to validate the ABI shape Swift will see. This
//! catches symbol-visibility and argument-passing regressions before they
//! hit the Swift test target.

const std = @import("std");
const testing = std.testing;

// Force the core FFI exports to be linked into the test binary.
comptime {
    _ = @import("libsmithers");
}

// C ABI structs — manually mirror what smithers.h declares. Keep in sync.
const CCredentials = extern struct {
    bearer: ?[*:0]const u8,
    expires_unix_ms: i64,
    refresh_token: ?[*:0]const u8,
};

const CEngineConfig = extern struct {
    engine_id: ?[*:0]const u8,
    base_url: ?[*:0]const u8,
    shape_proxy_url: ?[*:0]const u8,
    ws_pty_url: ?[*:0]const u8,
    cache_dir: ?[*:0]const u8,
    cache_max_mb: u32,
};

const CError = extern struct {
    code: i32,
    msg: ?[*:0]const u8,
};

const CString = extern struct {
    ptr: ?[*:0]const u8,
    len: usize,
};

const CCredentialsFn = *const fn (ud: ?*anyopaque, out: *CCredentials) callconv(.c) bool;
const CEventFn = *const fn (ud: ?*anyopaque, tag: i32, payload: ?[*:0]const u8) callconv(.c) void;

extern fn smithers_core_new(cb: ?CCredentialsFn, ud: ?*anyopaque, out_err: ?*CError) ?*anyopaque;
extern fn smithers_core_free(w: ?*anyopaque) void;
extern fn smithers_core_connect(w: ?*anyopaque, cfg: ?*const CEngineConfig, out_err: ?*CError) ?*anyopaque;
extern fn smithers_core_disconnect(s: ?*anyopaque) void;
extern fn smithers_core_register_callback(s: ?*anyopaque, cb: ?CEventFn, ud: ?*anyopaque) void;
extern fn smithers_core_subscribe(s: ?*anyopaque, shape: ?[*:0]const u8, params: ?[*:0]const u8, out_err: ?*CError) u64;
extern fn smithers_core_unsubscribe(s: ?*anyopaque, handle: u64) void;
extern fn smithers_core_cache_query(s: ?*anyopaque, table: ?[*:0]const u8, where: ?[*:0]const u8, limit: i32, offset: i32, out_err: ?*CError) CString;
extern fn smithers_core_write(s: ?*anyopaque, action: ?[*:0]const u8, payload: ?[*:0]const u8, out_err: ?*CError) u64;
extern fn smithers_core_cache_wipe(s: ?*anyopaque) CError;
extern fn smithers_core_tick_for_test(s: ?*anyopaque) void;

fn credsOk(_: ?*anyopaque, out: *CCredentials) callconv(.c) bool {
    out.* = .{ .bearer = "test-bearer", .expires_unix_ms = 0, .refresh_token = null };
    return true;
}

fn credsExpired(_: ?*anyopaque, out: *CCredentials) callconv(.c) bool {
    _ = out;
    return false;
}

const EvtCtr = struct { shape_delta: u32 = 0, auth_expired: u32 = 0, write_ack: u32 = 0 };

fn recordEvt(ud: ?*anyopaque, tag: i32, payload: ?[*:0]const u8) callconv(.c) void {
    _ = payload;
    const ctr: *EvtCtr = @ptrCast(@alignCast(ud.?));
    switch (tag) {
        1 => ctr.auth_expired += 1,
        3 => ctr.shape_delta += 1,
        4 => ctr.write_ack += 1,
        else => {},
    }
}

test "FFI: new + free" {
    var err: CError = .{ .code = 0, .msg = null };
    const core = smithers_core_new(credsOk, null, &err);
    try testing.expect(core != null);
    smithers_core_free(core);
}

test "FFI: connect + disconnect" {
    var err: CError = .{ .code = 0, .msg = null };
    const core = smithers_core_new(credsOk, null, &err);
    defer smithers_core_free(core);
    const cfg = CEngineConfig{
        .engine_id = "e1",
        .base_url = "http://localhost",
        .shape_proxy_url = null,
        .ws_pty_url = null,
        .cache_dir = null,
        .cache_max_mb = 0,
    };
    const s = smithers_core_connect(core, &cfg, &err);
    try testing.expect(s != null);
    smithers_core_disconnect(s);
}

test "FFI: subscribe agent_sessions + cache query round-trip" {
    var err: CError = .{ .code = 0, .msg = null };
    const core = smithers_core_new(credsOk, null, &err);
    defer smithers_core_free(core);
    const cfg = CEngineConfig{
        .engine_id = "e1",
        .base_url = "http://localhost",
        .shape_proxy_url = null,
        .ws_pty_url = null,
        .cache_dir = null,
        .cache_max_mb = 0,
    };
    const s = smithers_core_connect(core, &cfg, &err);
    defer smithers_core_disconnect(s);

    var ctr = EvtCtr{};
    smithers_core_register_callback(s, recordEvt, @ptrCast(&ctr));

    const sub = smithers_core_subscribe(s, "agent_sessions", "{}", &err);
    try testing.expect(sub != 0);

    // Tick drains the (empty) fake transport — no deltas yet, query returns [].
    smithers_core_tick_for_test(s);
    const rows0 = smithers_core_cache_query(s, "agent_sessions", null, 0, 0, &err);
    defer if (rows0.ptr) |p| std.heap.c_allocator.free(@as([*]u8, @constCast(@ptrCast(p)))[0 .. rows0.len + 1]);
    const s0 = std.mem.sliceTo(rows0.ptr.?, 0);
    try testing.expectEqualStrings("[]", s0);

    smithers_core_unsubscribe(s, sub);
}

test "FFI: write returns non-zero future" {
    var err: CError = .{ .code = 0, .msg = null };
    const core = smithers_core_new(credsOk, null, &err);
    defer smithers_core_free(core);
    const cfg = CEngineConfig{
        .engine_id = "e1",
        .base_url = "http://x",
        .shape_proxy_url = null,
        .ws_pty_url = null,
        .cache_dir = null,
        .cache_max_mb = 0,
    };
    const s = smithers_core_connect(core, &cfg, &err);
    defer smithers_core_disconnect(s);
    const fut = smithers_core_write(s, "agent_session.create", "{\"title\":\"hi\"}", &err);
    try testing.expect(fut != 0);
}

test "FFI: cache_wipe succeeds" {
    var err: CError = .{ .code = 0, .msg = null };
    const core = smithers_core_new(credsOk, null, &err);
    defer smithers_core_free(core);
    const cfg = CEngineConfig{
        .engine_id = "e1",
        .base_url = "http://x",
        .shape_proxy_url = null,
        .ws_pty_url = null,
        .cache_dir = null,
        .cache_max_mb = 0,
    };
    const s = smithers_core_connect(core, &cfg, &err);
    defer smithers_core_disconnect(s);
    const r = smithers_core_cache_wipe(s);
    try testing.expectEqual(@as(i32, 0), r.code);
}

test "FFI: credentials expired → connect still returns session in disconnected state" {
    var err: CError = .{ .code = 0, .msg = null };
    const core = smithers_core_new(credsExpired, null, &err);
    defer smithers_core_free(core);
    const cfg = CEngineConfig{
        .engine_id = "e1",
        .base_url = "http://x",
        .shape_proxy_url = null,
        .ws_pty_url = null,
        .cache_dir = null,
        .cache_max_mb = 0,
    };
    const s = smithers_core_connect(core, &cfg, &err);
    // The session is constructed regardless so the host can retry after
    // refreshing creds; auth-expired is signaled via the event callback on
    // the next tick (wired in 0120-followup for real transport).
    try testing.expect(s != null);
    smithers_core_disconnect(s);
}
