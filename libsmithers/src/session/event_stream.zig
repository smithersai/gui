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
mutex: std.Thread.Mutex = .{},
ref_count: usize = 1,
events: std.ArrayList(QueuedEvent) = .empty,
closed: bool = false,
end_emitted: bool = false,

pub fn create(allocator: Allocator) !*EventStream {
    const stream = try allocator.create(EventStream);
    stream.* = .{ .allocator = allocator };
    return stream;
}

pub fn destroy(self: *EventStream) void {
    self.release();
}

pub fn retain(self: *EventStream) *EventStream {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(self.ref_count > 0);
    self.ref_count += 1;
    return self;
}

pub fn release(self: *EventStream) void {
    var should_destroy = false;
    self.mutex.lock();
    std.debug.assert(self.ref_count > 0);
    self.ref_count -= 1;
    if (self.ref_count == 0) should_destroy = true;
    self.mutex.unlock();

    if (!should_destroy) return;
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
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.closed) return;
    try self.events.append(self.allocator, .{
        .tag = tag,
        .payload = try self.allocator.dupe(u8, payload),
    });
}

pub fn close(self: *EventStream) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.closed = true;
}

pub fn next(self: *EventStream) structs.Event {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.events.items.len > 0) {
        const queued = self.events.orderedRemove(0);
        const payload = ffi.stringDup(queued.payload);
        self.allocator.free(queued.payload);
        return .{
            .tag = queued.tag,
            .payload = payload,
        };
    }

    if (self.closed and !self.end_emitted) {
        self.end_emitted = true;
        return .{ .tag = .end, .payload = ffi.emptyString() };
    }

    return .{ .tag = .none, .payload = ffi.emptyString() };
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
