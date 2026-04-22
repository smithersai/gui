const std = @import("std");
const ffi = @import("../ffi.zig");
const structs = @import("../apprt/structs.zig");
const EventStream = @import("../session/event_stream.zig");
const App = @import("../App.zig");
const devtools = @import("../devtools/DevToolsClient.zig");
const devtools_snapshot = @import("../devtools/Snapshot.zig");
const devtools_stream = @import("../devtools/Stream.zig");
const devtools_chat_output = @import("../devtools/ChatOutput.zig");
const devtools_chat_stream = @import("../devtools/ChatStream.zig");
const models = @import("../models/mod.zig");
const terminal = @import("../terminal/tmux.zig");
const agents = @import("agents.zig");

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
    if (std.mem.eql(u8, method, "listAgents")) {
        const json = try agents.detect(
            self.allocator,
            std.posix.getenv("PATH"),
            std.posix.getenv("HOME"),
            agents.processEnvLookup,
        );
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }
    if (try terminal.call(self.allocator, method, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }
    if (try devtools.call(self.allocator, method, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }
    if (std.mem.eql(u8, method, "getDevToolsSnapshot")) {
        const run_id = ffi.jsonObjectString(parsed.value, "runId") orelse return error.MissingRunId;
        const frame_no = ffi.jsonObjectInteger(parsed.value, "frameNo");
        const db_path = try self.resolveDbPath() orelse return error.SmithersDbNotFound;
        defer self.allocator.free(db_path);
        const json = try devtools_snapshot.loadSnapshotJson(self.allocator, db_path, run_id, frame_no);
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }
    if (std.mem.eql(u8, method, "getChatOutput")) {
        const run_id = ffi.jsonObjectString(parsed.value, "runId") orelse return error.MissingRunId;
        const db_path = try self.resolveDbPath() orelse return error.SmithersDbNotFound;
        defer self.allocator.free(db_path);
        const json = try devtools_chat_output.loadChatOutputJson(self.allocator, db_path, run_id);
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }
    if (try models.call(self.allocator, method, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }
    if (try localFallback(self, method, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }

    if (try cliFallback(self, method, parsed.value)) |json| {
        defer self.allocator.free(json);
        return ffi.stringDup(json);
    }

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

    if (std.mem.eql(u8, method, "streamDevTools")) {
        const run_id = ffi.jsonObjectString(parsed.value, "runId") orelse return error.MissingRunId;
        const from_seq = ffi.jsonObjectInteger(parsed.value, "fromSeq");
        const db_path = try self.resolveDbPath() orelse return error.SmithersDbNotFound;
        defer self.allocator.free(db_path);
        const event_stream = try EventStream.create(self.allocator);
        errdefer event_stream.destroy();
        try devtools_stream.start(self.allocator, event_stream, run_id, db_path, from_seq);
        return event_stream;
    }

    if (std.mem.eql(u8, method, "streamChat")) {
        const run_id = ffi.jsonObjectString(parsed.value, "runId") orelse return error.MissingRunId;
        const db_path = try self.resolveDbPath() orelse return error.SmithersDbNotFound;
        defer self.allocator.free(db_path);
        const event_stream = try EventStream.create(self.allocator);
        errdefer event_stream.destroy();
        try devtools_chat_stream.start(self.allocator, event_stream, run_id, db_path);
        return event_stream;
    }

    // Methods with a dedicated producer must not fall through to the
    // `{"method":..., "args":...}` passthrough below — that payload has no
    // `type` key and surfaces in the GUI as
    // `Malformed event: keyNotFound("type")`, which is exactly what you see
    // when the app is linked against a stale libsmithers.a that predates the
    // dedicated handler. Fail fast so the error is visible at connect time.
    if (std.mem.eql(u8, method, "streamDevTools")) return error.UnsupportedMethod;
    if (std.mem.eql(u8, method, "streamChat")) return error.UnsupportedMethod;

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

fn resolveDbPath(self: *Client) !?[]u8 {
    if (try envDbPath(self.allocator, "SMITHERS_DB_PATH")) |p| return p;
    if (try envDbPath(self.allocator, "SMITHERS_DB")) |p| return p;

    const cwd = try self.app.activeWorkspacePathDup(self.allocator) orelse
        try std.process.getCwdAlloc(self.allocator);
    defer self.allocator.free(cwd);

    const direct = try std.fs.path.join(self.allocator, &.{ cwd, "smithers.db" });
    if (pathExists(direct)) return direct;
    self.allocator.free(direct);

    const nested = try std.fs.path.join(self.allocator, &.{ cwd, ".smithers", "smithers.db" });
    if (pathExists(nested)) return nested;
    self.allocator.free(nested);
    return null;
}

fn envDbPath(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const raw = std.posix.getenv(key) orelse return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (!pathExists(trimmed)) return null;
    return try allocator.dupe(u8, trimmed);
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
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
    }) catch |err| return err;
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return cliStderrToError(result.stderr);

    return try normalizeCliOutput(self.allocator, method, result.stdout);
}

// Map a failing smithers CLI invocation's stderr to a descriptive zig error.
// smithers prints lines like `error: <Code>: <message>` when a request fails.
// Surfacing the code as the error name lets the GUI map it back to a typed
// DevToolsClientError instead of showing a generic `CliInvocationFailed`.
fn cliStderrToError(stderr: []const u8) anyerror {
    const code = extractCliErrorCode(stderr) orelse return error.CliInvocationFailed;
    if (std.mem.eql(u8, code, "AttemptNotFinished")) return error.AttemptNotFinished;
    if (std.mem.eql(u8, code, "AttemptNotFound")) return error.AttemptNotFound;
    if (std.mem.eql(u8, code, "RunNotFound")) return error.RunNotFound;
    if (std.mem.eql(u8, code, "NodeNotFound")) return error.NodeNotFound;
    if (std.mem.eql(u8, code, "NodeHasNoOutput")) return error.NodeHasNoOutput;
    if (std.mem.eql(u8, code, "InvalidRunId")) return error.InvalidRunId;
    if (std.mem.eql(u8, code, "InvalidNodeId")) return error.InvalidNodeId;
    if (std.mem.eql(u8, code, "InvalidIteration")) return error.InvalidIteration;
    if (std.mem.eql(u8, code, "IterationNotFound")) return error.IterationNotFound;
    if (std.mem.eql(u8, code, "PayloadTooLarge")) return error.PayloadTooLarge;
    if (std.mem.eql(u8, code, "DiffTooLarge")) return error.DiffTooLarge;
    if (std.mem.eql(u8, code, "WorkingTreeDirty")) return error.WorkingTreeDirty;
    if (std.mem.eql(u8, code, "VcsError")) return error.VcsError;
    if (std.mem.eql(u8, code, "FrameOutOfRange")) return error.FrameOutOfRange;
    if (std.mem.eql(u8, code, "MalformedOutputRow")) return error.MalformedOutputRow;
    if (std.mem.eql(u8, code, "ConfirmationRequired")) return error.ConfirmationRequired;
    if (std.mem.eql(u8, code, "Busy")) return error.Busy;
    if (std.mem.eql(u8, code, "UnsupportedSandbox")) return error.UnsupportedSandbox;
    if (std.mem.eql(u8, code, "RewindFailed")) return error.RewindFailed;
    if (std.mem.eql(u8, code, "RateLimited")) return error.RateLimited;
    return error.CliInvocationFailed;
}

fn extractCliErrorCode(stderr: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        const prefix = "error: ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
        const code = std.mem.trim(u8, rest[0..colon], &std.ascii.whitespace);
        if (code.len == 0 or code.len > 64) continue;
        if (!isPascalCaseIdentifier(code)) continue;
        return code;
    }
    return null;
}

fn isPascalCaseIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(s[0] >= 'A' and s[0] <= 'Z')) return false;
    for (s) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or
            (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9');
        if (!ok) return false;
    }
    return true;
}

