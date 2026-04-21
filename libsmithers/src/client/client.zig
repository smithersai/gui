const std = @import("std");
const ffi = @import("../ffi.zig");
const structs = @import("../apprt/structs.zig");
const EventStream = @import("../session/event_stream.zig");
const App = @import("../App.zig");

pub const Client = @This();

allocator: std.mem.Allocator,
app: *App,
mutex: std.Thread.Mutex = .{},

pub fn create(app: *App) !*Client {
    const c = try app.allocator.create(Client);
    c.* = .{ .allocator = app.allocator, .app = app };
    return c;
}

pub fn destroy(self: *Client) void {
    self.mutex.lock();
    self.mutex.unlock();
    self.allocator.destroy(self);
}

pub fn call(self: *Client, method: []const u8, args_json: []const u8, out_err: ?*structs.Error) structs.String {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (out_err) |err| err.* = ffi.errorSuccess();
    return self.callImpl(method, args_json) catch |err| {
        if (out_err) |out| out.* = ffi.errorFrom("client call", err);
        return ffi.stringDup("null");
    };
}

pub fn stream(self: *Client, method: []const u8, args_json: []const u8, out_err: ?*structs.Error) ?*EventStream {
    self.mutex.lock();
    defer self.mutex.unlock();
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
    if (try localFallback(self, method, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }

    if (try cliFallback(self, method, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }

    if (staticFallback(method)) |json| return ffi.stringDup(json);
    return error.UnsupportedMethod;
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

fn staticFallback(method: []const u8) ?[]const u8 {
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
        "listSQLTables",
        "listCrons",
        "listPendingApprovals",
        "listRecentDecisions",
        "search",
    };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return "[]";

    const ok_methods = [_][]const u8{
        "approveNode",
        "denyNode",
        "cancelRun",
        "updatePrompt",
        "deleteTicket",
        "saveWorkflowSource",
        "triggerJJHubWorkflow",
        "deleteBookmark",
        "landLanding",
        "reviewLanding",
        "toggleCron",
        "deleteCron",
        "deleteWorkspace",
        "suspendWorkspace",
        "resumeWorkspace",
        "deleteWorkspaceSnapshot",
    };
    for (ok_methods) |candidate| if (std.mem.eql(u8, method, candidate)) return "{\"ok\":true}";

    if (std.mem.eql(u8, method, "runWorkflow")) return "{\"runId\":\"\",\"status\":\"queued\"}";
    if (std.mem.eql(u8, method, "getCurrentRepo")) return "{\"name\":\"\",\"owner\":null}";
    if (std.mem.eql(u8, method, "inspectRun")) {
        return "{\"run\":{\"runId\":\"\",\"workflowName\":null,\"workflowPath\":null,\"status\":\"unknown\",\"startedAtMs\":null,\"finishedAtMs\":null,\"summary\":null,\"errorJson\":null},\"tasks\":[]}";
    }
    if (std.mem.eql(u8, method, "getWorkflowDAG")) {
        return "{\"workflowID\":null,\"mode\":null,\"runId\":null,\"frameNo\":null,\"xml\":null,\"tasks\":[],\"graphEdges\":null,\"entryTask\":null,\"entryTaskID\":null,\"fields\":null,\"message\":null}";
    }
    if (std.mem.eql(u8, method, "getDevToolsSnapshot")) {
        return "{\"runId\":\"\",\"frameNo\":0,\"seq\":0,\"root\":{\"id\":0,\"type\":\"workflow\",\"name\":\"Workflow\",\"props\":{},\"task\":null,\"children\":[],\"depth\":0}}";
    }
    if (std.mem.eql(u8, method, "jumpToFrame")) {
        return "{\"ok\":true,\"newFrameNo\":0,\"revertedSandboxes\":0,\"deletedFrames\":0,\"deletedAttempts\":0,\"invalidatedDiffs\":0,\"durationMs\":0}";
    }
    if (std.mem.eql(u8, method, "getNodeOutput")) return "{\"status\":\"pending\",\"row\":null,\"schema\":null,\"partial\":null}";
    if (std.mem.eql(u8, method, "getNodeDiff")) return "{\"seq\":0,\"baseRef\":\"\",\"patches\":[]}";
    if (std.mem.eql(u8, method, "hijackRun")) {
        return "{\"runId\":\"\",\"agentEngine\":\"smithers\",\"agentBinary\":\"smithers\",\"resumeToken\":\"\",\"cwd\":\"\",\"supportsResume\":false,\"launchCommand\":null,\"launchArgs\":[],\"mode\":null,\"resumeCommand\":null}";
    }
    if (std.mem.eql(u8, method, "getOrchestratorVersion")) return "\"0.0.0\"";
    if (std.mem.eql(u8, method, "status") or
        std.mem.eql(u8, method, "changeDiff") or
        std.mem.eql(u8, method, "workingCopyDiff") or
        std.mem.eql(u8, method, "landingDiff") or
        std.mem.eql(u8, method, "landingChecks") or
        std.mem.eql(u8, method, "previewPrompt") or
        std.mem.eql(u8, method, "readWorkflowSource") or
        std.mem.eql(u8, method, "rerunRun"))
    {
        return "\"\"";
    }
    return null;
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

    const cwd = try self.app.activeWorkspacePathDup(self.allocator);
    defer if (cwd) |path| self.allocator.free(path);

    const result = std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = actual,
        .cwd = cwd,
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch return null;
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return null;

    return try normalizeCliOutput(self.allocator, method, result.stdout);
}

fn normalizeCliOutput(allocator: std.mem.Allocator, method: []const u8, stdout: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (std.mem.eql(u8, method, "getOrchestratorVersion") or stringResultMethod(method)) {
        return jsonStringAlloc(allocator, trimmed);
    }
    if (std.mem.eql(u8, method, "runWorkflow")) {
        if (trimmed.len == 0) return try allocator.dupe(u8, "{\"runId\":\"\",\"status\":\"queued\"}");
        if (std.mem.startsWith(u8, trimmed, "run-") or std.mem.indexOfScalar(u8, trimmed, '\n') == null) {
            return try std.fmt.allocPrint(allocator, "{{\"runId\":{f},\"status\":\"queued\"}}", .{std.json.fmt(trimmed, .{})});
        }
    }
    if (trimmed.len == 0) return try allocator.dupe(u8, "{}");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return jsonStringAlloc(allocator, trimmed);
    };
    defer parsed.deinit();
    return try jsonValueAlloc(allocator, parsed.value);
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
    } else if (std.mem.eql(u8, method, "getOrchestratorVersion")) {
        try appendArgs(allocator, &list, &.{ "smithers", "--version" });
    } else if (std.mem.eql(u8, method, "inspectRun")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "inspect", run_id, "--format", "json" });
    } else if (std.mem.eql(u8, method, "getWorkflowDAG")) {
        const workflow_path = ffi.jsonObjectString(args, "workflowPath") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "graph", workflow_path, "--format", "json" });
        try appendJsonOption(allocator, &list, "--input", jsonObjectValue(args, "input"));
    } else if (std.mem.eql(u8, method, "runWorkflow")) {
        const workflow_path = ffi.jsonObjectString(args, "workflowPath") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "up", workflow_path, "--detach", "true", "--format", "json" });
        try appendJsonOption(allocator, &list, "--input", jsonObjectValue(args, "inputs"));
    } else if (std.mem.eql(u8, method, "approveNode")) {
        try appendApprovalArgs(allocator, &list, "approve", args, "note");
    } else if (std.mem.eql(u8, method, "denyNode")) {
        try appendApprovalArgs(allocator, &list, "deny", args, "reason");
    } else if (std.mem.eql(u8, method, "cancelRun")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "cancel", run_id, "--format", "json" });
    } else if (std.mem.eql(u8, method, "getChatOutput")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "chat", run_id, "--format", "json" });
    } else if (std.mem.eql(u8, method, "hijackRun")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "hijack", run_id, "--launch=false", "--format", "json" });
    } else if (std.mem.eql(u8, method, "listJJHubWorkflows")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "workflow", "list", "--json" });
    } else if (std.mem.eql(u8, method, "triggerJJHubWorkflow")) {
        const workflow_id = jsonObjectIntegerString(allocator, args, "workflowID") orelse return null;
        defer allocator.free(workflow_id);
        const ref = ffi.jsonObjectString(args, "ref") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workflow", "run", workflow_id, "--ref", ref, "--json" });
    } else if (std.mem.eql(u8, method, "listChanges")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "change", "list", "--json" });
    } else if (std.mem.eql(u8, method, "viewChange")) {
        const change_id = ffi.jsonObjectString(args, "changeID") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "change", "show", change_id, "--json" });
    } else if (std.mem.eql(u8, method, "changeDiff")) {
        if (ffi.jsonObjectString(args, "changeID")) |change_id|
            try appendArgs(allocator, &list, &.{ "jjhub", "change", "diff", change_id })
        else
            try appendArgs(allocator, &list, &.{ "jjhub", "change", "diff" });
    } else if (std.mem.eql(u8, method, "status")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "status" });
    } else if (std.mem.eql(u8, method, "listIssues")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "issue", "list", "--json" });
    } else if (std.mem.eql(u8, method, "getIssue")) {
        const number = jsonObjectIntegerString(allocator, args, "number") orelse return null;
        defer allocator.free(number);
        try appendArgs(allocator, &list, &.{ "jjhub", "issue", "view", number, "--json" });
    } else if (std.mem.eql(u8, method, "getCurrentRepo")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "repo", "view", "--json" });
    } else if (std.mem.eql(u8, method, "listWorkspaces")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "list", "--json" });
    } else if (std.mem.eql(u8, method, "viewWorkspace")) {
        const workspace_id = ffi.jsonObjectString(args, "workspaceId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "view", workspace_id, "--json" });
    } else {
        return null;
    }

    return try list.toOwnedSlice(allocator);
}

