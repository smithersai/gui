const std = @import("std");

const Value = std.json.Value;

const NodeStateEntry = struct {
    node_id: []const u8,
    state: []const u8,
    iteration: i64,
    last_attempt: ?i64,
};

const AttemptEntry = struct {
    node_id: []const u8,
    iteration: i64,
    attempt: i64,
    state: []const u8,
    started_at_ms: i64,
    finished_at_ms: ?i64,
};

const BuiltNode = struct {
    json: []u8,
    state: []const u8,
};

const PropEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub fn call(allocator: std.mem.Allocator, method: []const u8, args: Value) !?[]u8 {
    if (!std.mem.startsWith(u8, method, "devtools.")) return null;

    if (std.mem.eql(u8, method, "devtools.validateRunId")) {
        return try validationResult(allocator, isValidRunId(stringArg(args, "runId") orelse ""));
    }
    if (std.mem.eql(u8, method, "devtools.validateNodeId")) {
        return try validationResult(allocator, isValidNodeId(stringArg(args, "nodeId") orelse ""));
    }
    if (std.mem.eql(u8, method, "devtools.validateIteration")) {
        return try validationResult(allocator, (intArg(args, "iteration") orelse -1) >= 0);
    }
    if (std.mem.eql(u8, method, "devtools.validateFrameNo")) {
        return try validationResult(allocator, (intArg(args, "frameNo") orelse -1) >= 0);
    }
    if (std.mem.eql(u8, method, "devtools.sqlQuote")) {
        const quoted = try sqlQuote(allocator, stringArg(args, "value") orelse "");
        defer allocator.free(quoted);
        return try jsonStringAlloc(allocator, quoted);
    }
    if (std.mem.eql(u8, method, "devtools.normalizeNodeState")) {
        return try jsonStringAlloc(allocator, normalizeNodeState(stringArg(args, "state") orelse ""));
    }
    if (std.mem.eql(u8, method, "devtools.rolledUpState")) {
        return try rolledUpStateCall(allocator, args);
    }
    if (std.mem.eql(u8, method, "devtools.nodeStateQuery")) {
        return try queryCall(allocator, args, "_smithers_nodes");
    }
    if (std.mem.eql(u8, method, "devtools.attemptQuery")) {
        return try queryCall(allocator, args, "_smithers_attempts");
    }
    if (std.mem.eql(u8, method, "devtools.nodeStateDict")) {
        return try nodeStateDictCall(allocator, args);
    }
    if (std.mem.eql(u8, method, "devtools.attemptEntries")) {
        return try attemptEntriesCall(allocator, args);
    }
    if (std.mem.eql(u8, method, "devtools.nodeStatesAtTimestamp")) {
        return try nodeStatesAtTimestampCall(allocator, args);
    }
    if (std.mem.eql(u8, method, "devtools.buildTree")) {
        return try buildTreeCall(allocator, args);
    }
    if (std.mem.eql(u8, method, "devtools.applyFrameDeltas")) {
        return try applyFrameDeltasCall(allocator, args);
    }
    if (std.mem.eql(u8, method, "devtools.applyDelta")) {
        return try applyDeltaCall(allocator, args, false);
    }
    if (std.mem.eql(u8, method, "devtools.applyDeltaOp")) {
        return try applyDeltaCall(allocator, args, true);
    }

    return null;
}

fn validationResult(allocator: std.mem.Allocator, valid: bool) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"valid\":{s}}}", .{if (valid) "true" else "false"});
}

fn isValidRunId(run_id: []const u8) bool {
    if (run_id.len == 0 or run_id.len > 64) return false;
    for (run_id) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn isValidNodeId(node_id: []const u8) bool {
    if (node_id.len == 0 or node_id.len > 128) return false;
    for (node_id) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':')) return false;
    }
    return true;
}

