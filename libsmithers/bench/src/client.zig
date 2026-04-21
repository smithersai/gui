const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");
const capi = common.capi;

// Measures smithers_client_call without network or CLI fallback work. The echo
// and listRuns cases stay in the local JSON dispatch path, isolating the ABI
// call, JSON parse, and core-owned string return/free cost.

const narrative =
    "smithers_client_call crosses the C ABI and exercises local JSON dispatch only: echo returns small and empty payloads without network or CLI fallback.";

const Fixture = struct {
    app: capi.App,
    client: capi.Client,

    fn create() !*Fixture {
        const allocator = std.heap.c_allocator;
        const ctx = try allocator.create(Fixture);
        errdefer allocator.destroy(ctx);
        const app = capi.smithers_app_new(null) orelse return error.AppCreateFailed;
        errdefer capi.smithers_app_free(app);
        const client = capi.smithers_client_new(app) orelse return error.ClientCreateFailed;
        ctx.* = .{ .app = app, .client = client };
        return ctx;
    }

    fn destroy(self: *Fixture) void {
        const allocator = std.heap.c_allocator;
        capi.smithers_client_free(self.client);
        capi.smithers_app_free(self.app);
        allocator.destroy(self);
    }
};

var fixture: ?*Fixture = null;

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    fixture = try Fixture.create();
    try registry.addCleanup(@ptrCast(fixture.?), cleanupFixture);

    try registry.addSimple(bench, .{
        .name = "client.call_echo",
        .group = "client",
        .narrative = narrative,
    }, benchEcho, common.withLimits(2048, 200_000_000));
    try registry.addSimple(bench, .{
        .name = "client.call_echo_empty",
        .group = "client",
        .narrative = narrative,
    }, benchEchoEmpty, common.withLimits(2048, 200_000_000));
}

fn cleanupFixture(ptr: *anyopaque) void {
    const f: *Fixture = @ptrCast(@alignCast(ptr));
    f.destroy();
}

fn call(method: [*:0]const u8, args: [*:0]const u8, allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    const f = fixture orelse @panic("client fixture missing");
    var err: capi.Error = undefined;
    const out = capi.smithers_client_call(f.client, method, args, &err);
    capi.assertOkAndFree(err);
    capi.consumeAndFreeString(out);
}

fn benchEcho(allocator: std.mem.Allocator) void {
    call("echo", "{\"message\":\"hello\",\"n\":42}", allocator);
}

fn benchEchoEmpty(allocator: std.mem.Allocator) void {
    call("echo", "{}", allocator);
}
