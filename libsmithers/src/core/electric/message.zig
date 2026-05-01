//! Electric shape message parsing. Pure code — no I/O, no transport.
//! Promoted verbatim from poc/zig-electric-client/src/message.zig.
//!
//! Shape messages arrive as JSON arrays. Each element has a `headers`
//! object whose `operation` or `control` field dispatches:
//!
//!   { "headers": {"operation": "insert"}, "key": "\"public\".\"t\"/1",
//!     "value": { ... row ... } }
//!   { "headers": {"control": "up-to-date"} }
//!   { "headers": {"control": "must-refetch"} }

const std = @import("std");
const Err = @import("errors.zig").Error;

pub const Operation = enum {
    insert,
    update,
    delete,
    up_to_date,
    must_refetch,
    snapshot_end,
};

pub const Message = struct {
    op: Operation,
    key: []const u8,
    value_json: []const u8,
};

pub const ParsedBody = struct {
    parsed: std.json.Parsed(std.json.Value),
    messages: []Message,

    pub fn deinit(self: *ParsedBody, allocator: std.mem.Allocator) void {
        allocator.free(self.messages);
        self.parsed.deinit();
    }
};

pub fn parseBody(allocator: std.mem.Allocator, body: []const u8) Err!ParsedBody {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |e| switch (e) {
        error.OutOfMemory => return Err.OutOfMemory,
        else => return Err.JsonMalformed,
    };
    errdefer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return Err.JsonMalformed;
    const arr = root.array;

    var msgs = try allocator.alloc(Message, arr.items.len);
    errdefer allocator.free(msgs);

    var i: usize = 0;
    for (arr.items) |elem| {
        if (elem != .object) return Err.JsonMalformed;
        const obj = elem.object;
        const headers_v = obj.get("headers") orelse return Err.JsonMalformed;
        if (headers_v != .object) return Err.JsonMalformed;
        const headers = headers_v.object;

        var op: Operation = undefined;
        if (headers.get("operation")) |op_v| {
            if (op_v != .string) return Err.JsonMalformed;
            const s = op_v.string;
            if (std.mem.eql(u8, s, "insert")) {
                op = .insert;
            } else if (std.mem.eql(u8, s, "update")) {
                op = .update;
            } else if (std.mem.eql(u8, s, "delete")) {
                op = .delete;
            } else {
                return Err.UnknownOperation;
            }
        } else if (headers.get("control")) |ctrl_v| {
            if (ctrl_v != .string) return Err.JsonMalformed;
            const s = ctrl_v.string;
            if (std.mem.eql(u8, s, "up-to-date")) {
                op = .up_to_date;
            } else if (std.mem.eql(u8, s, "must-refetch")) {
                op = .must_refetch;
            } else if (std.mem.eql(u8, s, "snapshot-end")) {
                op = .snapshot_end;
            } else {
                return Err.UnknownOperation;
            }
        } else {
            return Err.JsonMalformed;
        }

        const key: []const u8 = if (obj.get("key")) |k| blk: {
            if (k == .null) break :blk "";
            if (k != .string) return Err.JsonMalformed;
            break :blk k.string;
        } else "";

        var value_json: []const u8 = "";
        if (obj.get("value")) |v| {
            if (v != .null) {
                value_json = stringifyLeaked(allocator, v) catch |e| switch (e) {
                    error.OutOfMemory => return Err.OutOfMemory,
                    else => return Err.JsonMalformed,
                };
            }
        }

        msgs[i] = .{ .op = op, .key = key, .value_json = value_json };
        i += 1;
    }

    return .{ .parsed = parsed, .messages = msgs };
}

fn stringifyLeaked(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(v, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn freeValueJsons(allocator: std.mem.Allocator, msgs: []Message) void {
    for (msgs) |m| {
        if (m.value_json.len != 0) allocator.free(m.value_json);
    }
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "parseBody: empty array" {
    var pb = try parseBody(testing.allocator, "[]");
    defer pb.deinit(testing.allocator);
    defer freeValueJsons(testing.allocator, pb.messages);
    try testing.expectEqual(@as(usize, 0), pb.messages.len);
}

test "parseBody: up-to-date control" {
    const body =
        \\[{"headers":{"control":"up-to-date"}}]
    ;
    var pb = try parseBody(testing.allocator, body);
    defer pb.deinit(testing.allocator);
    defer freeValueJsons(testing.allocator, pb.messages);
    try testing.expectEqual(Operation.up_to_date, pb.messages[0].op);
}

test "parseBody: insert with value round-trips id" {
    const body =
        \\[{"headers":{"operation":"insert"},"key":"\"public\".\"t\"/1","value":{"id":1,"name":"a"}}]
    ;
    var pb = try parseBody(testing.allocator, body);
    defer pb.deinit(testing.allocator);
    defer freeValueJsons(testing.allocator, pb.messages);
    try testing.expectEqual(Operation.insert, pb.messages[0].op);
    try testing.expect(std.mem.indexOf(u8, pb.messages[0].value_json, "\"name\"") != null);
}

test "parseBody: unknown operation fails" {
    const r = parseBody(testing.allocator,
        \\[{"headers":{"operation":"truncate"}}]
    );
    try testing.expectError(Err.UnknownOperation, r);
}

test "parseBody: malformed JSON" {
    const r = parseBody(testing.allocator, "{not-json}");
    try testing.expectError(Err.JsonMalformed, r);
}
