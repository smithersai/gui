const std = @import("std");

const Value = std.json.Value;

pub const Workflow = struct {
    id: []u8,
    name: []u8,
    relative_path: ?[]u8 = null,
    status: []u8 = &.{},
    updated_at: ?[]u8 = null,

    pub fn deinit(self: *Workflow, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        if (self.relative_path) |v| alloc.free(v);
        if (self.status.len > 0) alloc.free(self.status);
        if (self.updated_at) |v| alloc.free(v);
    }
};

pub const RunSummary = struct {
    run_id: []u8,
    workflow_name: ?[]u8 = null,
    workflow_path: ?[]u8 = null,
    status: []u8,
    started_at_ms: ?i64 = null,
    finished_at_ms: ?i64 = null,
    total: i64 = 0,
    finished: i64 = 0,
    failed: i64 = 0,
    error_json: ?[]u8 = null,

    pub fn deinit(self: *RunSummary, alloc: std.mem.Allocator) void {
        alloc.free(self.run_id);
        if (self.workflow_name) |v| alloc.free(v);
        if (self.workflow_path) |v| alloc.free(v);
        alloc.free(self.status);
        if (self.error_json) |v| alloc.free(v);
    }
};

pub const RunTask = struct {
    node_id: []u8,
    label: ?[]u8 = null,
    state: []u8,
    iteration: ?i64 = null,

    pub fn deinit(self: *RunTask, alloc: std.mem.Allocator) void {
        alloc.free(self.node_id);
        if (self.label) |v| alloc.free(v);
        alloc.free(self.state);
    }
};

pub const RunInspection = struct {
    run: RunSummary,
    tasks: std.ArrayList(RunTask) = .empty,

    pub fn deinit(self: *RunInspection, alloc: std.mem.Allocator) void {
        self.run.deinit(alloc);
        for (self.tasks.items) |*task| task.deinit(alloc);
        self.tasks.deinit(alloc);
    }
};

pub const Approval = struct {
    id: []u8,
    run_id: []u8,
    node_id: []u8,
    gate: ?[]u8 = null,
    status: []u8,
    requested_at: ?i64 = null,
    source: ?[]u8 = null,

    pub fn deinit(self: *Approval, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.run_id);
        alloc.free(self.node_id);
        if (self.gate) |v| alloc.free(v);
        alloc.free(self.status);
        if (self.source) |v| alloc.free(v);
    }
};

pub const Agent = struct {
    id: []u8,
    name: []u8,
    status: []u8,
    usable: bool = false,
    version: ?[]u8 = null,

    pub fn deinit(self: *Agent, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.status);
        if (self.version) |v| alloc.free(v);
    }
};

pub const Workspace = struct {
    id: []u8,
    name: []u8,
    status: ?[]u8 = null,
    created_at: ?[]u8 = null,

    pub fn deinit(self: *Workspace, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        if (self.status) |v| alloc.free(v);
        if (self.created_at) |v| alloc.free(v);
    }
};

pub const PaletteItem = struct {
    id: []u8,
    title: []u8,
    subtitle: ?[]u8 = null,
    kind: []u8,
    score: f64 = 0,

    pub fn deinit(self: *PaletteItem, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        if (self.subtitle) |v| alloc.free(v);
        alloc.free(self.kind);
    }
};

pub fn clearList(comptime T: type, alloc: std.mem.Allocator, list: *std.ArrayList(T)) void {
    for (list.items) |*item| item.deinit(alloc);
    list.clearRetainingCapacity();
}

pub fn parseWorkflows(alloc: std.mem.Allocator, json: []const u8) !std.ArrayList(Workflow) {
    var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
    defer parsed.deinit();
    var result: std.ArrayList(Workflow) = .empty;
    errdefer clearList(Workflow, alloc, &result);

    if (arrayFromRoot(&parsed.value, &.{ "workflows", "items", "data" })) |items| {
        for (items) |*item| {
            const obj = object(item) orelse continue;
            const id = try stringField(alloc, obj, &.{ "id", "path", "relativePath", "entryFile" }) orelse continue;
            errdefer alloc.free(id);
            const name = try stringField(alloc, obj, &.{ "name", "displayName", "id" }) orelse try alloc.dupe(u8, id);
            errdefer alloc.free(name);
            const status = try stringField(alloc, obj, &.{"status"}) orelse try alloc.dupe(u8, "unknown");
            errdefer alloc.free(status);
            try result.append(alloc, .{
                .id = id,
                .name = name,
                .relative_path = try stringField(alloc, obj, &.{ "relativePath", "entryFile", "path", "workflowPath", "workflow_path" }),
                .status = status,
                .updated_at = try stringField(alloc, obj, &.{ "updatedAt", "updated_at" }),
            });
        }
    }
    return result;
}

