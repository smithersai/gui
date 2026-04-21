const std = @import("std");
const lib = @import("libsmithers");
const fuzz_corpus = @import("fuzz_corpus");

const App = lib.App;
const Palette = lib.commands.palette.Palette;
const structs = lib.apprt.structs;
const ffi = lib.ffi;

const max_query = 16 * 1024;

const modes = [_]structs.PaletteMode{
    .all,
    .commands,
    .files,
    .workflows,
    .workspaces,
    .runs,
};

test "fuzz palette query" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus.corpus });
}

fn fuzzOne(_: void, input: []const u8) !void {
    const selector = if (input.len == 0) 0 else input[0];
    const query_raw = if (input.len > 1) input[1..] else "";
    const query = query_raw[0..@min(query_raw.len, max_query)];

    var app = try App.create(std.testing.allocator, .{});
    defer app.destroy();
    var palette = try Palette.create(app);
    defer palette.destroy();

    palette.setMode(modes[selector % modes.len]);
    palette.setQuery(query);

    const result = palette.itemsJson();
    defer ffi.stringFree(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stringSlice(result), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
}

fn stringSlice(s: structs.String) []const u8 {
    return if (s.ptr) |ptr| ptr[0..s.len] else "";
}
