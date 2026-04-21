const std = @import("std");
const structs = @import("apprt/structs.zig");

pub const allocator = std.heap.c_allocator;

pub fn spanZ(ptr: ?[*:0]const u8) []const u8 {
    return if (ptr) |p| std.mem.sliceTo(p, 0) else "";
}

pub fn dupZ(bytes: []const u8) ![:0]u8 {
    return allocator.dupeZ(u8, bytes);
}

pub fn stringFromOwnedZ(s: [:0]u8) structs.String {
    return .{ .ptr = s.ptr, .len = s.len };
}

pub fn stringDup(bytes: []const u8) structs.String {
    const owned = dupZ(bytes) catch return .{ .ptr = null, .len = 0 };
    return stringFromOwnedZ(owned);
}

pub fn stringJson(value: anytype) structs.String {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch return stringDup("null");
    const owned = out.toOwnedSliceSentinel(0) catch return .{ .ptr = null, .len = 0 };
    return stringFromOwnedZ(owned);
}

pub fn stringFree(s: structs.String) void {
    const ptr = s.ptr orelse return;
    const raw: [*:0]u8 = @constCast(ptr);
    allocator.free(raw[0 .. s.len + 1]);
}

pub fn errorSuccess() structs.Error {
    return .{ .code = 0, .msg = null };
}

pub fn errorMessage(code: i32, msg: []const u8) structs.Error {
    const owned = dupZ(msg) catch return .{ .code = code, .msg = null };
    return .{ .code = code, .msg = owned.ptr };
}

pub fn errorFrom(comptime prefix: []const u8, err: anyerror) structs.Error {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, prefix ++ ": {}", .{err}) catch prefix;
    return errorMessage(1, msg);
}

pub fn errorFree(e: structs.Error) void {
    const ptr = e.msg orelse return;
    const raw: [*:0]u8 = @constCast(ptr);
    allocator.free(raw[0 .. std.mem.len(ptr) + 1]);
}

pub fn bytesDup(bytes: []const u8) structs.Bytes {
    const owned = allocator.dupe(u8, bytes) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = owned.ptr, .len = owned.len };
}

pub fn bytesFree(b: structs.Bytes) void {
    const ptr = b.ptr orelse return;
    const raw: [*]u8 = @constCast(ptr);
    allocator.free(raw[0..b.len]);
}

pub fn parseJson(input: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, input, .{});
}

pub fn jsonObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const found = value.object.get(key) orelse return null;
    return switch (found) {
        .string => |s| s,
        else => null,
    };
}

pub fn jsonObjectBool(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const found = value.object.get(key) orelse return null;
    return switch (found) {
        .bool => |b| b,
        else => null,
    };
}

pub fn jsonObjectInteger(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const found = value.object.get(key) orelse return null;
    return switch (found) {
        .integer => |i| i,
        else => null,
    };
}