fn sqlQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (value) |c| {
        try out.writer.writeByte(c);
        if (c == '\'') try out.writer.writeByte('\'');
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

fn normalizeNodeState(raw: []const u8) []const u8 {
    var buf: [128]u8 = undefined;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    const len = @min(trimmed.len, buf.len);
    for (trimmed[0..len], 0..) |c, i| {
        buf[i] = switch (c) {
            'A'...'Z' => c + 32,
            '_', ' ' => '-',
            else => c,
        };
    }
    const token = buf[0..len];
    if (std.mem.eql(u8, token, "running") or
        std.mem.eql(u8, token, "in-progress") or
        std.mem.eql(u8, token, "inprogress") or
        std.mem.eql(u8, token, "started")) return "running";
    if (std.mem.eql(u8, token, "finished") or
        std.mem.eql(u8, token, "complete") or
        std.mem.eql(u8, token, "completed") or
        std.mem.eql(u8, token, "success") or
        std.mem.eql(u8, token, "succeeded") or
        std.mem.eql(u8, token, "done")) return "finished";
    if (std.mem.eql(u8, token, "failed") or
        std.mem.eql(u8, token, "failure") or
        std.mem.eql(u8, token, "error") or
        std.mem.eql(u8, token, "errored")) return "failed";
    if (std.mem.eql(u8, token, "waiting-approval") or
        std.mem.eql(u8, token, "waitingapproval")) return "waitingApproval";
    if (std.mem.eql(u8, token, "blocked") or std.mem.eql(u8, token, "paused")) return "blocked";
    if (std.mem.eql(u8, token, "cancelled") or
        std.mem.eql(u8, token, "canceled") or
        std.mem.eql(u8, token, "skipped")) return "cancelled";
    if (std.mem.eql(u8, token, "pending") or token.len == 0) return "pending";
    return raw;
}

fn rollupRank(state: []const u8) i32 {
    if (std.mem.eql(u8, state, "failed")) return 6;
    if (std.mem.eql(u8, state, "running")) return 5;
    if (std.mem.eql(u8, state, "blocked")) return 4;
    if (std.mem.eql(u8, state, "waitingApproval")) return 3;
    if (std.mem.eql(u8, state, "pending")) return 2;
    if (std.mem.eql(u8, state, "finished")) return 1;
    if (std.mem.eql(u8, state, "cancelled")) return 0;
    return -1;
}

fn rolledUpState(states: []const []const u8) ?[]const u8 {
    var best_state: ?[]const u8 = null;
    var best_rank: i32 = -2;
    for (states) |state| {
        if (state.len == 0) continue;
        const rank = rollupRank(state);
        if (best_state == null or rank > best_rank) {
            best_state = state;
            best_rank = rank;
        }
    }
    return best_state;
}

fn rolledUpStateCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    const arr = arrayArg(args, "states") orelse return try allocator.dupe(u8, "null");
    var states = try allocator.alloc([]const u8, arr.len);
    defer allocator.free(states);
    var count: usize = 0;
    for (arr) |item| {
        if (item == .string) {
            states[count] = item.string;
            count += 1;
        }
    }
    if (rolledUpState(states[0..count])) |state| return jsonStringAlloc(allocator, state);
    return try allocator.dupe(u8, "null");
}

fn queryCall(allocator: std.mem.Allocator, args: Value, table: []const u8) ![]u8 {
    const run_id = stringArg(args, "runId") orelse "";
    const quoted = try sqlQuote(allocator, run_id);
    defer allocator.free(quoted);
    if (std.mem.eql(u8, table, "_smithers_nodes")) {
        return try std.fmt.allocPrint(
            allocator,
            "SELECT node_id, state, iteration, last_attempt\nFROM _smithers_nodes\nWHERE run_id={s}\nORDER BY iteration ASC;",
            .{quoted},
        );
    }
    return try std.fmt.allocPrint(
        allocator,
        "SELECT node_id, iteration, attempt, state, started_at_ms, finished_at_ms\nFROM _smithers_attempts\nWHERE run_id={s}\nORDER BY started_at_ms ASC;",
        .{quoted},
    );
}

pub fn nodeStateDictCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    const rows = arrayArg(args, "rows") orelse &.{};
    var entries: std.ArrayList(NodeStateEntry) = .empty;
    defer entries.deinit(allocator);

    for (rows) |row| {
        if (row != .object) continue;
        const node_id = objectString(row, "node_id") orelse continue;
        const state = objectString(row, "state") orelse continue;
        const iteration = objectInt(row, "iteration") orelse 0;
        const last_attempt = objectInt(row, "last_attempt");
        const entry = NodeStateEntry{
            .node_id = node_id,
            .state = state,
            .iteration = iteration,
            .last_attempt = last_attempt,
        };
        var replaced = false;
        for (entries.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing.node_id, node_id)) {
                if (iteration > existing.iteration) entries.items[idx] = entry;
                replaced = true;
                break;
            }
        }
        if (!replaced) try entries.append(allocator, entry);
    }

    return writeNodeStateMap(allocator, entries.items);
}