fn appendArgs(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), args: []const []const u8) !void {
    for (args) |arg| try appendArg(allocator, list, arg);
}

fn appendArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), arg: []const u8) !void {
    try list.append(allocator, try allocator.dupe(u8, arg));
}

fn appendJsonOption(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), flag: []const u8, maybe_value: ?std.json.Value) !void {
    const value = maybe_value orelse return;
    if (value == .null) return;
    const json = try jsonValueAlloc(allocator, value);
    defer allocator.free(json);
    try appendArgs(allocator, list, &.{ flag, json });
}

fn appendApprovalArgs(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    command: []const u8,
    args: std.json.Value,
    note_key: []const u8,
) !void {
    const run_id = ffi.jsonObjectString(args, "runId") orelse return error.MissingRunId;
    const node_id = ffi.jsonObjectString(args, "nodeId") orelse return error.MissingNodeId;
    try appendArgs(allocator, list, &.{ "smithers", command, run_id, "--node", node_id, "--format", "json" });
    if (ffi.jsonObjectInteger(args, "iteration")) |iteration| {
        const text = try std.fmt.allocPrint(allocator, "{}", .{iteration});
        defer allocator.free(text);
        try appendArgs(allocator, list, &.{ "--iteration", text });
    }
    if (ffi.jsonObjectString(args, note_key)) |note| try appendArgs(allocator, list, &.{ "--note", note });
}

