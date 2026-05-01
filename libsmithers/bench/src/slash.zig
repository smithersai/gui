const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");
const capi = common.capi;

// Measures smithers_slashcmd_parse on the shapes typed into the chat box and
// command launcher. It is synchronous on every slash submission, so quoted args
// and malformed text should not become visible latency.

const narrative =
    "smithers_slashcmd_parse tokenizes common slash command inputs, key-value flags, and malformed text without touching app state.";

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    try registry.addSimple(bench, .{
        .name = "slash.simple",
        .group = "slash",
        .narrative = narrative,
    }, benchSimple, common.default_config);
    try registry.addSimple(bench, .{
        .name = "slash.args",
        .group = "slash",
        .narrative = narrative,
    }, benchArgs, common.default_config);
    try registry.addSimple(bench, .{
        .name = "slash.flag_value",
        .group = "slash",
        .narrative = narrative,
    }, benchFlagValue, common.default_config);
    try registry.addSimple(bench, .{
        .name = "slash.malformed_text",
        .group = "slash",
        .narrative = narrative,
    }, benchMalformedText, common.default_config);
}

fn parse(input: [*:0]const u8, allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    const out = capi.smithers_slashcmd_parse(input);
    capi.consumeAndFreeString(out);
}

fn benchSimple(allocator: std.mem.Allocator) void {
    parse("/foo", allocator);
}

fn benchArgs(allocator: std.mem.Allocator) void {
    parse("/foo arg1 arg2", allocator);
}

fn benchFlagValue(allocator: std.mem.Allocator) void {
    parse("/foo --flag=value", allocator);
}

fn benchMalformedText(allocator: std.mem.Allocator) void {
    parse("not-a/slash command", allocator);
}