pub fn attemptEntriesCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    const rows = arrayArg(args, "rows") orelse &.{};
    var entries: std.ArrayList(AttemptEntry) = .empty;
    defer entries.deinit(allocator);

    for (rows) |row| {
        if (row != .object) continue;
        const node_id = objectString(row, "node_id") orelse continue;
        const started = objectInt(row, "started_at_ms") orelse continue;
        try entries.append(allocator, .{
            .node_id = node_id,
            .iteration = objectInt(row, "iteration") orelse 0,
            .attempt = objectInt(row, "attempt") orelse 0,
            .state = objectString(row, "state") orelse "",
            .started_at_ms = started,
            .finished_at_ms = objectInt(row, "finished_at_ms"),
        });
    }

    return writeAttemptArray(allocator, entries.items);
}

pub fn nodeStatesAtTimestampCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    const attempts_json = arrayArg(args, "attempts") orelse &.{};
    const frame_timestamp_ms = intArg(args, "frameTimestampMs") orelse 0;
    var chosen: std.ArrayList(AttemptEntry) = .empty;
    defer chosen.deinit(allocator);

    for (attempts_json) |value| {
        const entry = parseAttemptEntry(value) orelse continue;
        if (entry.started_at_ms > frame_timestamp_ms) continue;
        var replaced = false;
        for (chosen.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing.node_id, entry.node_id) and existing.iteration == entry.iteration) {
                if (entry.attempt > existing.attempt or
                    (entry.attempt == existing.attempt and entry.started_at_ms > existing.started_at_ms))
                {
                    chosen.items[idx] = entry;
                }
                replaced = true;
                break;
            }
        }
        if (!replaced) try chosen.append(allocator, entry);
    }

    var per_node: std.ArrayList(AttemptEntry) = .empty;
    defer per_node.deinit(allocator);
    for (chosen.items) |entry| {
        var replaced = false;
        for (per_node.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing.node_id, entry.node_id)) {
                if (entry.iteration > existing.iteration) per_node.items[idx] = entry;
                replaced = true;
                break;
            }
        }
        if (!replaced) try per_node.append(allocator, entry);
    }

    var states: std.ArrayList(NodeStateEntry) = .empty;
    defer states.deinit(allocator);
    for (per_node.items) |entry| {
        const state_at_frame = if (entry.finished_at_ms) |finished|
            if (finished <= frame_timestamp_ms) entry.state else "running"
        else
            "running";
        try states.append(allocator, .{
            .node_id = entry.node_id,
            .state = state_at_frame,
            .iteration = entry.iteration,
            .last_attempt = entry.attempt,
        });
    }
    return writeNodeStateMap(allocator, states.items);
}

pub fn buildTreeCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const xml = objectValue(args, "xml") orelse return error.InvalidDevToolsTree;
    const task_index = arrayArg(args, "taskIndex") orelse &.{};
    const node_states = objectValue(args, "nodeStates") orelse Value{ .object = std.json.ObjectMap.init(scratch) };
    var next_id: i64 = 0;
    const built = try buildNode(scratch, xml, 0, &next_id, task_index, node_states);
    return try allocator.dupe(u8, built.json);
}

