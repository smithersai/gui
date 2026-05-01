//! Process-wide observability runtime for libsmithers.
//!
//! Three jobs:
//!   1. Buffer structured events in a thread-safe drop-oldest ring so the host
//!      can drain them on its own cadence (Swift dev tools poll this).
//!   2. Push the same events to an optional host callback for real-time tap.
//!   3. Track per-method latency histograms and named counters that the host
//!      can snapshot as JSON for live dashboards.
//!
//! Design notes:
//!   - Lives in process-static state. Initialised lazily on first use.
//!   - All state guarded by a single mutex. We're not in the hot path of any
//!     latency-sensitive loop; correctness over micro-optimisation.
//!   - Event strings stored in an arena that resets when the ring laps. The
//!     ring slot we're about to overwrite already won the last reference.
//!   - Histogram = exponential bucket cumulative counts (1ms .. 60s, 13 buckets).
//!     Cheap, low-resolution, sufficient for "is this slow?" dev tooling.

const std = @import("std");

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

pub const Event = struct {
    seq: u64,
    timestamp_ms: i64,
    level: Level,
    subsystem: []const u8,
    name: []const u8,
    duration_ms: ?i64 = null,
    fields_json: ?[]const u8 = null,
};

pub const EventCallback = *const fn (
    userdata: ?*anyopaque,
    seq: u64,
    timestamp_ms: i64,
    level: u8,
    subsystem_z: [*:0]const u8,
    name_z: [*:0]const u8,
    duration_ms: i64, // -1 when none
    fields_json_z: ?[*:0]const u8,
) callconv(.c) void;

const ring_capacity: usize = 2048;

pub const histogram_bucket_count: usize = 13;
pub const histogram_upper_ms = [histogram_bucket_count]i64{
    1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 5000, 60000, std.math.maxInt(i64),
};

const MethodStats = struct {
    count: u64 = 0,
    error_count: u64 = 0,
    total_ms: i128 = 0,
    max_ms: i64 = 0,
    last_ms: i64 = 0,
    buckets: [histogram_bucket_count]u64 = @splat(0),

    fn record(self: *MethodStats, duration_ms: i64, is_error: bool) void {
        self.count += 1;
        if (is_error) self.error_count += 1;
        self.total_ms += duration_ms;
        if (duration_ms > self.max_ms) self.max_ms = duration_ms;
        self.last_ms = duration_ms;
        for (histogram_upper_ms, 0..) |upper, i| {
            if (duration_ms <= upper) {
                self.buckets[i] += 1;
                break;
            }
        }
    }
};

const State = struct {
    mu: std.Thread.Mutex = .{},
    arena_state: std.heap.ArenaAllocator,
    arena: std.mem.Allocator,
    backing: std.mem.Allocator,

    ring: [ring_capacity]?Event = @splat(null),
    head: usize = 0, // next write slot
    seq: u64 = 0,
    dropped: u64 = 0,

    callback: ?EventCallback = null,
    callback_userdata: ?*anyopaque = null,
    min_level: Level = .debug,

    counters: std.StringHashMap(u64),
    methods: std.StringHashMap(MethodStats),
    started_at_ms: i64,

    fn init(self: *State, backing: std.mem.Allocator) void {
        self.* = .{
            .arena_state = std.heap.ArenaAllocator.init(backing),
            .arena = undefined,
            .backing = backing,
            .counters = std.StringHashMap(u64).init(backing),
            .methods = std.StringHashMap(MethodStats).init(backing),
            .started_at_ms = std.time.milliTimestamp(),
        };
        self.arena = self.arena_state.allocator();
    }
};

var state_storage: State = undefined;
var state_init = std.once(initState);

fn initState() void {
    state_storage.init(std.heap.c_allocator);
}

fn st() *State {
    state_init.call();
    return &state_storage;
}

pub fn nowMs() i64 {
    return std.time.milliTimestamp();
}

pub fn setCallback(cb: ?EventCallback, userdata: ?*anyopaque) void {
    const s = st();
    s.mu.lock();
    defer s.mu.unlock();
    s.callback = cb;
    s.callback_userdata = userdata;
}

pub fn setMinLevel(level: Level) void {
    const s = st();
    s.mu.lock();
    defer s.mu.unlock();
    s.min_level = level;
}

pub fn currentMinLevel() Level {
    const s = st();
    s.mu.lock();
    defer s.mu.unlock();
    return s.min_level;
}

