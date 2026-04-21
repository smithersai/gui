const std = @import("std");
const lib = @import("libsmithers");
const fuzz_corpus = @import("fuzz_corpus");

const embedded = lib.apprt.embedded;
const ffi = lib.ffi;

const max_input = 64 * 1024;

test "fuzz slash command parse" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus.corpus });
}

fn fuzzOne(_: void, input: []const u8) !void {
    const bounded = input[0..@min(input.len, max_input)];
    const input_z = try std.testing.allocator.dupeZ(u8, bounded);
    defer std.testing.allocator.free(input_z);

    const result = embedded.smithers_slashcmd_parse(input_z.ptr);
    defer ffi.stringFree(result);

    const bytes = stringSlice(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

fn stringSlice(s: lib.apprt.structs.String) []const u8 {
    return if (s.ptr) |ptr| ptr[0..s.len] else "";
}
