//! Shared logging + span helpers for libsmithers.
//!
//! Two layers:
//!
//!   * `std.log` scoped loggers — for free-text traces, owned by the host's
//!     `std_options.logFn`. libsmithers does NOT install its own.
//!
//!   * `obs.zig` ring buffer + callback — for structured events the Swift dev
//!     tools (and any future tap) can pull or subscribe to. Spans, counters,
//!     and per-method histograms all live there.
//!
//! Usage:
//!   const std = @import("std");
//!   const logx = @import("../log.zig");
//!   const log = std.log.scoped(.smithers_core_<module>);
//!
//!   log.info("session opened id={s}", .{id});
//!   doThing() catch |err| logx.catchWarn(log, "doThing", err);
//!
//!   // Span: timed structured event
//!   var sp = logx.beginSpan("core.session", "open");
//!   defer sp.end(.info, null);
//!
//!   // Method tracking (per-method histogram + counter):
//!   var t = logx.startTimer();
//!   defer logx.recordMethod("client.call.listWorkflows", t, false);
//!
//! This intentionally mirrors `linux/src/log.zig` so the two codebases share
//! conventions.

const std = @import("std");
const obs = @import("obs.zig");

pub const Level = obs.Level;

pub fn catchWarn(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.warn(context ++ " failed: {s}", .{@errorName(err)});
    recordError(.warn, "smithers", context, err);
}

pub fn catchErr(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.err(context ++ " failed: {s}", .{@errorName(err)});
    recordError(.err, "smithers", context, err);
}

pub fn catchDebug(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.debug(context ++ " errored: {s}", .{@errorName(err)});
    recordError(.debug, "smithers", context, err);
}

/// Emit a structured error event into the observability ring. Use at any
/// catch site where the surrounding context warrants a dev-tools breadcrumb.
pub fn recordError(level: Level, subsystem: []const u8, name: []const u8, err: anyerror) void {
    var buf: [128]u8 = undefined;
    const fields = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
    obs.record(level, subsystem, name, null, fields);
}

pub const Timer = struct {
    start_ns: i128,

    pub fn elapsedMs(self: Timer) i64 {
        const now = std.time.nanoTimestamp();
        const delta = now - self.start_ns;
        return @intCast(@divTrunc(delta, std.time.ns_per_ms));
    }
};

pub fn startTimer() Timer {
    return .{ .start_ns = std.time.nanoTimestamp() };
}

pub fn endTimer(comptime log: anytype, comptime label: []const u8, timer: Timer) void {
    log.info(label ++ " took {d}ms", .{timer.elapsedMs()});
    obs.record(.info, "smithers", label, timer.elapsedMs(), null);
}

pub fn endTimerDebug(comptime log: anytype, comptime label: []const u8, timer: Timer) void {
    log.debug(label ++ " took {d}ms", .{timer.elapsedMs()});
    obs.record(.debug, "smithers", label, timer.elapsedMs(), null);
}

pub fn event(comptime log: anytype, comptime name: []const u8, comptime fmt: []const u8, args: anytype) void {
    log.info("event=" ++ name ++ " " ++ fmt, args);
    obs.record(.info, "smithers", name, null, null);
}

/// Record a per-method observation: increments method counter and feeds the
/// duration into the latency histogram. Use for FFI/RPC dispatch wrappers.
pub fn recordMethod(name: []const u8, timer: Timer, is_error: bool) void {
    obs.recordMethod(name, timer.elapsedMs(), is_error);
}

pub fn incrementCounter(name: []const u8, delta: u64) void {
    obs.incrementCounter(name, delta);
}

/// A timed scoped event. Begin, then call `end` (or `endError`) to emit a
/// structured record carrying duration. `subsystem` is typically the scope
/// name; `name` is the operation (e.g. "smithers_client_call").
pub const Span = struct {
    subsystem: []const u8,
    name: []const u8,
    started_ns: i128,
    method_key: ?[]const u8 = null,
    fields_json: ?[]const u8 = null,

    pub fn end(self: Span, level: Level, fields_json: ?[]const u8) void {
        const dur = computeMs(self.started_ns);
        obs.record(level, self.subsystem, self.name, dur, fields_json orelse self.fields_json);
        if (self.method_key) |k| obs.recordMethod(k, dur, false);
    }

    pub fn endError(self: Span, fields_json: ?[]const u8) void {
        const dur = computeMs(self.started_ns);
        obs.record(.err, self.subsystem, self.name, dur, fields_json orelse self.fields_json);
        if (self.method_key) |k| obs.recordMethod(k, dur, true);
    }
};

fn computeMs(started_ns: i128) i64 {
    const delta = std.time.nanoTimestamp() - started_ns;
    return @intCast(@divTrunc(delta, std.time.ns_per_ms));
}

pub fn beginSpan(subsystem: []const u8, name: []const u8) Span {
    return .{
        .subsystem = subsystem,
        .name = name,
        .started_ns = std.time.nanoTimestamp(),
    };
}

/// Begin a span and also tag it with a method key so end()/endError() will
/// feed the per-method latency histogram. Keep `method_key` static (it's used
/// as a stable map key in the metrics snapshot).
pub fn beginMethodSpan(subsystem: []const u8, name: []const u8, method_key: []const u8) Span {
    return .{
        .subsystem = subsystem,
        .name = name,
        .started_ns = std.time.nanoTimestamp(),
        .method_key = method_key,
    };
}