fn normalizeCliOutput(allocator: std.mem.Allocator, method: []const u8, stdout: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (std.mem.eql(u8, method, "getOrchestratorVersion") or stringResultMethod(method)) {
        return jsonStringAlloc(allocator, trimmed);
    }
    if (std.mem.eql(u8, method, "runWorkflow")) {
        return normalizeRunWorkflowOutput(allocator, trimmed);
    }
    if (trimmed.len == 0) return try allocator.dupe(u8, "{}");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return jsonStringAlloc(allocator, trimmed);
    };
    defer parsed.deinit();
    return try jsonValueAlloc(allocator, parsed.value);
}

fn normalizeRunWorkflowOutput(allocator: std.mem.Allocator, trimmed: []const u8) ![]u8 {
    if (trimmed.len == 0) return error.EmptyCliOutput;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return runIdJson(allocator, trimmed);
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .string => |run_id| return runIdJson(allocator, run_id),
        .object => |object| {
            if (object.get("runId") != null or object.get("run_id") != null or object.get("id") != null) {
                return try jsonValueAlloc(allocator, parsed.value);
            }
            if (object.get("data")) |data| {
                if (data == .object and (data.object.get("runId") != null or data.object.get("run_id") != null or data.object.get("id") != null)) {
                    return try jsonValueAlloc(allocator, parsed.value);
                }
            }
            return error.MissingRunId;
        },
        else => return error.MissingRunId,
    }
}

