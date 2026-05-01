const std = @import("std");
const lib = @import("libsmithers");
const fuzz_corpus = @import("fuzz_corpus");

const embedded = lib.apprt.embedded;
const structs = lib.apprt.structs;
const ffi = lib.ffi;

const max_input = 128 * 1024;

test "fuzz persistence save sessions" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus.corpus });
}

fn fuzzOne(_: void, input: []const u8) !void {
    const bounded = input[0..@min(input.len, max_input)];
    const sessions_z = try std.testing.allocator.dupeZ(u8, bounded);
    defer std.testing.allocator.free(sessions_z);

    var open_err: structs.Error = undefined;
    const persistence = embedded.smithers_persistence_open(":memory:", &open_err) orelse {
        defer ffi.errorFree(open_err);
        return;
    };
    defer embedded.smithers_persistence_close(persistence);
    defer ffi.errorFree(open_err);

    const err = embedded.smithers_persistence_save_sessions(
        persistence,
        "/tmp/libsmithers-fuzz",
        sessions_z.ptr,
    );
    defer ffi.errorFree(err);

    const c_visible = cStringPrefix(bounded);
    const valid_array = isJsonArray(c_visible);
    if (valid_array) {
        try std.testing.expectEqual(@as(i32, 0), err.code);
    } else {
        try std.testing.expect(err.code != 0);
    }
}

fn cStringPrefix(input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, 0)) |idx| return input[0..idx];
    return input;
}

fn isJsonArray(input: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .array;
}