fn jsonObjectValue(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn jsonObjectIntegerString(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ?[]u8 {
    const integer = ffi.jsonObjectInteger(value, key) orelse return null;
    return std.fmt.allocPrint(allocator, "{}", .{integer}) catch null;
}

fn stringResultMethod(method: []const u8) bool {
    const methods = [_][]const u8{
        "status",
        "changeDiff",
        "workingCopyDiff",
        "landingDiff",
        "landingChecks",
        "previewPrompt",
        "readWorkflowSource",
        "rerunRun",
    };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
}

fn localFallback(self: *Client, method: []const u8, args: std.json.Value) !?[]u8 {
    if (std.mem.eql(u8, method, "hasSmithersProject")) {
        const root = try self.workspaceRoot(args);
        defer self.allocator.free(root);
        const path = try std.fs.path.join(self.allocator, &.{ root, ".smithers" });
        defer self.allocator.free(path);
        return try self.allocator.dupe(u8, if (isDirectory(path)) "true" else "false");
    }
    if (std.mem.eql(u8, method, "localSmithersFilePath")) {
        const relative = ffi.jsonObjectString(args, "relativePath") orelse return null;
        const path = try self.localSmithersPath(relative);
        defer self.allocator.free(path);
        return try jsonStringAlloc(self.allocator, path);
    }
    if (std.mem.eql(u8, method, "localTicketFilePath")) {
        const ticket_id = ffi.jsonObjectString(args, "ticketId") orelse return null;
        const path = try self.localSmithersPathJoin(&.{ "tickets", ticket_id });
        defer self.allocator.free(path);
        return try jsonStringAlloc(self.allocator, path);
    }
    if (std.mem.eql(u8, method, "readWorkflowSource")) {
        const relative = ffi.jsonObjectString(args, "relativePath") orelse return null;
        const path = try self.workspacePath(relative);
        defer self.allocator.free(path);
        const bytes = try readFileAlloc(self.allocator, path, 2 * 1024 * 1024);
        defer self.allocator.free(bytes);
        return try jsonStringAlloc(self.allocator, bytes);
    }
    if (std.mem.eql(u8, method, "saveWorkflowSource")) {
        const relative = ffi.jsonObjectString(args, "relativePath") orelse return null;
        const source = ffi.jsonObjectString(args, "source") orelse return error.MissingSource;
        const path = try self.workspacePath(relative);
        defer self.allocator.free(path);
        try writeFile(path, source);
        return try self.allocator.dupe(u8, "{\"ok\":true}");
    }
    if (std.mem.eql(u8, method, "parseWorkflowImports")) {
        const source = ffi.jsonObjectString(args, "source") orelse return null;
        return try parseWorkflowImportsAlloc(self.allocator, source);
    }
    return null;
}

fn workspaceRoot(self: *Client, args: std.json.Value) ![]u8 {
    if (ffi.jsonObjectString(args, "cwd")) |raw| {
        if (raw.len > 0) return try self.allocator.dupe(u8, raw);
    }
    if (try self.app.activeWorkspacePathDup(self.allocator)) |path| return path;
    return std.process.getCwdAlloc(self.allocator);
}

fn workspacePath(self: *Client, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try self.allocator.dupe(u8, path);
    const root = try self.workspaceRoot(.null);
    defer self.allocator.free(root);
    return std.fs.path.join(self.allocator, &.{ root, path });
}

fn localSmithersPath(self: *Client, relative: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(relative)) return try self.allocator.dupe(u8, relative);
    if (std.mem.eql(u8, relative, ".smithers") or std.mem.startsWith(u8, relative, ".smithers/")) {
        return self.workspacePath(relative);
    }
    return self.localSmithersPathJoin(&.{relative});
}

fn localSmithersPathJoin(self: *Client, segments: []const []const u8) ![]u8 {
    const root = try self.workspaceRoot(.null);
    defer self.allocator.free(root);

    var parts = try self.allocator.alloc([]const u8, segments.len + 2);
    defer self.allocator.free(parts);
    parts[0] = root;
    parts[1] = ".smithers";
    for (segments, 0..) |segment, i| parts[i + 2] = segment;
    return std.fs.path.join(self.allocator, parts);
}

fn isDirectory(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    defer dir.close();
    const stat = dir.stat() catch return false;
    return stat.kind == .directory;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn jsonStringAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(text, .{})});
}