/// Record an event. `subsystem` and `name` are usually static strings. `fields_json`,
/// if provided, must be a complete JSON object; we copy it. Duration in ms or null.
pub fn record(
    level: Level,
    subsystem: []const u8,
    name: []const u8,
    duration_ms: ?i64,
    fields_json: ?[]const u8,
) void {
    const s = st();
    s.mu.lock();
    if (@intFromEnum(level) < @intFromEnum(s.min_level)) {
        s.mu.unlock();
        return;
    }

    // When the ring fully laps, reset the arena and clear stale slots so we
    // never read freed memory. This is the only point where event strings
    // become invalid. Hosts that have not drained by then lose those events.
    if (s.head == 0 and s.seq != 0) {
        _ = s.arena_state.reset(.retain_capacity);
        s.ring = @splat(null);
    }

    const subsystem_copy = s.arena.dupe(u8, subsystem) catch {
        s.dropped += 1;
        s.mu.unlock();
        return;
    };
    const name_copy = s.arena.dupe(u8, name) catch {
        s.dropped += 1;
        s.mu.unlock();
        return;
    };
    const fields_copy: ?[]const u8 = if (fields_json) |f|
        s.arena.dupe(u8, f) catch null
    else
        null;

    s.seq += 1;
    const ev = Event{
        .seq = s.seq,
        .timestamp_ms = nowMs(),
        .level = level,
        .subsystem = subsystem_copy,
        .name = name_copy,
        .duration_ms = duration_ms,
        .fields_json = fields_copy,
    };

    if (s.ring[s.head] != null) s.dropped += 1;
    s.ring[s.head] = ev;
    s.head = (s.head + 1) % ring_capacity;

    const cb = s.callback;
    const ud = s.callback_userdata;
    s.mu.unlock();

    if (cb) |func| {
        var sub_buf: [256]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        const sub_z = toStackZ(&sub_buf, ev.subsystem) orelse return;
        const name_z = toStackZ(&name_buf, ev.name) orelse return;

        var fields_z_buf: ?[:0]u8 = null;
        defer if (fields_z_buf) |b| std.heap.c_allocator.free(b);
        var fields_z_ptr: ?[*:0]const u8 = null;
        if (ev.fields_json) |f| {
            fields_z_buf = std.heap.c_allocator.dupeZ(u8, f) catch null;
            if (fields_z_buf) |b| fields_z_ptr = b.ptr;
        }

        func(
            ud,
            ev.seq,
            ev.timestamp_ms,
            @intFromEnum(ev.level),
            sub_z,
            name_z,
            ev.duration_ms orelse -1,
            fields_z_ptr,
        );
    }
}