fn buildNode(
    allocator: std.mem.Allocator,
    xml: Value,
    depth: i64,
    next_id: *i64,
    task_index: []const Value,
    node_states: Value,
) !BuiltNode {
    const id = next_id.*;
    next_id.* += 1;

    const tag = objectString(xml, "tag") orelse "";
    const props_value = objectValue(xml, "props") orelse Value{ .object = std.json.ObjectMap.init(allocator) };
    const node_type = smithersType(tag);
    const name = derivedName(tag, props_value);

    var children: std.ArrayList(BuiltNode) = .empty;
    defer children.deinit(allocator);
    var inline_text: ?[]u8 = if (objectString(xml, "text")) |t| try allocator.dupe(u8, t) else null;

    if (objectValue(xml, "children")) |children_value| {
        if (children_value == .array) {
            for (children_value.array.items) |child| {
                const child_kind = objectString(child, "kind") orelse "element";
                if (std.mem.eql(u8, child_kind, "text") or std.mem.eql(u8, child_kind, "cdata")) {
                    if (objectString(child, "text")) |text| {
                        if (text.len == 0) continue;
                        if (inline_text) |existing| {
                            inline_text = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ existing, text });
                        } else {
                            inline_text = try allocator.dupe(u8, text);
                        }
                    }
                } else {
                    try children.append(allocator, try buildNode(
                        allocator,
                        child,
                        depth + 1,
                        next_id,
                        task_index,
                        node_states,
                    ));
                }
            }
        }
    }

    var props: std.ArrayList(PropEntry) = .empty;
    defer props.deinit(allocator);
    if (props_value == .object) {
        var it = props_value.object.iterator();
        while (it.next()) |entry| {
            try setProp(allocator, &props, entry.key_ptr.*, try propString(allocator, entry.value_ptr.*));
        }
    }
    if (inline_text) |text| try setProp(allocator, &props, "text", text);

    var task_json: ?[]u8 = null;
    if (std.mem.eql(u8, node_type, "task")) {
        if (propValue(props.items, "id")) |node_id| {
            const index_entry = findTaskIndex(task_index, node_id);
            var task_out: std.Io.Writer.Allocating = .init(allocator);
            errdefer task_out.deinit();
            try task_out.writer.print(
                "{{\"nodeId\":{f},\"kind\":{f},\"agent\":",
                .{
                    std.json.fmt(node_id, .{}),
                    std.json.fmt(if (index_entry) |entry| objectString(entry, "kind") orelse "agent" else "agent", .{}),
                },
            );
            try writeNullableString(&task_out.writer, if (index_entry) |entry| objectString(entry, "agent") else null);
            try task_out.writer.writeAll(",\"label\":");
            try writeNullableString(&task_out.writer, if (index_entry) |entry| objectString(entry, "label") else null);
            try task_out.writer.writeAll(",\"outputTableName\":");
            try writeNullableString(&task_out.writer, if (index_entry) |entry| objectString(entry, "outputTableName") else null);
            try task_out.writer.writeAll(",\"iteration\":");
            if (index_entry) |entry| {
                if (objectInt(entry, "iteration")) |iteration| {
                    try task_out.writer.print("{}", .{iteration});
                } else {
                    try task_out.writer.writeAll("null");
                }
            } else {
                try task_out.writer.writeAll("null");
            }
            try task_out.writer.writeByte('}');
            task_json = try task_out.toOwnedSlice();

            const existing_state = propValue(props.items, "state");
            if (existing_state == null or existing_state.?.len == 0) {
                if (nodeStateFor(node_states, node_id)) |state_entry| {
                    try setProp(allocator, &props, "state", normalizeNodeState(state_entry.state));
                    if (propValue(props.items, "iteration") == null) {
                        try setProp(allocator, &props, "iteration", try std.fmt.allocPrint(allocator, "{}", .{state_entry.iteration}));
                    }
                } else {
                    try setProp(allocator, &props, "state", "pending");
                }
            }
        }
    }

    var child_states = try allocator.alloc([]const u8, children.items.len);
    defer allocator.free(child_states);
    for (children.items, 0..) |child, idx| child_states[idx] = child.state;
    var state_for_parent = propValue(props.items, "state") orelse "";
    if (children.items.len > 0 and state_for_parent.len == 0) {
        if (rolledUpState(child_states)) |rolled| {
            try setProp(allocator, &props, "state", rolled);
            state_for_parent = rolled;
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        "{{\"id\":{},\"type\":{f},\"name\":{f},\"props\":",
        .{ id, std.json.fmt(node_type, .{}), std.json.fmt(name, .{}) },
    );
    try writePropsObject(&out.writer, props.items);
    try out.writer.writeAll(",\"task\":");
    if (task_json) |task| {
        try out.writer.writeAll(task);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"children\":[");
    for (children.items, 0..) |child, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(child.json);
    }
    try out.writer.print("],\"depth\":{}}}", .{depth});
    return .{ .json = try out.toOwnedSlice(), .state = state_for_parent };
}