pub fn parseRuns(alloc: std.mem.Allocator, json: []const u8) !std.ArrayList(RunSummary) {
    var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
    defer parsed.deinit();
    var result: std.ArrayList(RunSummary) = .empty;
    errdefer clearList(RunSummary, alloc, &result);

    if (arrayFromRoot(&parsed.value, &.{ "runs", "items", "data" })) |items| {
        for (items) |*item| {
            if (try runFromValue(alloc, item)) |run| {
                try result.append(alloc, run);
            }
        }
    }
    return result;
}

pub fn parseRunInspection(alloc: std.mem.Allocator, json: []const u8) !RunInspection {
    var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
    defer parsed.deinit();
    const root = object(&parsed.value) orelse return error.InvalidRunInspection;

    var run_copy = root.get("run");
    const run_value = if (run_copy) |*value| value else &parsed.value;
    var inspection = RunInspection{
        .run = (try runFromValue(alloc, @constCast(run_value))) orelse return error.InvalidRunInspection,
    };
    errdefer inspection.deinit(alloc);

    if (arrayField(root, &.{ "tasks", "nodes" })) |tasks| {
        for (tasks) |*task_value| {
            const task_obj = object(task_value) orelse continue;
            const node_id = try stringField(alloc, task_obj, &.{ "nodeId", "node_id", "id" }) orelse continue;
            errdefer alloc.free(node_id);
            const state = try stringField(alloc, task_obj, &.{ "state", "status" }) orelse try alloc.dupe(u8, "unknown");
            errdefer alloc.free(state);
            try inspection.tasks.append(alloc, .{
                .node_id = node_id,
                .label = try stringField(alloc, task_obj, &.{ "label", "name" }),
                .state = state,
                .iteration = intField(task_obj, &.{ "iteration", "attempt" }),
            });
        }
    }
    return inspection;
}

pub fn parseApprovals(alloc: std.mem.Allocator, json: []const u8) !std.ArrayList(Approval) {
    var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
    defer parsed.deinit();
    var result: std.ArrayList(Approval) = .empty;
    errdefer clearList(Approval, alloc, &result);

    if (arrayFromRoot(&parsed.value, &.{ "approvals", "items", "data" })) |items| {
        for (items) |*item| {
            const obj = object(item) orelse continue;
            const id = try stringField(alloc, obj, &.{ "id", "approvalId", "approval_id" }) orelse continue;
            errdefer alloc.free(id);
            const run_id = try stringField(alloc, obj, &.{ "runId", "run_id" }) orelse try alloc.dupe(u8, "");
            errdefer alloc.free(run_id);
            const node_id = try stringField(alloc, obj, &.{ "nodeId", "node_id", "gate" }) orelse try alloc.dupe(u8, "");
            errdefer alloc.free(node_id);
            const status = try stringField(alloc, obj, &.{"status"}) orelse try alloc.dupe(u8, "pending");
            errdefer alloc.free(status);
            try result.append(alloc, .{
                .id = id,
                .run_id = run_id,
                .node_id = node_id,
                .gate = try stringField(alloc, obj, &.{"gate"}),
                .status = status,
                .requested_at = intField(obj, &.{ "requestedAt", "requested_at" }),
                .source = try stringField(alloc, obj, &.{"source"}),
            });
        }
    }
    return result;
}

pub fn parseAgents(alloc: std.mem.Allocator, json: []const u8) !std.ArrayList(Agent) {
    var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
    defer parsed.deinit();
    var result: std.ArrayList(Agent) = .empty;
    errdefer clearList(Agent, alloc, &result);

    if (arrayFromRoot(&parsed.value, &.{ "agents", "items", "data" })) |items| {
        for (items) |*item| {
            const obj = object(item) orelse continue;
            const id = try stringField(alloc, obj, &.{ "id", "name" }) orelse continue;
            errdefer alloc.free(id);
            const name = try stringField(alloc, obj, &.{ "name", "id" }) orelse try alloc.dupe(u8, id);
            errdefer alloc.free(name);
            const status = try stringField(alloc, obj, &.{"status"}) orelse try alloc.dupe(u8, "unknown");
            errdefer alloc.free(status);
            try result.append(alloc, .{
                .id = id,
                .name = name,
                .status = status,
                .usable = boolField(obj, &.{"usable"}) orelse false,
                .version = try stringField(alloc, obj, &.{"version"}),
            });
        }
    }
    return result;
}

pub fn parseWorkspaces(alloc: std.mem.Allocator, json: []const u8) !std.ArrayList(Workspace) {
    var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
    defer parsed.deinit();
    var result: std.ArrayList(Workspace) = .empty;
    errdefer clearList(Workspace, alloc, &result);

    if (arrayFromRoot(&parsed.value, &.{ "workspaces", "recent", "items", "data" })) |items| {
        for (items) |*item| {
            const obj = object(item) orelse continue;
            const id = try stringField(alloc, obj, &.{ "id", "path", "name" }) orelse continue;
            errdefer alloc.free(id);
            const name = try stringField(alloc, obj, &.{ "name", "displayName", "path" }) orelse try alloc.dupe(u8, id);
            errdefer alloc.free(name);
            try result.append(alloc, .{
                .id = id,
                .name = name,
                .status = try stringField(alloc, obj, &.{ "status", "state" }),
                .created_at = try stringField(alloc, obj, &.{ "createdAt", "created_at" }),
            });
        }
    }
    return result;
}