const ImportKind = enum { component, prompt };

const ImportRef = struct {
    name: []u8,
    path: []u8,
};

fn parseWorkflowImportsAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var components = std.ArrayList(ImportRef).empty;
    defer freeImportList(allocator, &components);
    var prompts = std.ArrayList(ImportRef).empty;
    defer freeImportList(allocator, &prompts);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        try collectWorkflowImportsFromLine(allocator, &components, &prompts, line);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{
        .components = components.items,
        .prompts = prompts.items,
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn freeImportList(allocator: std.mem.Allocator, list: *std.ArrayList(ImportRef)) void {
    for (list.items) |item| {
        allocator.free(item.name);
        allocator.free(item.path);
    }
    list.deinit(allocator);
}

fn collectWorkflowImportsFromLine(
    allocator: std.mem.Allocator,
    components: *std.ArrayList(ImportRef),
    prompts: *std.ArrayList(ImportRef),
    line: []const u8,
) !void {
    if (line.len == 0 or std.mem.startsWith(u8, line, "//")) return;
    const path = extractImportPath(line) orelse return;
    const clean_path = cleanImportPath(path);
    const kind = classifyImportPath(clean_path) orelse return;

    switch (kind) {
        .component => {
            const appended_named = try appendNamedImportRefs(allocator, components, line, clean_path);
            if (!appended_named) {
                const name = extractDefaultImportName(line) orelse importNameFromPath(clean_path);
                try appendImportRef(allocator, components, name, clean_path);
            }
        },
        .prompt => {
            const name = extractDefaultImportName(line) orelse importNameFromPath(clean_path);
            try appendImportRef(allocator, prompts, name, clean_path);
        },
    }
}

fn extractImportPath(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "import(")) |idx| {
        return extractQuotedPath(line[idx + "import(".len ..]);
    }
    if (std.mem.indexOf(u8, line, " from ")) |idx| {
        return extractQuotedPath(line[idx + " from ".len ..]);
    }
    if (std.mem.startsWith(u8, line, "from ")) {
        return extractQuotedPath(line["from ".len..]);
    }
    return null;
}