pub fn applyFrameDeltasCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var tree = objectValue(args, "keyframe") orelse return error.InvalidFrame;
    const deltas = arrayArg(args, "deltas") orelse &.{};
    for (deltas) |delta| {
        const ops = if (delta == .object) delta.object.get("ops") else null;
        if (ops == null or ops.? != .array) continue;
        for (ops.?.array.items) |op| {
            const op_name = objectString(op, "op") orelse continue;
            const path_value = objectValue(op, "path") orelse continue;
            if (path_value != .array) continue;
            const value = objectValue(op, "value");
            if (std.mem.eql(u8, op_name, "set")) {
                try frameSet(allocator, &tree, path_value.array.items, value);
            } else if (std.mem.eql(u8, op_name, "insert")) {
                try frameInsert(&tree, path_value.array.items, value);
            } else if (std.mem.eql(u8, op_name, "remove")) {
                try frameRemove(&tree, path_value.array.items);
            }
        }
    }
    return jsonValueAlloc(allocator, tree);
}

fn applyDeltaCall(allocator: std.mem.Allocator, args: Value, single_op: bool) ![]u8 {
    var tree = objectValue(args, "tree") orelse Value.null;
    if (single_op) {
        if (objectValue(args, "op")) |op| {
            if (try applyNodeOp(allocator, &tree, op)) |err| {
                return writeApplyError(allocator, err);
            }
        }
    } else if (objectValue(args, "delta")) |delta| {
        if (objectValue(delta, "ops")) |ops_value| {
            if (ops_value == .array) {
                for (ops_value.array.items) |op| {
                    if (try applyNodeOp(allocator, &tree, op)) |err| {
                        return writeApplyError(allocator, err);
                    }
                }
            }
        }
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"ok\":true,\"tree\":");
    try std.json.Stringify.value(tree, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

const ApplyError = union(enum) {
    unknown_parent: i64,
    unknown_node: i64,
    index_out_of_bounds: struct { parent_id: i64, index: i64, child_count: i64 },
};

fn applyNodeOp(allocator: std.mem.Allocator, tree: *Value, op: Value) !?ApplyError {
    const op_name = objectString(op, "op") orelse return null;
    if (std.mem.eql(u8, op_name, "addNode")) {
        const parent_id = objectInt(op, "parentId") orelse -1;
        const index = objectInt(op, "index") orelse 0;
        const node = objectValue(op, "node") orelse Value.null;
        if (tree.* == .null) {
            if (parent_id == -1 and index == 0) {
                tree.* = node;
                return null;
            }
            return ApplyError{ .unknown_parent = parent_id };
        }
        const parent = findNodePtr(tree, parent_id) orelse return ApplyError{ .unknown_parent = parent_id };
        const children = nodeChildrenPtr(parent) orelse return ApplyError{
            .index_out_of_bounds = .{ .parent_id = parent_id, .index = index, .child_count = 0 },
        };
        if (index < 0 or index > children.items.len) {
            return ApplyError{ .index_out_of_bounds = .{
                .parent_id = parent_id,
                .index = index,
                .child_count = @intCast(children.items.len),
            } };
        }
        try children.insert(@intCast(index), node);
        return null;
    }
    if (std.mem.eql(u8, op_name, "removeNode")) {
        const id = objectInt(op, "id") orelse -1;
        if (tree.* == .null) return ApplyError{ .unknown_node = id };
        if ((objectInt(tree.*, "id") orelse -2) == id) {
            tree.* = Value.null;
            return null;
        }
        if (!removeNodeById(tree, id)) return ApplyError{ .unknown_node = id };
        return null;
    }
    if (std.mem.eql(u8, op_name, "updateProps")) {
        const id = objectInt(op, "id") orelse -1;
        const props = objectValue(op, "props") orelse Value{ .object = std.json.ObjectMap.init(allocator) };
        const node = findNodePtr(tree, id) orelse return ApplyError{ .unknown_node = id };
        if (node.* != .object) return ApplyError{ .unknown_node = id };
        var props_ptr = node.object.getPtr("props");
        if (props_ptr == null or props_ptr.?.* != .object) {
            try node.object.put("props", Value{ .object = std.json.ObjectMap.init(allocator) });
            props_ptr = node.object.getPtr("props");
        }
        if (props == .object) {
            var it = props.object.iterator();
            while (it.next()) |entry| {
                try props_ptr.?.object.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        return null;
    }
    if (std.mem.eql(u8, op_name, "updateTask")) {
        const id = objectInt(op, "id") orelse -1;
        const node = findNodePtr(tree, id) orelse return ApplyError{ .unknown_node = id };
        if (node.* != .object) return ApplyError{ .unknown_node = id };
        try node.object.put("task", objectValue(op, "task") orelse Value.null);
        return null;
    }
    return null;
}

fn writeApplyError(allocator: std.mem.Allocator, err: ApplyError) ![]u8 {
    return switch (err) {
        .unknown_parent => |id| try std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"error\":\"unknownParent\",\"id\":{}}}",
            .{id},
        ),
        .unknown_node => |id| try std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"error\":\"unknownNode\",\"id\":{}}}",
            .{id},
        ),
        .index_out_of_bounds => |value| try std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"error\":\"indexOutOfBounds\",\"parentId\":{},\"index\":{},\"childCount\":{}}}",
            .{ value.parent_id, value.index, value.child_count },
        ),
    };
}

fn frameLeaf(root: *Value, path: []Value) *Value {
    var node = root;
    var index: usize = 0;
    while (path.len - index > 2) {
        const key = pathKey(path[index]) orelse break;
        const child_idx = pathIndex(path[index + 1]) orelse break;
        if (!std.mem.eql(u8, key, "children")) break;
        const children = nodeChildrenPtr(node) orelse break;
        if (child_idx < 0 or child_idx >= children.items.len) break;
        node = &children.items[@intCast(child_idx)];
        index += 2;
    }
    return node;
}

fn frameSet(allocator: std.mem.Allocator, tree: *Value, path: []Value, value: ?Value) !void {
    if (path.len == 0) {
        if (value) |v| {
            if (v == .object) tree.* = v;
        }
        return;
    }
    const node = frameLeaf(tree, path);
    const last = path[path.len - 1];
    if (pathKey(last)) |key| {
        if (std.mem.eql(u8, key, "text")) {
            if (value) |v| if (v == .string and node.* == .object) try node.object.put("text", v);
            return;
        }
        if (path.len >= 2 and pathKey(path[path.len - 2]) != null and
            std.mem.eql(u8, pathKey(path[path.len - 2]).?, "props"))
        {
            try frameSetProp(allocator, node, key, value);
            return;
        }
        if (std.mem.eql(u8, objectString(node.*, "kind") orelse "", "element")) {
            try frameSetProp(allocator, node, key, value);
        }
    } else if (pathIndex(last)) |idx| {
        if (value) |v| {
            if (v == .object) {
                if (nodeChildrenPtr(node)) |children| {
                    if (idx >= 0 and idx < children.items.len) children.items[@intCast(idx)] = v;
                }
            }
        }
    }
}

fn frameSetProp(allocator: std.mem.Allocator, node: *Value, key: []const u8, value: ?Value) !void {
    if (node.* != .object) return;
    var props = node.object.getPtr("props") orelse return;
    if (props.* != .object) return;
    if (value) |v| {
        switch (v) {
            .string => try props.object.put(key, v),
            .integer, .float, .number_string, .bool => try props.object.put(key, Value{ .string = try propString(allocator, v) }),
            .null => _ = props.object.orderedRemove(key),
            else => {},
        }
    } else {
        _ = props.object.orderedRemove(key);
    }
}

fn frameInsert(tree: *Value, path: []Value, value: ?Value) !void {
    if (path.len == 0) return;
    const idx = pathIndex(path[path.len - 1]) orelse return;
    const v = value orelse return;
    if (v != .object) return;
    const node = frameLeaf(tree, path);
    const children = nodeChildrenPtr(node) orelse return;
    const clamped: usize = if (idx < 0) 0 else @min(@as(usize, @intCast(idx)), children.items.len);
    try children.insert(clamped, v);
}

fn frameRemove(tree: *Value, path: []Value) !void {
    if (path.len == 0) return;
    const idx = pathIndex(path[path.len - 1]) orelse return;
    const node = frameLeaf(tree, path);
    const children = nodeChildrenPtr(node) orelse return;
    if (idx >= 0 and idx < children.items.len) _ = children.orderedRemove(@intCast(idx));
}

fn findNodePtr(node: *Value, id: i64) ?*Value {
    if (node.* != .object) return null;
    if ((objectInt(node.*, "id") orelse -1) == id) return node;
    const children = nodeChildrenPtr(node) orelse return null;
    for (children.items) |*child| {
        if (findNodePtr(child, id)) |found| return found;
    }
    return null;
}

fn removeNodeById(node: *Value, id: i64) bool {
    const children = nodeChildrenPtr(node) orelse return false;
    var i: usize = 0;
    while (i < children.items.len) : (i += 1) {
        if ((objectInt(children.items[i], "id") orelse -1) == id) {
            _ = children.orderedRemove(i);
            return true;
        }
        if (removeNodeById(&children.items[i], id)) return true;
    }
    return false;
}

fn nodeChildrenPtr(node: *Value) ?*std.json.Array {
    if (node.* != .object) return null;
    const children = node.object.getPtr("children") orelse return null;
    if (children.* != .array) return null;
    return &children.array;
}

fn writeNodeStateMap(allocator: std.mem.Allocator, entries: []const NodeStateEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.print("{f}:", .{std.json.fmt(entry.node_id, .{})});
        try writeNodeStateEntry(&out.writer, entry);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeNodeStateEntry(writer: *std.Io.Writer, entry: NodeStateEntry) !void {
    try writer.print(
        "{{\"nodeId\":{f},\"state\":{f},\"iteration\":{},\"lastAttempt\":",
        .{ std.json.fmt(entry.node_id, .{}), std.json.fmt(entry.state, .{}), entry.iteration },
    );
    if (entry.last_attempt) |last| try writer.print("{}", .{last}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn writeAttemptArray(allocator: std.mem.Allocator, entries: []const AttemptEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"nodeId\":{f},\"iteration\":{},\"attempt\":{},\"state\":{f},\"startedAtMs\":{},\"finishedAtMs\":",
            .{
                std.json.fmt(entry.node_id, .{}),
                entry.iteration,
                entry.attempt,
                std.json.fmt(entry.state, .{}),
                entry.started_at_ms,
            },
        );
        if (entry.finished_at_ms) |finished| try out.writer.print("{}", .{finished}) else try out.writer.writeAll("null");
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn parseAttemptEntry(value: Value) ?AttemptEntry {
    if (value != .object) return null;
    const node_id = objectString(value, "nodeId") orelse objectString(value, "node_id") orelse return null;
    const started = objectInt(value, "startedAtMs") orelse objectInt(value, "started_at_ms") orelse return null;
    return .{
        .node_id = node_id,
        .iteration = objectInt(value, "iteration") orelse 0,
        .attempt = objectInt(value, "attempt") orelse 0,
        .state = objectString(value, "state") orelse "",
        .started_at_ms = started,
        .finished_at_ms = objectInt(value, "finishedAtMs") orelse objectInt(value, "finished_at_ms"),
    };
}

fn nodeStateFor(node_states: Value, node_id: []const u8) ?NodeStateEntry {
    if (node_states != .object) return null;
    const value = node_states.object.get(node_id) orelse return null;
    if (value != .object) return null;
    return .{
        .node_id = objectString(value, "nodeId") orelse node_id,
        .state = objectString(value, "state") orelse "",
        .iteration = objectInt(value, "iteration") orelse 0,
        .last_attempt = objectInt(value, "lastAttempt"),
    };
}

fn findTaskIndex(task_index: []const Value, node_id: []const u8) ?Value {
    for (task_index) |entry| {
        if (std.mem.eql(u8, objectString(entry, "nodeId") orelse "", node_id)) return entry;
    }
    return null;
}

fn smithersType(tag: []const u8) []const u8 {
    if (std.mem.eql(u8, tag, "smithers:workflow")) return "workflow";
    if (std.mem.eql(u8, tag, "smithers:sequence")) return "sequence";
    if (std.mem.eql(u8, tag, "smithers:parallel")) return "parallel";
    if (std.mem.eql(u8, tag, "smithers:task")) return "task";
    if (std.mem.eql(u8, tag, "smithers:forEach") or
        std.mem.eql(u8, tag, "smithers:foreach") or
        std.mem.eql(u8, tag, "smithers:for-each")) return "forEach";
    if (std.mem.eql(u8, tag, "smithers:conditional") or std.mem.eql(u8, tag, "smithers:if")) return "conditional";
    return "unknown";
}

fn derivedName(tag: []const u8, props: Value) []const u8 {
    if (props == .object) {
        if (props.object.get("name")) |value| if (value == .string and value.string.len > 0) return value.string;
        if (props.object.get("id")) |value| if (value == .string and value.string.len > 0) return value.string;
    }
    if (std.mem.startsWith(u8, tag, "smithers:")) return tag["smithers:".len..];
    return if (tag.len == 0) "node" else tag;
}

fn propString(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
        .float => |f| blk: {
            if (@round(f) == f and @abs(f) < 1e15) {
                break :blk try std.fmt.allocPrint(allocator, "{}", .{@as(i64, @intFromFloat(f))});
            }
            break :blk try std.fmt.allocPrint(allocator, "{}", .{f});
        },
        .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .null => "",
        else => try jsonValueAlloc(allocator, value),
    };
}

fn propValue(props: []const PropEntry, key: []const u8) ?[]const u8 {
    for (props) |prop| if (std.mem.eql(u8, prop.key, key)) return prop.value;
    return null;
}

fn setProp(allocator: std.mem.Allocator, props: *std.ArrayList(PropEntry), key: []const u8, value: []const u8) !void {
    for (props.items) |*prop| {
        if (std.mem.eql(u8, prop.key, key)) {
            prop.value = value;
            return;
        }
    }
    try props.append(allocator, .{ .key = key, .value = value });
}

fn writePropsObject(writer: *std.Io.Writer, props: []const PropEntry) !void {
    try writer.writeByte('{');
    for (props, 0..) |prop, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{f}:{f}", .{ std.json.fmt(prop.key, .{}), std.json.fmt(prop.value, .{}) });
    }
    try writer.writeByte('}');
}

fn writeNullableString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try writer.print("{f}", .{std.json.fmt(text, .{})});
    } else {
        try writer.writeAll("null");
    }
}

