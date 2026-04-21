const std = @import("std");
const lib = @import("libsmithers");
const fuzz_corpus = @import("fuzz_corpus");

const models = lib.models;

const max_input = 128 * 1024;

test "fuzz model json parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus.corpus });
}

fn fuzzOne(_: void, input: []const u8) !void {
    const bounded = input[0..@min(input.len, max_input)];
    for (models.smithers_model_descriptors) |descriptor| {
        try roundTripIfJson(descriptor.name, bounded);
    }
    for (models.app.app_model_descriptors) |descriptor| {
        try roundTripIfJson(descriptor.name, bounded);
    }
}

fn roundTripIfJson(model_name: []const u8, input: []const u8) !void {
    const out = models.roundTripJson(std.testing.allocator, model_name, input) catch return;
    defer std.testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
}
