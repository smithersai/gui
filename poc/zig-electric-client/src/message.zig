//! Electric shape message parsing. Pure code — no I/O, no transport.
//!
//! The Electric shape protocol (v1) delivers messages in JSON arrays. Each
//! element has a `headers` object whose `operation` or `control` field
//! dispatches the rest of the shape:
//!
//!   { "headers": {"operation": "insert"}, "key": "\"public\".\"t\"/1",
//!     "value": { ... row ... } }
//!   { "headers": {"operation": "update"}, "key": "...", "value": { ... } }
//!   { "headers": {"operation": "delete"}, "key": "...", "value": { "id": 1 } }
//!   { "headers": {"control": "up-to-date"} }
//!   { "headers": {"control": "must-refetch"} }
//!
//! Offsets are strings shaped like `"LSN_hi_LSN_lo"` but the client only
//! needs to treat them as opaque tokens that the server echoes back in the
//! `offset` query parameter. See `persistence.zig` for storage.

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

/// A parsed shape message. `key` and `value_json` borrow from the backing
/// JSON slice; the caller must keep the parsed tree alive or dupe them.
pub const Message = struct {
    op: Operation,
    /// Primary key as emitted by Electric, e.g. `"public"."t"/42`.
    /// Empty for control messages.
    key: []const u8,
    /// Raw JSON of the `value` field, for the caller to re-parse or store.
    /// Empty for control messages and for deletes where Electric only sent
    /// the PK.
    value_json: []const u8,
};

/// Parse a single response body (a JSON array) into a list of messages and
/// their headers. Returns the slice into the parsed tree; caller must keep
/// `parsed` alive while reading `.messages[i]`.
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

        // We don't need the structured value — we just need to round-trip
        // its JSON shape to the caller. Re-stringify on demand.
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

/// Serialize a std.json.Value to a newly allocated buffer. The caller owns
/// the returned slice. (std.json.Value does not own a pre-rendered form, so
/// any code that wants canonical JSON output has to re-render.)
fn stringifyLeaked(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(v, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// When a `ParsedBody` is deinit'd, the `value_json` slices from
/// stringifyLeaked are NOT freed (they live in their own allocations). The
/// caller must walk the messages and free each non-empty `value_json`.
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
    try testing.expectEqual(@as(usize, 1), pb.messages.len);
    try testing.expectEqual(Operation.up_to_date, pb.messages[0].op);
}

test "parseBody: insert + update + delete" {
    const body =
        \\[
        \\  {"headers":{"operation":"insert"},"key":"\"public\".\"t\"/1","value":{"id":1,"name":"a"}},
        \\  {"headers":{"operation":"update"},"key":"\"public\".\"t\"/1","value":{"id":1,"name":"b"}},
        \\  {"headers":{"operation":"delete"},"key":"\"public\".\"t\"/1","value":{"id":1}}
        \\]
    ;
    var pb = try parseBody(testing.allocator, body);
    defer pb.deinit(testing.allocator);
    defer freeValueJsons(testing.allocator, pb.messages);
    try testing.expectEqual(@as(usize, 3), pb.messages.len);
    try testing.expectEqual(Operation.insert, pb.messages[0].op);
    try testing.expectEqual(Operation.update, pb.messages[1].op);
    try testing.expectEqual(Operation.delete, pb.messages[2].op);
    // Basic sanity check: value_json round-trips id.
    try testing.expect(std.mem.indexOf(u8, pb.messages[0].value_json, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, pb.messages[1].value_json, "\"b\"") != null);
}

test "parseBody: unknown operation fails" {
    const body =
        \\[{"headers":{"operation":"truncate"}}]
    ;
    const r = parseBody(testing.allocator, body);
    try testing.expectError(Err.UnknownOperation, r);
}

test "parseBody: unknown control fails" {
    const body =
        \\[{"headers":{"control":"mystery"}}]
    ;
    const r = parseBody(testing.allocator, body);
    try testing.expectError(Err.UnknownOperation, r);
}

test "parseBody: malformed JSON" {
    const r = parseBody(testing.allocator, "{not-json}");
    try testing.expectError(Err.JsonMalformed, r);
}

test "parseBody: not an array" {
    const r = parseBody(testing.allocator, "{\"headers\":{\"control\":\"up-to-date\"}}");
    try testing.expectError(Err.JsonMalformed, r);
}

test "parseBody: missing headers field" {
    const r = parseBody(testing.allocator, "[{\"key\":\"x\"}]");
    try testing.expectError(Err.JsonMalformed, r);
}