fn runIdJson(allocator: std.mem.Allocator, run_id: []const u8) ![]u8 {
    const clean = std.mem.trim(u8, run_id, &std.ascii.whitespace);
    if (clean.len == 0) return error.EmptyRunId;
    return try std.fmt.allocPrint(allocator, "{{\"runId\":{f},\"status\":\"queued\"}}", .{std.json.fmt(clean, .{})});
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
    } else if (std.mem.eql(u8, method, "runWorkflowDoctor")) {
        const workflow_path = ffi.jsonObjectString(args, "workflowPath") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "workflow", "doctor", workflow_path, "--format", "json" });
    } else if (std.mem.eql(u8, method, "getWorkflowDAG")) {
        const workflow_path = ffi.jsonObjectString(args, "workflowPath") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "graph", workflow_path, "--format", "json" });
        try appendJsonOption(allocator, &list, "--input", jsonObjectValue(args, "input"));
    } else if (std.mem.eql(u8, method, "runWorkflow")) {
        const workflow_path = ffi.jsonObjectString(args, "workflowPath") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "up", workflow_path, "--detach", "true", "--format", "json" });
        try appendJsonOption(allocator, &list, "--input", jsonObjectValue(args, "inputs"));
    } else if (std.mem.eql(u8, method, "createChat")) {
        const agent = ffi.jsonObjectString(args, "agent") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "chat", "create", "--agent", agent, "--format", "json" });
        if (ffi.jsonObjectString(args, "cwd")) |cwd| try appendArgs(allocator, &list, &.{ "--cwd", cwd });
    } else if (std.mem.eql(u8, method, "approveNode")) {
        try appendApprovalArgs(allocator, &list, "approve", args, "note");
    } else if (std.mem.eql(u8, method, "denyNode")) {
        try appendApprovalArgs(allocator, &list, "deny", args, "reason");
    } else if (std.mem.eql(u8, method, "cancelRun")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "cancel", run_id, "--format", "json" });
    } else if (std.mem.eql(u8, method, "getNodeOutput")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        const node_id = ffi.jsonObjectString(args, "nodeId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "output", run_id, node_id, "--json" });
        try appendIntegerOption(allocator, &list, "--iteration", args, "iteration");
    } else if (std.mem.eql(u8, method, "getNodeDiff")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        const node_id = ffi.jsonObjectString(args, "nodeId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "diff", run_id, node_id, "--json" });
        try appendIntegerOption(allocator, &list, "--iteration", args, "iteration");
    } else if (std.mem.eql(u8, method, "getChatOutput")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "chat", run_id, "--format", "json" });
    } else if (std.mem.eql(u8, method, "hijackRun")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "hijack", run_id, "--launch=false", "--format", "json" });
    } else if (std.mem.eql(u8, method, "listRecentScores")) {
        const run_id = ffi.jsonObjectString(args, "runId") orelse return null;
        try appendArgs(allocator, &list, &.{ "smithers", "scores", run_id, "--format", "json" });
        if (ffi.jsonObjectString(args, "nodeId")) |node_id| try appendArgs(allocator, &list, &.{ "--node", node_id });
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
    } else if (std.mem.eql(u8, method, "createIssue")) {
        const title = ffi.jsonObjectString(args, "title") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "issue", "create", "--json", "--title", title });
        if (ffi.jsonObjectString(args, "body")) |body| try appendArgs(allocator, &list, &.{ "--body", body });
    } else if (std.mem.eql(u8, method, "closeIssue")) {
        const number = jsonObjectIntegerString(allocator, args, "number") orelse return null;
        defer allocator.free(number);
        try appendArgs(allocator, &list, &.{ "jjhub", "issue", "close", number, "--json" });
        if (ffi.jsonObjectString(args, "comment")) |comment| try appendArgs(allocator, &list, &.{ "--comment", comment });
    } else if (std.mem.eql(u8, method, "getCurrentRepo")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "repo", "view", "--json" });
    } else if (std.mem.eql(u8, method, "listWorkspaces")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "list", "--json" });
    } else if (std.mem.eql(u8, method, "viewWorkspace")) {
        const workspace_id = ffi.jsonObjectString(args, "workspaceId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "view", workspace_id, "--json" });
    } else if (std.mem.eql(u8, method, "createWorkspace")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "create", "--json" });
        if (ffi.jsonObjectString(args, "name")) |name| try appendArgs(allocator, &list, &.{ "--name", name });
        if (ffi.jsonObjectString(args, "snapshotId")) |snapshot_id| try appendArgs(allocator, &list, &.{ "--snapshot", snapshot_id });
    } else if (std.mem.eql(u8, method, "deleteWorkspace")) {
        const workspace_id = ffi.jsonObjectString(args, "workspaceId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "delete", workspace_id, "--json" });
    } else if (std.mem.eql(u8, method, "suspendWorkspace")) {
        const workspace_id = ffi.jsonObjectString(args, "workspaceId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "suspend", workspace_id, "--json" });
    } else if (std.mem.eql(u8, method, "resumeWorkspace")) {
        const workspace_id = ffi.jsonObjectString(args, "workspaceId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "resume", workspace_id, "--json" });
    } else if (std.mem.eql(u8, method, "forkWorkspace")) {
        const workspace_id = ffi.jsonObjectString(args, "workspaceId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "fork", workspace_id, "--json" });
        if (ffi.jsonObjectString(args, "name")) |name| try appendArgs(allocator, &list, &.{ "--name", name });
    } else if (std.mem.eql(u8, method, "listWorkspaceSnapshots")) {
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "snapshot", "list", "--json" });
    } else if (std.mem.eql(u8, method, "viewWorkspaceSnapshot")) {
        const snapshot_id = ffi.jsonObjectString(args, "snapshotId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "snapshot", "view", snapshot_id, "--json" });
    } else if (std.mem.eql(u8, method, "createWorkspaceSnapshot")) {
        const workspace_id = ffi.jsonObjectString(args, "workspaceId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "snapshot", "create", workspace_id, "--json" });
        if (ffi.jsonObjectString(args, "name")) |name| try appendArgs(allocator, &list, &.{ "--name", name });
    } else if (std.mem.eql(u8, method, "deleteWorkspaceSnapshot")) {
        const snapshot_id = ffi.jsonObjectString(args, "snapshotId") orelse return null;
        try appendArgs(allocator, &list, &.{ "jjhub", "workspace", "snapshot", "delete", snapshot_id, "--json" });
    } else if (std.mem.eql(u8, method, "search")) {
        const scope = ffi.jsonObjectString(args, "scope") orelse return null;
        const query = ffi.jsonObjectString(args, "query") orelse return null;
        if (std.mem.eql(u8, scope, "code")) {
            try appendArgs(allocator, &list, &.{ "jjhub", "search", "code", query, "--json" });
        } else if (std.mem.eql(u8, scope, "issues")) {
            try appendArgs(allocator, &list, &.{ "jjhub", "search", "issues", query, "--json" });
            if (ffi.jsonObjectString(args, "issueState")) |state| try appendArgs(allocator, &list, &.{ "--state", state });
        } else if (std.mem.eql(u8, scope, "repos")) {
            try appendArgs(allocator, &list, &.{ "jjhub", "search", "repos", query, "--json" });
        } else {
            return null;
        }
        try appendIntegerOption(allocator, &list, "--limit", args, "limit");
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

fn appendIntegerOption(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    flag: []const u8,
    args: std.json.Value,
    key: []const u8,
) !void {
    const value = ffi.jsonObjectInteger(args, key) orelse return;
    const text = try std.fmt.allocPrint(allocator, "{}", .{value});
    defer allocator.free(text);
    try appendArgs(allocator, list, &.{ flag, text });
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
    if (std.mem.eql(u8, method, "runQuickLaunchParser")) {
        return try quickLaunchParserResult(self.allocator, args);
    }
    return null;
}

fn quickLaunchParserResult(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const prompt = ffi.jsonObjectString(args, "prompt") orelse "";
    const trimmed = std.mem.trim(u8, prompt, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return try allocator.dupe(u8, "{\"inputs\":{},\"notes\":\"\",\"parseRunId\":\"\"}");
    }
    return try std.fmt.allocPrint(
        allocator,
        "{{\"inputs\":{{\"prompt\":{f}}},\"notes\":\"\",\"parseRunId\":\"\"}}",
        .{std.json.fmt(trimmed, .{})},
    );
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

test "runWorkflow normalizes JSON and plain run id output" {
    const json_object = try normalizeCliOutput(std.testing.allocator, "runWorkflow", "{\"runId\":\"run-json\",\"status\":\"queued\"}\n");
    defer std.testing.allocator.free(json_object);
    try std.testing.expectEqualStrings("{\"runId\":\"run-json\",\"status\":\"queued\"}", json_object);

    const plain = try normalizeCliOutput(std.testing.allocator, "runWorkflow", "run-plain\n");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("{\"runId\":\"run-plain\",\"status\":\"queued\"}", plain);

    try std.testing.expectError(error.MissingRunId, normalizeRunWorkflowOutput(std.testing.allocator, "{\"ok\":true}"));
}

test "cliArgsFor maps workflow doctor output diff and scores methods" {
    try expectCliArgsFor(
        "runWorkflowDoctor",
        "{\"workflowPath\":\"quick-launch\"}",
        &.{ "smithers", "workflow", "doctor", "quick-launch", "--format", "json" },
    );
    try expectCliArgsFor(
        "getNodeOutput",
        "{\"runId\":\"run-1\",\"nodeId\":\"task.build\",\"iteration\":2}",
        &.{ "smithers", "output", "run-1", "task.build", "--json", "--iteration", "2" },
    );
    try expectCliArgsFor(
        "getNodeDiff",
        "{\"runId\":\"run-1\",\"nodeId\":\"task.build\",\"iteration\":2}",
        &.{ "smithers", "diff", "run-1", "task.build", "--json", "--iteration", "2" },
    );
    try expectCliArgsFor(
        "listRecentScores",
        "{\"runId\":\"run-1\",\"nodeId\":\"task.build\"}",
        &.{ "smithers", "scores", "run-1", "--format", "json", "--node", "task.build" },
    );
}

test "cliArgsFor maps JJHub workspace lifecycle and snapshots" {
    try expectCliArgsFor(
        "createWorkspace",
        "{\"name\":\"scratch\",\"snapshotId\":\"snap-1\"}",
        &.{ "jjhub", "workspace", "create", "--json", "--name", "scratch", "--snapshot", "snap-1" },
    );
    try expectCliArgsFor(
        "deleteWorkspace",
        "{\"workspaceId\":\"ws-1\"}",
        &.{ "jjhub", "workspace", "delete", "ws-1", "--json" },
    );
    try expectCliArgsFor(
        "suspendWorkspace",
        "{\"workspaceId\":\"ws-1\"}",
        &.{ "jjhub", "workspace", "suspend", "ws-1", "--json" },
    );
    try expectCliArgsFor(
        "resumeWorkspace",
        "{\"workspaceId\":\"ws-1\"}",
        &.{ "jjhub", "workspace", "resume", "ws-1", "--json" },
    );
    try expectCliArgsFor(
        "forkWorkspace",
        "{\"workspaceId\":\"ws-1\",\"name\":\"scratch-copy\"}",
        &.{ "jjhub", "workspace", "fork", "ws-1", "--json", "--name", "scratch-copy" },
    );
    try expectCliArgsFor(
        "listWorkspaceSnapshots",
        "{}",
        &.{ "jjhub", "workspace", "snapshot", "list", "--json" },
    );
    try expectCliArgsFor(
        "viewWorkspaceSnapshot",
        "{\"snapshotId\":\"snap-1\"}",
        &.{ "jjhub", "workspace", "snapshot", "view", "snap-1", "--json" },
    );
    try expectCliArgsFor(
        "createWorkspaceSnapshot",
        "{\"workspaceId\":\"ws-1\",\"name\":\"before-merge\"}",
        &.{ "jjhub", "workspace", "snapshot", "create", "ws-1", "--json", "--name", "before-merge" },
    );
    try expectCliArgsFor(
        "deleteWorkspaceSnapshot",
        "{\"snapshotId\":\"snap-1\"}",
        &.{ "jjhub", "workspace", "snapshot", "delete", "snap-1", "--json" },
    );
}

test "cliArgsFor maps JJHub issue create close and search methods" {
    try expectCliArgsFor(
        "createIssue",
        "{\"title\":\"Ship it\",\"body\":\"Needs rollout notes\"}",
        &.{ "jjhub", "issue", "create", "--json", "--title", "Ship it", "--body", "Needs rollout notes" },
    );
    try expectCliArgsFor(
        "closeIssue",
        "{\"number\":42,\"comment\":\"Fixed in main\"}",
        &.{ "jjhub", "issue", "close", "42", "--json", "--comment", "Fixed in main" },
    );
    try expectCliArgsFor(
        "search",
        "{\"query\":\"parser\",\"scope\":\"issues\",\"issueState\":\"closed\",\"limit\":50}",
        &.{ "jjhub", "search", "issues", "parser", "--json", "--state", "closed", "--limit", "50" },
    );
    try expectCliArgsFor(
        "search",
        "{\"query\":\"tmux\",\"scope\":\"code\",\"limit\":10}",
        &.{ "jjhub", "search", "code", "tmux", "--json", "--limit", "10" },
    );
}

test "extractCliErrorCode pulls code from smithers stderr" {
    const stderr =
        "timestamp=2026-04-22T16:34:48.296Z level=INFO fiber=#17 message=\"handled\"\n" ++
        "error: AttemptNotFinished: The latest attempt is still running.\n" ++
        "  hint: Wait for the task to finish before asking for a diff.\n";
    const code = extractCliErrorCode(stderr);
    try std.testing.expect(code != null);
    try std.testing.expectEqualStrings("AttemptNotFinished", code.?);
}

test "extractCliErrorCode ignores non-error log lines" {
    const stderr = "timestamp=... level=WARN message=\"error: not-a-code\"\nsome other log\n";
    try std.testing.expect(extractCliErrorCode(stderr) == null);
}

test "extractCliErrorCode rejects lowercase or punctuated identifiers" {
    try std.testing.expect(extractCliErrorCode("error: attemptNotFinished: msg\n") == null);
    try std.testing.expect(extractCliErrorCode("error: : missing code\n") == null);
    try std.testing.expect(extractCliErrorCode("error: Weird-Code: nope\n") == null);
}

test "cliStderrToError maps known codes and falls back otherwise" {
    try std.testing.expect(cliStderrToError("error: AttemptNotFinished: running\n") == error.AttemptNotFinished);
    try std.testing.expect(cliStderrToError("error: RunNotFound: gone\n") == error.RunNotFound);
    try std.testing.expect(cliStderrToError("error: DiffTooLarge: 51MB\n") == error.DiffTooLarge);
    try std.testing.expect(cliStderrToError("error: NodeHasNoOutput: none\n") == error.NodeHasNoOutput);
    try std.testing.expect(cliStderrToError("") == error.CliInvocationFailed);
    try std.testing.expect(cliStderrToError("error: UnheardOfCode: msg\n") == error.CliInvocationFailed);
}

test "unsupported client method reports an error instead of a fake fallback" {
    var app = try App.create(std.testing.allocator, .{});
    defer app.destroy();
    var c = try Client.create(app);
    defer c.destroy();
    var err: structs.Error = undefined;
    const s = c.call("notImplemented", "{}", &err);
    defer ffi.stringFree(s);
    defer ffi.errorFree(err);
    try std.testing.expect(err.code != 0);
}

fn expectCliArgsFor(method: []const u8, args_json: []const u8, expected: []const []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, args_json, .{});
    defer parsed.deinit();

    const argv = try cliArgsFor(std.testing.allocator, method, parsed.value);
    defer freeCliArgs(std.testing.allocator, argv);

    try std.testing.expect(argv != null);
    const actual = argv.?;
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

fn freeCliArgs(allocator: std.mem.Allocator, maybe_args: ?[][]const u8) void {
    const args = maybe_args orelse return;
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

test "listAgents reports unavailable when PATH is empty" {
    const allocator = std.testing.allocator;
    const json = try agents.detect(allocator, "", null, agents.nullEnvLookup);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const list = obj.get("agents").?.array.items;
    try std.testing.expectEqual(@as(usize, agents.known_agents.len), list.len);
    try std.testing.expectEqual(@as(usize, 7), list.len);
    for (list) |entry| {
        try std.testing.expectEqualStrings("unavailable", entry.object.get("status").?.string);
        try std.testing.expectEqual(false, entry.object.get("usable").?.bool);
        try std.testing.expectEqualStrings("", entry.object.get("binaryPath").?.string);
    }
}

test "listAgents detects binary in synthetic PATH" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const claude_path = try std.fs.path.join(allocator, &.{ tmp_path, "claude" });
    defer allocator.free(claude_path);
    {
        var file = try std.fs.createFileAbsolute(claude_path, .{ .truncate = true, .mode = 0o755 });
        defer file.close();
        try file.writeAll("#!/bin/sh\n");
    }

    const json = try agents.detect(allocator, tmp_path, null, agents.nullEnvLookup);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const list = parsed.value.object.get("agents").?.array.items;
    var claude_entry: ?std.json.Value = null;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.object.get("id").?.string, "claude-code")) {
            claude_entry = entry;
            break;
        }
    }
    const claude = claude_entry.?;
    try std.testing.expectEqualStrings("binary-only", claude.object.get("status").?.string);
    try std.testing.expectEqual(true, claude.object.get("usable").?.bool);
    try std.testing.expectEqual(false, claude.object.get("hasAuth").?.bool);
    try std.testing.expectEqual(false, claude.object.get("hasAPIKey").?.bool);
    const bin_path = claude.object.get("binaryPath").?.string;
    try std.testing.expect(std.mem.endsWith(u8, bin_path, "/claude"));
}

const TestEnv = struct {
    const Entry = struct { key: []const u8, value: []const u8 };
    var entries: []const Entry = &.{};

    fn lookup(name: []const u8) ?[]const u8 {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, name)) return entry.value;
        }
        return null;
    }
};

test "listAgents reports api-key when env var is set" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const claude_path = try std.fs.path.join(allocator, &.{ tmp_path, "claude" });
    defer allocator.free(claude_path);
    {
        var file = try std.fs.createFileAbsolute(claude_path, .{ .truncate = true, .mode = 0o755 });
        defer file.close();
        try file.writeAll("#!/bin/sh\n");
    }

    TestEnv.entries = &.{.{ .key = "ANTHROPIC_API_KEY", .value = "sk-test" }};
    defer TestEnv.entries = &.{};

    const json = try agents.detect(allocator, tmp_path, null, TestEnv.lookup);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const list = parsed.value.object.get("agents").?.array.items;
    var claude_entry: ?std.json.Value = null;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.object.get("id").?.string, "claude-code")) {
            claude_entry = entry;
            break;
        }
    }
    const claude = claude_entry.?;
    try std.testing.expectEqualStrings("api-key", claude.object.get("status").?.string);
    try std.testing.expectEqual(true, claude.object.get("hasAPIKey").?.bool);
    try std.testing.expectEqual(false, claude.object.get("hasAuth").?.bool);
    try std.testing.expectEqual(true, claude.object.get("usable").?.bool);
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