pub fn parsePaletteItems(alloc: std.mem.Allocator, json: []const u8) !std.ArrayList(PaletteItem) {
    var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
    defer parsed.deinit();
    var result: std.ArrayList(PaletteItem) = .empty;
    errdefer clearList(PaletteItem, alloc, &result);

    if (arrayFromRoot(&parsed.value, &.{ "items", "results", "data" })) |items| {
        for (items) |*item| {
            const obj = object(item) orelse continue;
            const id = try stringField(alloc, obj, &.{"id"}) orelse continue;
            errdefer alloc.free(id);
            const title = try stringField(alloc, obj, &.{"title"}) orelse try alloc.dupe(u8, id);
            errdefer alloc.free(title);
            const kind = try stringField(alloc, obj, &.{"kind"}) orelse try alloc.dupe(u8, "command");
            errdefer alloc.free(kind);
            try result.append(alloc, .{
                .id = id,
                .title = title,
                .subtitle = try stringField(alloc, obj, &.{"subtitle"}),
                .kind = kind,
                .score = floatField(obj, &.{"score"}) orelse 0,
            });
        }
    }
    return result;
}

fn runFromValue(alloc: std.mem.Allocator, value: *Value) !?RunSummary {
    const obj = object(value) orelse return null;
    const run_id = try stringField(alloc, obj, &.{ "runId", "run_id", "id" }) orelse return null;
    errdefer alloc.free(run_id);
    const status = try stringField(alloc, obj, &.{"status"}) orelse try alloc.dupe(u8, "unknown");
    errdefer alloc.free(status);
    var run = RunSummary{
        .run_id = run_id,
        .workflow_name = try stringField(alloc, obj, &.{ "workflowName", "workflow_name", "workflow" }),
        .workflow_path = try stringField(alloc, obj, &.{ "workflowPath", "workflow_path" }),
        .status = status,
        .started_at_ms = intField(obj, &.{ "startedAtMs", "started_at_ms", "startedAt", "started_at" }),
        .finished_at_ms = intField(obj, &.{ "finishedAtMs", "finished_at_ms", "finishedAt", "finished_at" }),
        .error_json = try stringField(alloc, obj, &.{ "errorJson", "error_json", "error" }),
    };
    if (obj.get("summary")) |summary| {
        var summary_copy = summary;
        if (object(&summary_copy)) |summary_obj| {
            run.total = intField(summary_obj, &.{"total"}) orelse 0;
            run.finished = intField(summary_obj, &.{ "finished", "succeeded" }) orelse 0;
            run.failed = intField(summary_obj, &.{"failed"}) orelse 0;
        }
    }
    return run;
}

fn arrayFromRoot(root: *Value, keys: []const []const u8) ?[]Value {
    switch (root.*) {
        .array => |array| return array.items,
        .object => |obj| {
            for (keys) |key| {
                if (obj.get(key)) |value| {
                    switch (value) {
                        .array => |array| return array.items,
                        else => {},
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

fn object(value: *Value) ?*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*obj| obj,
        else => null,
    };
}

fn arrayField(obj: *std.json.ObjectMap, keys: []const []const u8) ?[]Value {
    for (keys) |key| {
        if (obj.get(key)) |value| {
            switch (value) {
                .array => |array| return array.items,
                else => {},
            }
        }
    }
    return null;
}

fn stringField(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, keys: []const []const u8) !?[]u8 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .string => |s| if (s.len > 0) return try alloc.dupe(u8, s),
            .number_string => |s| return try alloc.dupe(u8, s),
            .integer => |i| return try std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| return try std.fmt.allocPrint(alloc, "{d}", .{f}),
            .bool => |b| return try alloc.dupe(u8, if (b) "true" else "false"),
            else => {},
        }
    }
    return null;
}

fn intField(obj: *std.json.ObjectMap, keys: []const []const u8) ?i64 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .integer => |i| return i,
            .float => |f| return @intFromFloat(f),
            .number_string, .string => |s| return std.fmt.parseInt(i64, s, 10) catch null,
            else => {},
        }
    }
    return null;
}

fn floatField(obj: *std.json.ObjectMap, keys: []const []const u8) ?f64 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .integer => |i| return @floatFromInt(i),
            .float => |f| return f,
            .number_string, .string => |s| return std.fmt.parseFloat(f64, s) catch null,
            else => {},
        }
    }
    return null;
}

fn boolField(obj: *std.json.ObjectMap, keys: []const []const u8) ?bool {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .bool => |b| return b,
            .integer => |i| return i != 0,
            .string => |s| {
                if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
                if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
            },
            else => {},
        }
    }
    return null;
}