fn toStackZ(buf: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len + 1 > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// Drain all events with seq > `after_seq` to a JSON array string.
pub fn drainJson(allocator: std.mem.Allocator, after_seq: u64) ![]u8 {
    const s = st();
    s.mu.lock();
    defer s.mu.unlock();

    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    for (s.ring, 0..) |slot, i| {
        if (slot) |ev| if (ev.seq > after_seq) try indices.append(allocator, i);
    }
    std.mem.sort(usize, indices.items, s, struct {
        fn lt(state: *State, a: usize, b: usize) bool {
            return state.ring[a].?.seq < state.ring[b].?.seq;
        }
    }.lt);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeByte('[');
    for (indices.items, 0..) |idx, i| {
        const ev = s.ring[idx].?;
        if (i != 0) try w.writeByte(',');
        try w.writeByte('{');
        try w.print("\"seq\":{d}", .{ev.seq});
        try w.print(",\"ts_ms\":{d}", .{ev.timestamp_ms});
        try w.print(",\"level\":{d}", .{@intFromEnum(ev.level)});
        try w.writeAll(",\"subsystem\":");
        try writeJsonString(w, ev.subsystem);
        try w.writeAll(",\"name\":");
        try writeJsonString(w, ev.name);
        if (ev.duration_ms) |d| try w.print(",\"duration_ms\":{d}", .{d});
        if (ev.fields_json) |f| try w.print(",\"fields\":{s}", .{f});
        try w.writeByte('}');
    }
    try w.writeByte(']');

    return try out.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

pub fn incrementCounter(name: []const u8, delta: u64) void {
    const s = st();
    s.mu.lock();
    defer s.mu.unlock();
    const gop = s.counters.getOrPut(name) catch return;
    if (!gop.found_existing) {
        const owned = s.backing.dupe(u8, name) catch {
            _ = s.counters.remove(name);
            return;
        };
        gop.key_ptr.* = owned;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += delta;
}

pub fn recordMethod(method: []const u8, duration_ms: i64, is_error: bool) void {
    const s = st();
    s.mu.lock();
    defer s.mu.unlock();
    const gop = s.methods.getOrPut(method) catch return;
    if (!gop.found_existing) {
        const owned = s.backing.dupe(u8, method) catch {
            _ = s.methods.remove(method);
            return;
        };
        gop.key_ptr.* = owned;
        gop.value_ptr.* = .{};
    }
    gop.value_ptr.record(duration_ms, is_error);
}

pub fn metricsJson(allocator: std.mem.Allocator) ![]u8 {
    const s = st();
    s.mu.lock();
    defer s.mu.unlock();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeByte('{');
    try w.print("\"started_at_ms\":{d}", .{s.started_at_ms});
    try w.print(",\"now_ms\":{d}", .{nowMs()});
    try w.print(",\"events_seq\":{d}", .{s.seq});
    try w.print(",\"events_dropped\":{d}", .{s.dropped});
    try w.print(",\"events_capacity\":{d}", .{ring_capacity});
    try w.print(",\"min_level\":{d}", .{@intFromEnum(s.min_level)});

    try w.writeAll(",\"counters\":{");
    var ci = s.counters.iterator();
    var first_counter = true;
    while (ci.next()) |entry| {
        if (!first_counter) try w.writeByte(',');
        first_counter = false;
        try writeJsonString(w, entry.key_ptr.*);
        try w.print(":{d}", .{entry.value_ptr.*});
    }
    try w.writeByte('}');

    try w.writeAll(",\"methods\":{");
    var mi = s.methods.iterator();
    var first_method = true;
    while (mi.next()) |entry| {
        const stats = entry.value_ptr.*;
        if (!first_method) try w.writeByte(',');
        first_method = false;
        try writeJsonString(w, entry.key_ptr.*);
        try w.writeAll(":{");
        try w.print("\"count\":{d}", .{stats.count});
        try w.print(",\"errors\":{d}", .{stats.error_count});
        try w.print(",\"max_ms\":{d}", .{stats.max_ms});
        try w.print(",\"last_ms\":{d}", .{stats.last_ms});
        const avg: f64 = if (stats.count == 0) 0 else @as(f64, @floatFromInt(stats.total_ms)) / @as(f64, @floatFromInt(stats.count));
        try w.print(",\"avg_ms\":{d:.2}", .{avg});
        try w.writeAll(",\"buckets\":[");
        for (stats.buckets, 0..) |b, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{d}", .{b});
        }
        try w.writeByte(']');
        try w.writeAll(",\"bucket_upper_ms\":[");
        for (histogram_upper_ms, 0..) |u, i| {
            if (i != 0) try w.writeByte(',');
            // i64 max is huge; emit -1 sentinel for the +Inf bucket.
            const printed: i64 = if (u == std.math.maxInt(i64)) -1 else u;
            try w.print("{d}", .{printed});
        }
        try w.writeAll("]}");
    }
    try w.writeByte('}');

    try w.writeByte('}');
    return try out.toOwnedSlice();
}

/// Convenience: record a span ending now, with a duration computed from `start_ns`.
pub fn recordSpan(
    level: Level,
    subsystem: []const u8,
    name: []const u8,
    start_ns: i128,
    fields_json: ?[]const u8,
) void {
    const now_ns = std.time.nanoTimestamp();
    const dur_ms: i64 = @intCast(@divTrunc(now_ns - start_ns, std.time.ns_per_ms));
    record(level, subsystem, name, dur_ms, fields_json);
}

test "record + drain roundtrip" {
    const allocator = std.testing.allocator;
    setMinLevel(.trace);
    record(.info, "test", "hello", null, null);
    record(.warn, "test", "world", 42, "{\"k\":\"v\"}");
    const json = try drainJson(allocator, 0);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"duration_ms\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fields\":{\"k\":\"v\"}") != null);
}

test "metrics counter + method snapshot" {
    const allocator = std.testing.allocator;
    incrementCounter("test.unit.counter", 3);
    incrementCounter("test.unit.counter", 4);
    recordMethod("test.unit.method", 5, false);
    recordMethod("test.unit.method", 250, true);
    const json = try metricsJson(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"test.unit.counter\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"test.unit.method\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"errors\":1") != null);
}
