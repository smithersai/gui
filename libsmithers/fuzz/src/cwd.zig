const std = @import("std");
const lib = @import("libsmithers");
const fuzz_corpus = @import("fuzz_corpus");

const embedded = lib.apprt.embedded;
const ffi = lib.ffi;

const max_input = 16 * 1024;

test "fuzz cwd resolve" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus.corpus });
}

fn fuzzOne(_: void, input: []const u8) !void {
    const bounded = input[0..@min(input.len, max_input)];

    const input_z = try std.testing.allocator.dupeZ(u8, bounded);
    defer std.testing.allocator.free(input_z);
    const result = embedded.smithers_cwd_resolve(input_z.ptr);
    defer ffi.stringFree(result);
    _ = stringSlice(result);

    if (std.mem.indexOfScalar(u8, bounded, 0) != null) return;

    const direct = lib.workspace.cwd.resolve(std.testing.allocator, bounded) catch return;
    defer std.testing.allocator.free(direct);
}

fn stringSlice(s: lib.apprt.structs.String) []const u8 {
    return if (s.ptr) |ptr| ptr[0..s.len] else "";
}
