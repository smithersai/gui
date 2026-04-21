const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");
const capi = common.capi;

// Measures the smithers_event_stream_next drain loop using local fixture
// streams created by smithers_client_stream. The reported throughput uses
// events-per-second so regressions in orderedRemove, payload duplication, or
// event freeing are visible.

const narrative =
    "smithers_event_stream_next drains fixture JSON streams of 10, 1k, and 10k events and reports events-per-second.";

const Fixture = struct {
    app: capi.App,
    client: capi.Client,
    args_json: [:0]u8,
    events: usize,

    fn create(events: usize) !*Fixture {
        const allocator = std.heap.c_allocator;
        const fixture = try allocator.create(Fixture);
        errdefer allocator.destroy(fixture);
        const app = capi.smithers_app_new(null) orelse return error.AppCreateFailed;
        errdefer capi.smithers_app_free(app);
        const client = capi.smithers_client_new(app) orelse return error.ClientCreateFailed;
        errdefer capi.smithers_client_free(client);
        fixture.* = .{
            .app = app,
            .client = client,
            .args_json = try makeEventsArg(allocator, events),
            .events = events,
        };
        return fixture;
    }

    fn destroy(self: *Fixture) void {
        const allocator = std.heap.c_allocator;
        capi.smithers_client_free(self.client);
        capi.smithers_app_free(self.app);
        allocator.free(self.args_json);
        allocator.destroy(self);
    }

    fn run(self: *Fixture, allocator: std.mem.Allocator) void {
        var arena = common.freshArena(allocator);
        defer arena.deinit();

        var err: capi.Error = undefined;
        const stream = capi.smithers_client_stream(self.client, "streamChat", self.args_json.ptr, &err);
        capi.assertOkAndFree(err);
        const s = stream orelse @panic("stream fixture returned null");
        defer capi.smithers_event_stream_free(s);

        var drained: usize = 0;
        while (true) {
            const ev = capi.smithers_event_stream_next(s);
            const tag = ev.tag;
            capi.consumeString(ev.payload);
            capi.smithers_event_free(ev);
            switch (tag) {
                .json => drained += 1,
                .end => break,
                .none => @panic("stream ended with none before end"),
                .err => @panic("stream returned error event"),
            }
        }
        if (drained != self.events) @panic("stream drained unexpected event count");
        std.mem.doNotOptimizeAway(drained);
    }
};

var ten: ?*Fixture = null;
var thousand: ?*Fixture = null;
var ten_thousand: ?*Fixture = null;

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    ten = try Fixture.create(10);
    try registry.addCleanup(@ptrCast(ten.?), cleanupFixture);
    thousand = try Fixture.create(1_000);
    try registry.addCleanup(@ptrCast(thousand.?), cleanupFixture);
    ten_thousand = try Fixture.create(10_000);
    try registry.addCleanup(@ptrCast(ten_thousand.?), cleanupFixture);

    try registry.addSimple(bench, .{
        .name = "stream.drain_10",
        .group = "stream",
        .narrative = narrative,
        .units_per_run = 10,
        .unit = "events",
    }, benchTen, common.default_config);
    try registry.addSimple(bench, .{
        .name = "stream.drain_1k",
        .group = "stream",
        .narrative = narrative,
        .units_per_run = 1_000,
        .unit = "events",
    }, benchThousand, common.withLimits(128, 200_000_000));
    try registry.addSimple(bench, .{
        .name = "stream.drain_10k",
        .group = "stream",
        .narrative = narrative,
        .units_per_run = 10_000,
        .unit = "events",
    }, benchTenThousand, common.withLimits(32, 250_000_000));
}

fn cleanupFixture(ptr: *anyopaque) void {
    const fixture: *Fixture = @ptrCast(@alignCast(ptr));
    fixture.destroy();
}

fn makeEventsArg(allocator: std.mem.Allocator, events: usize) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"events\":[");
    for (0..events) |i| {
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"seq\":{d},\"token\":\"tok-{d}\"}}", .{ i, i });
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSliceSentinel(0);
}

fn benchTen(allocator: std.mem.Allocator) void {
    (ten orelse @panic("stream 10 fixture missing")).run(allocator);
}

fn benchThousand(allocator: std.mem.Allocator) void {
    (thousand orelse @panic("stream 1k fixture missing")).run(allocator);
}

fn benchTenThousand(allocator: std.mem.Allocator) void {
    (ten_thousand orelse @panic("stream 10k fixture missing")).run(allocator);
}
