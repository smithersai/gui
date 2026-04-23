//! Shared logging helpers for smithers-gtk.
//!
//! Conventions:
//!   const std = @import("std");
//!   const logx = @import("../log.zig");
//!   const log = std.log.scoped(.view_runs);
//!
//!   log.info("run selected run_id={s} index={d}", .{ id, idx });
//!   doThing() catch |err| logx.catchWarn(log, "doThing", err);
//!
//! Use `startTimer`/`endTimer` to record the duration of a block:
//!
//!   const t = logx.startTimer();
//!   defer logx.endTimer(log, "refresh", t);

const std = @import("std");
const builtin = @import("builtin");

/// Log a caught error at `warn` level. Keeps call-sites to one line and
/// always includes the error name.
pub fn catchWarn(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.warn(context ++ " failed: {s}", .{@errorName(err)});
}

/// Log a caught error at `err` level. Use when the failure breaks an
/// invariant (vs. catchWarn for recoverable paths).
pub fn catchErr(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.err(context ++ " failed: {s}", .{@errorName(err)});
}

/// Log a caught error at `debug` level. Use for expected error paths that
/// we only care about while debugging (cancellation, missing-optional, ...).
pub fn catchDebug(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.debug(context ++ " errored: {s}", .{@errorName(err)});
}

/// Opaque timer handle. Captures a monotonic timestamp at construction.
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

/// Log the duration of a scope at `info` level.
pub fn endTimer(comptime log: anytype, comptime label: []const u8, timer: Timer) void {
    log.info(label ++ " took {d}ms", .{timer.elapsedMs()});
}

/// Log the duration of a scope at `debug` level.
pub fn endTimerDebug(comptime log: anytype, comptime label: []const u8, timer: Timer) void {
    log.debug(label ++ " took {d}ms", .{timer.elapsedMs()});
}

/// Emit a structured lifecycle event ("open", "close", "refresh", ...) so
/// we can grep for `event=` consistently across the codebase.
pub fn event(comptime log: anytype, comptime name: []const u8, comptime fmt: []const u8, args: anytype) void {
    log.info("event=" ++ name ++ " " ++ fmt, args);
}

/// Default runtime log level: Debug builds -> debug, Release -> info.
/// Overridable by the root module via `std_options.log_level`.
pub const default_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

/// Parse a log level string (case-insensitive) returning null on unknown.
pub fn parseLevel(s: []const u8) ?std.log.Level {
    if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(s, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(s, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(s, "error")) return .err;
    return null;
}

/// Custom logFn: `[+1234ms] [LEVEL] [scope] message`.
/// Install via:
///   pub const std_options: std.Options = .{ .logFn = smithers_log.logFn, ... };
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_str = switch (level) {
        .err => "ERROR",
        .warn => "WARN ",
        .info => "INFO ",
        .debug => "DEBUG",
    };
    const scope_str = if (scope == .default) "default" else @tagName(scope);

    var buffer: [128]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    const now_ns = std.time.nanoTimestamp();
    const start = process_start_ns.load(.monotonic);
    const ms_since_start: i64 = if (start == 0)
        0
    else
        @intCast(@divTrunc(now_ns - start, std.time.ns_per_ms));

    stderr.print("[+{d:>7}ms] [{s}] [{s}] ", .{ ms_since_start, level_str, scope_str }) catch return;
    stderr.print(format, args) catch return;
    stderr.writeByte('\n') catch return;
}

var process_start_ns: std.atomic.Value(i128) = .init(0);

/// Call once near the top of main() so timestamps are relative to launch.
pub fn initProcessClock() void {
    process_start_ns.store(std.time.nanoTimestamp(), .monotonic);
}