fn extractQuotedPath(raw: []const u8) ?[]const u8 {
    const text = std.mem.trimLeft(u8, raw, &std.ascii.whitespace);
    if (text.len < 2) return null;
    const quote = text[0];
    if (quote != '"' and quote != '\'' and quote != '`') return null;
    const rest = text[1..];
    const end = std.mem.indexOfScalar(u8, rest, quote) orelse return null;
    return rest[0..end];
}

fn classifyImportPath(path: []const u8) ?ImportKind {
    if (containsIgnoreCase(path, "prompt") or
        endsWithIgnoreCase(path, ".md") or
        endsWithIgnoreCase(path, ".mdx"))
    {
        return .prompt;
    }
    if (containsIgnoreCase(path, "component") or
        endsWithIgnoreCase(path, ".tsx") or
        endsWithIgnoreCase(path, ".jsx"))
    {
        return .component;
    }
    return null;
}

fn appendNamedImportRefs(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(ImportRef),
    line: []const u8,
    path: []const u8,
) !bool {
    const from_idx = std.mem.indexOf(u8, line, " from ") orelse line.len;
    const prefix = line[0..from_idx];
    const open = std.mem.indexOfScalar(u8, prefix, '{') orelse return false;
    const close_rel = std.mem.indexOfScalar(u8, prefix[open + 1 ..], '}') orelse return false;
    const names = prefix[open + 1 .. open + 1 + close_rel];

    var appended = false;
    var parts = std.mem.splitScalar(u8, names, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, &std.ascii.whitespace);
        if (part.len == 0) continue;
        const name_source = if (std.mem.indexOf(u8, part, " as ")) |as_idx|
            part[as_idx + " as ".len ..]
        else
            part;
        const name = firstIdentifier(name_source) orelse continue;
        try appendImportRef(allocator, list, name, path);
        appended = true;
    }
    return appended;
}

fn extractDefaultImportName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "import ")) return null;
    const from_idx = std.mem.indexOf(u8, line, " from ") orelse return null;
    var rest = std.mem.trim(u8, line["import ".len..from_idx], &std.ascii.whitespace);
    if (std.mem.startsWith(u8, rest, "type ")) rest = std.mem.trim(u8, rest["type ".len..], &std.ascii.whitespace);
    if (rest.len == 0 or rest[0] == '{' or rest[0] == '*') return null;
    const before_comma = if (std.mem.indexOfScalar(u8, rest, ',')) |idx| rest[0..idx] else rest;
    return firstIdentifier(before_comma);
}

fn appendImportRef(allocator: std.mem.Allocator, list: *std.ArrayList(ImportRef), raw_name: []const u8, raw_path: []const u8) !void {
    const name = if (raw_name.len > 0) raw_name else "import";
    const path = cleanImportPath(raw_path);
    for (list.items) |item| {
        if (std.mem.eql(u8, item.name, name) and std.mem.eql(u8, item.path, path)) return;
    }
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path),
    });
}

fn cleanImportPath(path: []const u8) []const u8 {
    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, path, '#')) |idx| end = @min(end, idx);
    return path[0..end];
}

fn importNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len == 0) return "import";
    if (lastIndexOfScalar(base, '.')) |idx| {
        if (idx > 0) return base[0..idx];
    }
    return base;
}

fn firstIdentifier(raw: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, raw, &std.ascii.whitespace);
    var start: usize = 0;
    while (start < text.len and !isJsIdentChar(text[start])) : (start += 1) {}
    if (start == text.len) return null;
    var end = start;
    while (end < text.len and isJsIdentChar(text[end])) : (end += 1) {}
    return text[start..end];
}

fn isJsIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or
        c == '$';
}

fn lastIndexOfScalar(haystack: []const u8, needle: u8) ?usize {
    var i = haystack.len;
    while (i > 0) {
        i -= 1;
        if (haystack[i] == needle) return i;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    return eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
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
