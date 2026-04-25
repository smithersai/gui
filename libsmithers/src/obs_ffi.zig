//! C exports for the observability runtime. Header counterparts live in
//! libsmithers/include/smithers.h under the "Observability" section.

const std = @import("std");
const obs = @import("obs.zig");
const ffi = @import("ffi.zig");
const structs = @import("apprt/structs.zig");

const log = std.log.scoped(.smithers_core_obs_ffi);

// --- Callback registration ---------------------------------------------------

pub export fn smithers_obs_set_callback(
    cb: ?obs.EventCallback,
    userdata: ?*anyopaque,
) void {
    obs.setCallback(cb, userdata);
}

pub export fn smithers_obs_set_min_level(level: i32) void {
    const clamped: u8 = if (level < 0) 0 else if (level > 4) 4 else @intCast(level);
    obs.setMinLevel(@enumFromInt(clamped));
}

// --- Drain (pull API) --------------------------------------------------------

/// Returns a JSON array string of all events with seq > after_seq. Caller
/// frees with smithers_string_free.
pub export fn smithers_obs_drain_json(after_seq: u64) structs.String {
    const json = obs.drainJson(ffi.allocator, after_seq) catch |err| {
        log.warn("smithers_obs_drain_json failed: {s}", .{@errorName(err)});
        return ffi.stringDup("[]");
    };
    defer ffi.allocator.free(json);
    return ffi.stringDup(json);
}

/// Snapshot counters + per-method histograms as a JSON object.
pub export fn smithers_obs_metrics_json() structs.String {
    const json = obs.metricsJson(ffi.allocator) catch |err| {
        log.warn("smithers_obs_metrics_json failed: {s}", .{@errorName(err)});
        return ffi.stringDup("{}");
    };
    defer ffi.allocator.free(json);
    return ffi.stringDup(json);
}

// --- Convenience emit helpers (host-side instrumentation) --------------------

/// Allow the host (Swift) to push its own structured events into the same ring.
/// Useful for unifying Zig + Swift event streams in dev tools.
pub export fn smithers_obs_emit(
    level: i32,
    subsystem_z: ?[*:0]const u8,
    name_z: ?[*:0]const u8,
    duration_ms: i64, // -1 for none
    fields_json_z: ?[*:0]const u8,
) void {
    const sub = ffi.spanZ(subsystem_z);
    const name = ffi.spanZ(name_z);
    if (name.len == 0) return;
    const lvl: u8 = if (level < 0) 0 else if (level > 4) 4 else @intCast(level);
    const dur: ?i64 = if (duration_ms < 0) null else duration_ms;
    const fields: ?[]const u8 = if (fields_json_z) |p| ffi.spanZ(p) else null;
    const fields_resolved: ?[]const u8 = if (fields) |f| (if (f.len == 0) null else f) else null;
    obs.record(@enumFromInt(lvl), sub, name, dur, fields_resolved);
}

pub export fn smithers_obs_record_method(
    method_z: ?[*:0]const u8,
    duration_ms: i64,
    is_error: bool,
) void {
    const method = ffi.spanZ(method_z);
    if (method.len == 0) return;
    obs.recordMethod(method, duration_ms, is_error);
}

pub export fn smithers_obs_increment_counter(
    name_z: ?[*:0]const u8,
    delta: u64,
) void {
    const name = ffi.spanZ(name_z);
    if (name.len == 0) return;
    obs.incrementCounter(name, delta);
}
