const std = @import("std");
const structs = @import("../apprt/structs.zig");
const ffi = @import("../ffi.zig");

const Allocator = std.mem.Allocator;

pub const QueuedEvent = struct {
    tag: structs.EventTag,
    payload: []u8,
};

pub const EventStream = @This();

allocator: Allocator,
events: std.ArrayList(QueuedEvent) = .empty,
closed: bool = false,
end_emitted: bool = false,

pub fn create(allocator: Allocator) !*EventStream {
    const stream = try allocator.create(EventStream);
    stream.* = .{ .allocator = allocator };
    return stream;
}

pub fn destroy(self: *EventStream) void {
    for (self.events.items) |event| self.allocator.free(event.payload);
    self.events.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn pushJson(self: *EventStream, payload: []const u8) !void {
    try self.push(.json, payload);
}

pub fn pushError(self: *EventStream, payload: []const u8) !void {
    try self.push(.err, payload);
}

pub fn push(self: *EventStream, tag: structs.EventTag, payload: []const u8) !void {
    if (self.closed) return;
    try self.events.append(self.allocator, .{
        .tag = tag,
        .payload = try self.allocator.dupe(u8, payload),
    });
}

pub fn close(self: *EventStream) void {
    self.closed = true;
}

pub fn next(self: *EventStream) structs.Event {
    if (self.events.items.len > 0) {
        const queued = self.events.orderedRemove(0);
        const owned = self.allocator.dupeZ(u8, queued.payload) catch {
            self.allocator.free(queued.payload);
            return .{ .tag = .err, .payload = ffi.stringDup("{\"error\":\"out of memory\"}") };
        };
        self.allocator.free(queued.payload);
        return .{
            .tag = queued.tag,
            .payload = .{ .ptr = owned.ptr, .len = owned.len },
        };
    }

    if (self.closed and !self.end_emitted) {
        self.end_emitted = true;
        return .{ .tag = .end, .payload = ffi.stringDup("") };
    }

    return .{ .tag = .none, .payload = ffi.stringDup("") };
}

pub fn fromJsonArray(allocator: Allocator, value: std.json.Value) !*EventStream {
    const stream = try create(allocator);
    errdefer stream.destroy();

    if (value == .array) {
        for (value.array.items) |item| {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            try std.json.Stringify.value(item, .{}, &out.writer);
            try stream.pushJson(out.written());
        }
    }
    stream.close();
    return stream;
}

test "stream drains queued events then end" {
    var stream = try EventStream.create(std.testing.allocator);
    defer stream.destroy();
    try stream.pushJson("{\"ok\":true}");
    stream.close();

    const first = stream.next();
    defer ffi.stringFree(first.payload);
    try std.testing.expectEqual(structs.EventTag.json, first.tag);

    const second = stream.next();
    defer ffi.stringFree(second.payload);
    try std.testing.expectEqual(structs.EventTag.end, second.tag);
}
