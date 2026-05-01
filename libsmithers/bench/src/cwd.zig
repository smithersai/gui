const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");
const capi = common.capi;

// Measures smithers_cwd_resolve as the UI calls it while opening workspaces.
// The path is expected to behave like a pure string resolver, so the benchmark
// keeps inputs tiny and makes any filesystem cost obvious in ns/op.

const narrative =
    "smithers_cwd_resolve resolves null, home aliases, absolute paths, and invalid paths; this should stay below UI-frame budget because workspace opening calls it synchronously.";

var absolute_cwd: ?[:0]u8 = null;

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    const cwd = std.process.getCwdAlloc(registry.allocator) catch @panic("getcwd failed");
    defer registry.allocator.free(cwd);
    absolute_cwd = common.dupeZ(std.heap.c_allocator, cwd);
    try registry.addCleanup(@ptrCast(absolute_cwd.?.ptr), cleanupAbsolute);

    try registry.addSimple(bench, .{
        .name = "cwd.null_default",
        .group = "cwd",
        .narrative = narrative,
    }, benchNullDefault, common.default_config);
    try registry.addSimple(bench, .{
        .name = "cwd.home_alias_slash",
        .group = "cwd",
        .narrative = narrative,
    }, benchHomeAliasSlash, common.default_config);
    try registry.addSimple(bench, .{
        .name = "cwd.absolute_existing",
        .group = "cwd",
        .narrative = narrative,
    }, benchAbsoluteExisting, common.default_config);
    try registry.addSimple(bench, .{
        .name = "cwd.invalid_fallback",
        .group = "cwd",
        .narrative = narrative,
    }, benchInvalidFallback, common.default_config);
}

fn cleanupAbsolute(ptr: *anyopaque) void {
    const bytes: [*:0]u8 = @ptrCast(@alignCast(ptr));
    const len = std.mem.len(bytes);
    std.heap.c_allocator.free(bytes[0 .. len + 1]);
}

fn benchNullDefault(allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    const out = capi.smithers_cwd_resolve(null);
    capi.consumeAndFreeString(out);
}

fn benchHomeAliasSlash(allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    const out = capi.smithers_cwd_resolve("/");
    capi.consumeAndFreeString(out);
}

fn benchAbsoluteExisting(allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    const path = absolute_cwd orelse @panic("cwd fixture missing");
    const out = capi.smithers_cwd_resolve(path.ptr);
    capi.consumeAndFreeString(out);
}

fn benchInvalidFallback(allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    const out = capi.smithers_cwd_resolve("/definitely/not/a/smithers/workspace");
    capi.consumeAndFreeString(out);
}
