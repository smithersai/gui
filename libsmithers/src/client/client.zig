const std = @import("std");
const ffi = @import("../ffi.zig");
const structs = @import("../apprt/structs.zig");
const EventStream = @import("../session/event_stream.zig");
const App = @import("../App.zig");

pub const Client = @This();

allocator: std.mem.Allocator,
app: *App,

pub fn create(app: *App) !*Client {
    const c = try app.allocator.create(Client);
    c.* = .{ .allocator = app.allocator, .app = app };
    return c;
}

pub fn destroy(self: *Client) void {
    self.allocator.destroy(self);
}

pub fn call(self: *Client, method: []const u8, args_json: []const u8, out_err: ?*structs.Error) structs.String {
    if (out_err) |err| err.* = ffi.errorSuccess();
    return self.callImpl(method, args_json) catch |err| {
        if (out_err) |out| out.* = ffi.errorFrom("client call", err);
        return ffi.stringDup("null");
    };
}

pub fn stream(self: *Client, method: []const u8, args_json: []const u8, out_err: ?*structs.Error) ?*EventStream {
    if (out_err) |err| err.* = ffi.errorSuccess();
    return self.streamImpl(method, args_json) catch |err| {
        if (out_err) |out| out.* = ffi.errorFrom("client stream", err);
        return null;
    };
}

fn callImpl(self: *Client, method: []const u8, args_json: []const u8) !structs.String {
    var parsed = try parseArgs(args_json);
    defer parsed.deinit();

    if (try maybeMockResult(self.allocator, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }
    if (ffi.jsonObjectString(parsed.value, "error") != null) return error.ClientRequestedError;

    if (std.mem.eql(u8, method, "echo")) return ffi.stringDup(args_json);
    if (std.mem.eql(u8, method, "resolveCwd")) {
        const requested = ffi.jsonObjectString(parsed.value, "requested");
        const resolved = try @import("../workspace/cwd.zig").resolve(self.allocator, requested);
        defer self.allocator.free(resolved);
        return ffi.stringJson(.{ .path = resolved });
    }

    if (knownEmptyArrayMethod(method)) return ffi.stringDup("[]");
    if (knownOkMethod(method)) return ffi.stringDup("{\"ok\":true}");
    if (std.mem.eql(u8, method, "runWorkflow")) return ffi.stringDup("{\"runId\":\"\",\"status\":\"queued\"}");
    if (std.mem.eql(u8, method, "getCurrentRepo")) return ffi.stringDup("{\"name\":\"\",\"owner\":null}");
    if (std.mem.eql(u8, method, "inspectRun")) return ffi.stringDup("{\"run\":null,\"tasks\":[]}");
    if (std.mem.eql(u8, method, "getWorkflowDAG")) return ffi.stringDup("{\"tasks\":[],\"edges\":[]}");

    if (try cliFallback(self, method, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }

    return ffi.stringJson(.{
        .method = method,
        .args = parsed.value,
        .transport = "unhandled",
    });
}

fn streamImpl(self: *Client, method: []const u8, args_json: []const u8) !*EventStream {
    var parsed = try parseArgs(args_json);
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("events")) |events| {
            return EventStream.fromJsonArray(self.allocator, events);
        }
        if (ffi.jsonObjectString(parsed.value, "sse")) |sse| {
            const event_stream = try EventStream.create(self.allocator);
            errdefer event_stream.destroy();
            try parseSSE(self.allocator, event_stream, sse);
            event_stream.close();
            return event_stream;
        }
    }

    const event_stream = try EventStream.create(self.allocator);
    errdefer event_stream.destroy();
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{
        .method = method,
        .args = parsed.value,
    }, .{}, &out.writer);
    try event_stream.pushJson(out.written());
    event_stream.close();
    return event_stream;
}

fn parseArgs(args_json: []const u8) !std.json.Parsed(std.json.Value) {
    const input = if (std.mem.trim(u8, args_json, &std.ascii.whitespace).len == 0) "{}" else args_json;
    return std.json.parseFromSlice(std.json.Value, ffi.allocator, input, .{});
}

fn maybeMockResult(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    if (value != .object) return null;
    if (value.object.get("mockResult")) |result| return try jsonValueAlloc(allocator, result);
    if (value.object.get("result")) |result| {
        if (ffi.jsonObjectBool(value, "mock") orelse false) return try jsonValueAlloc(allocator, result);
    }
    if (ffi.jsonObjectString(value, "result_json")) |raw| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        return try jsonValueAlloc(allocator, parsed.value);
    }
    return null;
}

