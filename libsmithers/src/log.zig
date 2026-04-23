//! Shared logging helpers for libsmithers.
//!
//! Usage:
//!   const std = @import("std");
//!   const logx = @import("../log.zig");
//!   const log = std.log.scoped(.smithers_core_<module>);
//!
//!   log.info("session opened id={s}", .{id});
//!   doThing() catch |err| logx.catchWarn(log, "doThing", err);
//!
//! This intentionally mirrors `linux/src/log.zig` so the two codebases share
//! conventions. libsmithers is a library — it does NOT install a custom
//! `std_options.logFn`; the host binary (smithers-gtk, Smithers.app) owns
//! log routing. These helpers only make call-sites uniform.

const std = @import("std");

pub fn catchWarn(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.warn(context ++ " failed: {s}", .{@errorName(err)});
}

pub fn catchErr(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.err(context ++ " failed: {s}", .{@errorName(err)});
}

pub fn catchDebug(comptime log: anytype, comptime context: []const u8, err: anyerror) void {
    log.debug(context ++ " errored: {s}", .{@errorName(err)});
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
}

pub fn endTimerDebug(comptime log: anytype, comptime label: []const u8, timer: Timer) void {
    log.debug(label ++ " took {d}ms", .{timer.elapsedMs()});
}

pub fn event(comptime log: anytype, comptime name: []const u8, comptime fmt: []const u8, args: anytype) void {
    log.info("event=" ++ name ++ " " ++ fmt, args);
}