fn objectValue(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn objectString(value: Value, key: []const u8) ?[]const u8 {
    const found = objectValue(value, key) orelse return null;
    return if (found == .string) found.string else null;
}

fn stringArg(value: Value, key: []const u8) ?[]const u8 {
    return objectString(value, key);
}

fn intArg(value: Value, key: []const u8) ?i64 {
    return objectInt(value, key);
}

fn arrayArg(value: Value, key: []const u8) ?[]Value {
    const found = objectValue(value, key) orelse return null;
    return if (found == .array) found.array.items else null;
}

fn objectInt(value: Value, key: []const u8) ?i64 {
    const found = objectValue(value, key) orelse return null;
    return intValue(found);
}

fn intValue(value: Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn pathKey(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn pathIndex(value: Value) ?i64 {
    return intValue(value);
}

fn jsonStringAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(text, .{})});
}

fn jsonValueAlloc(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "devtools validates ids and quotes SQL" {
    try std.testing.expect(isValidRunId("run-1776372721752"));
    try std.testing.expect(!isValidRunId("a/b"));
    try std.testing.expect(isValidNodeId("node:review:0"));
    try std.testing.expect(!isValidNodeId("bad node"));
    const quoted = try sqlQuote(std.testing.allocator, "O'Brien");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'O''Brien'", quoted);
}

test "devtools reconstructs historical node states" {
    const json =
        \\{"attempts":[
        \\{"nodeId":"a","iteration":0,"attempt":0,"state":"finished","startedAtMs":10,"finishedAtMs":20},
        \\{"nodeId":"b","iteration":0,"attempt":0,"state":"failed","startedAtMs":15,"finishedAtMs":40}
        \\],"frameTimestampMs":25}
    ;
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const out = try nodeStatesAtTimestampCall(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(out);
    var result = try std.json.parseFromSlice(Value, std.testing.allocator, out, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("finished", result.value.object.get("a").?.object.get("state").?.string);
    try std.testing.expectEqualStrings("running", result.value.object.get("b").?.object.get("state").?.string);
}

test "devtools builds tree with rolled state" {
    const json =
        \\{"xml":{"kind":"element","tag":"smithers:sequence","props":{"name":"seq"},"children":[
        \\{"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},
        \\{"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]}
        \\]},"taskIndex":[],"nodeStates":{"a":{"nodeId":"a","state":"finished","iteration":0,"lastAttempt":null},"b":{"nodeId":"b","state":"failed","iteration":0,"lastAttempt":1}}}
    ;
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const out = try buildTreeCall(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(out);
    var result = try std.json.parseFromSlice(Value, std.testing.allocator, out, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("sequence", result.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("failed", result.value.object.get("props").?.object.get("state").?.string);
}
