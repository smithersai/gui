const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const version = "0.1.0";

pub const foreground_changed_method = "foreground_changed";
pub const session_exited_method = "session_exited";

pub const ErrorCode = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
    pub const session_error = -32000;
};

pub const Request = struct {
    allocator: Allocator,
    parsed: std.json.Parsed(Value),
    id_json: []u8,
    method: []u8,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.id_json);
        self.allocator.free(self.method);
        self.parsed.deinit();
    }

    pub fn params(self: *const Request) ?Value {
        if (self.parsed.value != .object) return null;
        return self.parsed.value.object.get("params");
    }
};

pub const ForegroundChangedParams = struct {
    session_id: []const u8,
    pid: std.posix.pid_t,
    comm: []const u8,
    argv: []const []const u8,
};

pub const SessionExitedParams = struct {
    session_id: []const u8,
    pid: std.posix.pid_t,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
};

pub fn parseRequest(allocator: Allocator, line: []const u8) !Request {
    var parsed = try std.json.parseFromSlice(Value, allocator, line, .{});
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const method_value = parsed.value.object.get("method") orelse return error.InvalidRequest;
    if (method_value != .string) return error.InvalidRequest;

    const id_value = parsed.value.object.get("id") orelse Value.null;
    const id_json = try jsonValueAlloc(allocator, id_value);
    errdefer allocator.free(id_json);

    const method = try allocator.dupe(u8, method_value.string);
    errdefer allocator.free(method);

    return .{
        .allocator = allocator,
        .parsed = parsed,
        .id_json = id_json,
        .method = method,
    };
}

pub fn result(allocator: Allocator, id_json: []const u8, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_json});
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn resultRaw(allocator: Allocator, id_json: []const u8, raw_json: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id_json, raw_json });
    return out.toOwnedSlice();
}

pub fn notification(allocator: Allocator, method: []const u8, params: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":", .{});
    try std.json.Stringify.value(method, .{}, &out.writer);
    try out.writer.writeAll(",\"params\":");
    try std.json.Stringify.value(params, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn @"error"(allocator: Allocator, id_json: []const u8, code: i32, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{},\"message\":",
        .{ id_json, code },
    );
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll("}}\n");
    return out.toOwnedSlice();
}

pub fn jsonValueAlloc(allocator: Allocator, value: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "parse JSON-RPC request" {
    var req = try parseRequest(std.testing.allocator, "{\"id\":7,\"method\":\"daemon.ping\",\"params\":{}}\n");
    defer req.deinit();

    try std.testing.expectEqualStrings("7", req.id_json);
    try std.testing.expectEqualStrings("daemon.ping", req.method);
    try std.testing.expect(req.params() != null);
}

test "format JSON-RPC error" {
    const json = try @"error"(std.testing.allocator, "null", ErrorCode.method_not_found, "missing");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":-32601") != null);
}

test "format JSON-RPC notification" {
    const json = try notification(std.testing.allocator, foreground_changed_method, ForegroundChangedParams{
        .session_id = "sess-1",
        .pid = 42,
        .comm = "git",
        .argv = &.{ "git", "status" },
    });
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"foreground_changed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"sess-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"argv\":[\"git\",\"status\"]") != null);
}
