const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");
const capi = common.capi;

// Measures the SQLite-backed smithers_persistence_save_sessions +
// smithers_persistence_load_sessions round-trip. The payload sizes mirror tab
// restoration bursts when reopening a workspace with many persisted sessions.

const narrative =
    "smithers_persistence_save_sessions plus smithers_persistence_load_sessions round-trip JSON arrays with 1, 10, 100, and 1000 sessions through SQLite.";

const Fixture = struct {
    persistence: capi.Persistence,
    db_path: [:0]u8,
    workspace: [:0]u8,
    sessions_json: [:0]u8,
    sessions: usize,

    fn create(sessions: usize) !*Fixture {
        const allocator = std.heap.c_allocator;
        try std.fs.cwd().makePath(".zig-cache");

        const fixture = try allocator.create(Fixture);
        errdefer allocator.destroy(fixture);

        const db_path = try fmtAllocZ(allocator, ".zig-cache/smithers-bench-sessions-{d}.sqlite", .{sessions});
        errdefer allocator.free(db_path);
        std.fs.cwd().deleteFile(db_path) catch {};

        var open_err: capi.Error = undefined;
        const persistence = capi.smithers_persistence_open(db_path.ptr, &open_err);
        capi.assertOkAndFree(open_err);
        errdefer capi.smithers_persistence_close(persistence);

        fixture.* = .{
            .persistence = persistence,
            .db_path = db_path,
            .workspace = try fmtAllocZ(allocator, "/bench/workspace-{d}", .{sessions}),
            .sessions_json = try makeSessionsJson(allocator, sessions),
            .sessions = sessions,
        };
        return fixture;
    }

    fn destroy(self: *Fixture) void {
        const allocator = std.heap.c_allocator;
        capi.smithers_persistence_close(self.persistence);
        std.fs.cwd().deleteFile(self.db_path) catch {};
        allocator.free(self.db_path);
        allocator.free(self.workspace);
        allocator.free(self.sessions_json);
        allocator.destroy(self);
    }

    fn run(self: *Fixture, allocator: std.mem.Allocator) void {
        var arena = common.freshArena(allocator);
        defer arena.deinit();
        const save_err = capi.smithers_persistence_save_sessions(self.persistence, self.workspace.ptr, self.sessions_json.ptr);
        capi.assertOkAndFree(save_err);
        const loaded = capi.smithers_persistence_load_sessions(self.persistence, self.workspace.ptr);
        capi.consumeAndFreeString(loaded);
        std.mem.doNotOptimizeAway(self.sessions);
    }
};

var one: ?*Fixture = null;
var ten: ?*Fixture = null;
var hundred: ?*Fixture = null;
var thousand: ?*Fixture = null;

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    one = try Fixture.create(1);
    try registry.addCleanup(@ptrCast(one.?), cleanupFixture);
    ten = try Fixture.create(10);
    try registry.addCleanup(@ptrCast(ten.?), cleanupFixture);
    hundred = try Fixture.create(100);
    try registry.addCleanup(@ptrCast(hundred.?), cleanupFixture);
    thousand = try Fixture.create(1_000);
    try registry.addCleanup(@ptrCast(thousand.?), cleanupFixture);

    try registry.addSimple(bench, .{
        .name = "persistence.roundtrip_1",
        .group = "persistence",
        .narrative = narrative,
        .unit = "sessions",
    }, benchOne, common.withLimits(128, 200_000_000));
    try registry.addSimple(bench, .{
        .name = "persistence.roundtrip_10",
        .group = "persistence",
        .narrative = narrative,
        .units_per_run = 10,
        .unit = "sessions",
    }, benchTen, common.withLimits(128, 200_000_000));
    try registry.addSimple(bench, .{
        .name = "persistence.roundtrip_100",
        .group = "persistence",
        .narrative = narrative,
        .units_per_run = 100,
        .unit = "sessions",
    }, benchHundred, common.withLimits(64, 200_000_000));
    try registry.addSimple(bench, .{
        .name = "persistence.roundtrip_1000",
        .group = "persistence",
        .narrative = narrative,
        .units_per_run = 1_000,
        .unit = "sessions",
    }, benchThousand, common.withLimits(32, 250_000_000));
}

fn cleanupFixture(ptr: *anyopaque) void {
    const fixture: *Fixture = @ptrCast(@alignCast(ptr));
    fixture.destroy();
}

fn makeSessionsJson(allocator: std.mem.Allocator, sessions: usize) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (0..sessions) |i| {
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"id\":\"session-{d}\",\"kind\":\"chat\",\"targetId\":\"run-{d}\",\"title\":\"Chat {d}\",\"workspacePath\":\"/bench/workspace\"}}",
            .{ i, i, i },
        );
    }
    try out.writer.writeByte(']');
    return out.toOwnedSliceSentinel(0);
}

fn fmtAllocZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    return allocator.dupeZ(u8, bytes);
}

fn benchOne(allocator: std.mem.Allocator) void {
    (one orelse @panic("persistence 1 fixture missing")).run(allocator);
}

fn benchTen(allocator: std.mem.Allocator) void {
    (ten orelse @panic("persistence 10 fixture missing")).run(allocator);
}

fn benchHundred(allocator: std.mem.Allocator) void {
    (hundred orelse @panic("persistence 100 fixture missing")).run(allocator);
}

fn benchThousand(allocator: std.mem.Allocator) void {
    (thousand orelse @panic("persistence 1000 fixture missing")).run(allocator);
}