fn knownEmptyArrayMethod(method: []const u8) bool {
    const methods = [_][]const u8{
        "listWorkflows",
        "listRuns",
        "listAgents",
        "listMemoryFacts",
        "listAllMemoryFacts",
        "recallMemory",
        "listRecentScores",
        "aggregateScores",
        "listTickets",
        "searchTickets",
        "listPrompts",
        "listSnapshots",
        "listJJHubWorkflows",
        "listChanges",
        "listLandings",
        "listIssues",
        "listWorkspaces",
        "listWorkspaceSnapshots",
    };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
}

fn knownOkMethod(method: []const u8) bool {
    const methods = [_][]const u8{
        "approveNode",
        "denyNode",
        "cancelRun",
        "updatePrompt",
        "deleteTicket",
        "saveWorkflowSource",
        "jumpToFrame",
        "triggerJJHubWorkflow",
    };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
}

fn cliFallback(self: *Client, method: []const u8, args: std.json.Value) !?[]u8 {
    const argv = try cliArgsFor(self.allocator, method, args);
    defer {
        if (argv) |items| {
            for (items) |arg| self.allocator.free(arg);
            self.allocator.free(items);
        }
    }
    const actual = argv orelse return null;

    const result = std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = actual,
        .cwd = self.app.activeWorkspacePath(),
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch return null;
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return null;

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return try self.allocator.dupe(u8, "{}");
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch {
        return try std.fmt.allocPrint(self.allocator, "{{\"text\":{f}}}", .{std.json.fmt(trimmed, .{})});
    };
    defer parsed.deinit();
    return try jsonValueAlloc(self.allocator, parsed.value);
}

fn cliArgsFor(allocator: std.mem.Allocator, method: []const u8, args: std.json.Value) !?[][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }

    if (std.mem.eql(u8, method, "listWorkflows")) {
        try appendArgs(allocator, &list, &.{ "smithers", "workflow", "--format", "json" });
    } else if (std.mem.eql(u8, method, "listRuns")) {
        try appendArgs(allocator, &list, &.{ "smithers", "ps", "--format", "json" });
    } else if (std.mem.eql(u8, method, "inspectRun")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "inspect", run_id, "--format", "json" });
    } else {
        return null;
    }

    return try list.toOwnedSlice(allocator);
}

fn appendArgs(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), args: []const []const u8) !void {
    for (args) |arg| try list.append(allocator, try allocator.dupe(u8, arg));
}

fn parseSSE(allocator: std.mem.Allocator, event_stream: *EventStream, raw: []const u8) !void {
    var event_type: ?[]const u8 = null;
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0) {
            try flushSSE(event_stream, event_type, data.items);
            event_type = null;
            data.clearRetainingCapacity();
            continue;
        }
        if (std.mem.startsWith(u8, line, "event:")) {
            event_type = std.mem.trim(u8, line["event:".len..], " ");
        } else if (std.mem.startsWith(u8, line, "data:")) {
            if (data.items.len > 0) try data.append(allocator, '\n');
            try data.appendSlice(allocator, std.mem.trimLeft(u8, line["data:".len..], " "));
        }
    }
    if (data.items.len > 0 or event_type != null) try flushSSE(event_stream, event_type, data.items);
}

fn flushSSE(event_stream: *EventStream, event_type: ?[]const u8, data: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(event_stream.allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{
        .event = event_type,
        .data = data,
    }, .{}, &out.writer);
    try event_stream.pushJson(out.written());
}

fn jsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "client mock call returns result" {
    var app = try App.create(std.testing.allocator, .{});
    defer app.destroy();
    var c = try Client.create(app);
    defer c.destroy();
    var err: structs.Error = undefined;
    const s = c.call("listRuns", "{\"mockResult\":[{\"runId\":\"r1\"}]}", &err);
    defer ffi.stringFree(s);
    defer ffi.errorFree(err);
    try std.testing.expectEqual(@as(i32, 0), err.code);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(s.ptr.?, 0), "r1") != null);
}

test "client stream parses sse fixture" {
    var app = try App.create(std.testing.allocator, .{});
    defer app.destroy();
    var c = try Client.create(app);
    defer c.destroy();
    var err: structs.Error = undefined;
    const event_stream = c.stream("streamChat", "{\"sse\":\"event: token\\ndata: hello\\n\\n\"}", &err).?;
    defer event_stream.destroy();
    defer ffi.errorFree(err);
    const ev = event_stream.next();
    defer ffi.stringFree(ev.payload);
    try std.testing.expectEqual(structs.EventTag.json, ev.tag);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(ev.payload.ptr.?, 0), "hello") != null);
}
