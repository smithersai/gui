const std = @import("std");
const lib = @import("libsmithers");

pub const embedded = lib.apprt.embedded;
pub const structs = lib.apprt.structs;
pub const ffi = lib.ffi;

pub fn stringSlice(s: structs.String) []const u8 {
    return if (s.ptr) |ptr| ptr[0..s.len] else "";
}

pub fn errorMessageSlice(e: structs.Error) []const u8 {
    return if (e.msg) |ptr| std.mem.sliceTo(ptr, 0) else "";
}

pub fn expectJsonValid(json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    parsed.deinit();
}

pub fn expectJsonArray(json: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    errdefer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    return parsed;
}

pub fn expectJsonObject(json: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    errdefer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    return parsed;
}

pub fn tempPath(tmp: *std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    return try tmp.dir.realpathAlloc(std.testing.allocator, sub_path);
}

pub fn dupeZ(bytes: []const u8) ![:0]u8 {
    return try std.testing.allocator.dupeZ(u8, bytes);
}

pub fn makeSessionJson(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (0..count) |i| {
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"id\":\"session-{d}\",\"kind\":\"chat\",\"targetId\":\"run-{d}\",\"title\":\"Chat {d}\",\"metadata\":{{\"index\":{d},\"active\":{}}}}}",
            .{ i, i, i, i, i % 2 == 0 },
        );
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

pub fn expectError(e: structs.Error, expected_code: i32, expected_msg_part: []const u8) !void {
    try std.testing.expectEqual(expected_code, e.code);
    if (expected_msg_part.len > 0) {
        try std.testing.expect(std.mem.indexOf(u8, errorMessageSlice(e), expected_msg_part) != null);
    }
}

pub fn expectSuccess(e: structs.Error) !void {
    try std.testing.expectEqual(@as(i32, 0), e.code);
    try std.testing.expectEqual(@as(?[*:0]const u8, null), e.msg);
}
