const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");
const capi = common.capi;

// Measures the cost of creating an app, opening one workspace, creating one
// session, and freeing everything. Cold includes the top-level init boundary;
// warm is the steady-state lifecycle path after initialization has already run.

const narrative =
    "App lifecycle creates app_new, opens one workspace, creates one chat session, frees it, and frees the app; cold includes smithers_init.";

var workspace_path: ?[:0]u8 = null;

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    const cwd = std.process.getCwdAlloc(registry.allocator) catch @panic("getcwd failed");
    defer registry.allocator.free(cwd);
    workspace_path = common.dupeZ(std.heap.c_allocator, cwd);
    try registry.addCleanup(@ptrCast(workspace_path.?.ptr), cleanupPath);

    _ = capi.smithers_init(0, null);
    try registry.addSimple(bench, .{
        .name = "lifecycle.cold",
        .group = "lifecycle",
        .narrative = narrative,
    }, benchCold, common.withLimits(128, 200_000_000));
    try registry.addSimple(bench, .{
        .name = "lifecycle.warm",
        .group = "lifecycle",
        .narrative = narrative,
    }, benchWarm, common.withLimits(128, 200_000_000));
}

fn cleanupPath(ptr: *anyopaque) void {
    const bytes: [*:0]u8 = @ptrCast(@alignCast(ptr));
    const len = std.mem.len(bytes);
    std.heap.c_allocator.free(bytes[0 .. len + 1]);
}

fn benchCold(allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    _ = capi.smithers_init(0, null);
    lifecycleOnce();
}

fn benchWarm(allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    lifecycleOnce();
}

fn lifecycleOnce() void {
    const path = workspace_path orelse @panic("lifecycle workspace fixture missing");
    const app = capi.smithers_app_new(null) orelse @panic("app_new failed");
    const ws = capi.smithers_app_open_workspace(app, path.ptr) orelse @panic("open_workspace failed");
    std.mem.doNotOptimizeAway(ws);
    const session = capi.smithers_session_new(app, .{
        .kind = .chat,
        .workspace_path = path.ptr,
        .target_id = "bench-run",
        .userdata = null,
    }) orelse @panic("session_new failed");
    capi.smithers_session_free(session);
    capi.smithers_app_free(app);
}
