const std = @import("std");
const devtools = @import("DevToolsClient.zig");

const Value = std.json.Value;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_OPEN_READONLY: c_int = 0x00000001;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close(db: ?*sqlite3) c_int;
extern fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, value: [*]const u8, n: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) c_int;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
extern fn sqlite3_column_type(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
extern fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;

const SQLITE_NULL: c_int = 5;

pub const Error = error{
    DbOpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    RunNotFound,
    MalformedKeyframe,
} || std.mem.Allocator.Error || std.fmt.ParseIntError || error{ OutOfMemory, InvalidDevToolsTree, InvalidFrame };

pub fn loadSnapshotJson(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    run_id: []const u8,
    frame_no: ?i64,
) ![]u8 {
    const path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(path_z);

    var db: ?*sqlite3 = null;
    if (sqlite3_open_v2(path_z.ptr, &db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) {
        _ = sqlite3_close(db);
        return error.DbOpenFailed;
    }
    defer _ = sqlite3_close(db);
    _ = sqlite3_busy_timeout(db, 5000);

    const target_frame = try resolveTargetFrame(db, run_id, frame_no);

    var key_row = try loadKeyframe(allocator, db, run_id, target_frame);
    defer key_row.deinit(allocator);

    // Parse keyframe xml_json and task_index_json.
    var xml_parsed = try std.json.parseFromSlice(Value, allocator, key_row.xml_json, .{});
    defer xml_parsed.deinit();

    const task_index_text = if (key_row.task_index_json.len > 0) key_row.task_index_json else "[]";
    var task_index_parsed = try std.json.parseFromSlice(Value, allocator, task_index_text, .{});
    defer task_index_parsed.deinit();

    // Apply deltas between keyframe and target.
    var final_xml_holder: ?[]u8 = null;
    defer if (final_xml_holder) |h| allocator.free(h);
    var final_xml_parsed: ?std.json.Parsed(Value) = null;
    defer if (final_xml_parsed) |*p| p.deinit();

    var xml_for_build: Value = xml_parsed.value;
    if (target_frame > key_row.frame_no) {
        const deltas = try loadDeltas(allocator, db, run_id, key_row.frame_no, target_frame);
        defer freeStrings(allocator, deltas);
        if (deltas.len > 0) {
            const applied = try buildAppliedXml(allocator, xml_parsed.value, deltas);
            final_xml_holder = applied;
            const parsed = try std.json.parseFromSlice(Value, allocator, applied, .{});
            final_xml_parsed = parsed;
            xml_for_build = parsed.value;
        }
    }

    // Resolve wall-clock ts if historical (frame_no was supplied).
    var frame_ts_ms: ?i64 = null;
    if (frame_no != null) {
        if (target_frame == key_row.frame_no) {
            frame_ts_ms = key_row.created_at_ms;
        } else {
            frame_ts_ms = try loadFrameTimestamp(db, run_id, target_frame);
        }
    }

    // Load node states.
    var node_states_json: []u8 = undefined;
    if (frame_ts_ms) |ts| {
        const attempt_rows = try loadAttemptRows(allocator, db, run_id);
        defer freeAttemptRows(allocator, attempt_rows);
        node_states_json = try buildHistoricalNodeStates(allocator, attempt_rows, ts);
    } else {
        const node_rows = try loadNodeRows(allocator, db, run_id);
        defer freeNodeRows(allocator, node_rows);
        node_states_json = try buildLiveNodeStates(allocator, node_rows);
    }
    defer allocator.free(node_states_json);

    var node_states_parsed = try std.json.parseFromSlice(Value, allocator, node_states_json, .{});
    defer node_states_parsed.deinit();

    // Call buildTreeCall with xml + taskIndex + nodeStates.
    const root_json = try buildRoot(allocator, xml_for_build, task_index_parsed.value, node_states_parsed.value);
    defer allocator.free(root_json);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"runId\":{f},\"frameNo\":{},\"seq\":{},\"root\":{s}}}",
        .{ std.json.fmt(run_id, .{}), target_frame, target_frame, root_json },
    );
}

pub fn buildSnapshotEventJson(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    run_id: []const u8,
    frame_no: ?i64,
) ![]u8 {
    const inner = try loadSnapshotJson(allocator, db_path, run_id, frame_no);
    defer allocator.free(inner);
    // Flat-merge: replace leading `{` with `{"type":"snapshot",`.
    if (inner.len < 2 or inner[0] != '{') return error.MalformedKeyframe;
    const rest = inner[1..];
    return try std.fmt.allocPrint(allocator, "{{\"type\":\"snapshot\",{s}", .{rest});
}

pub fn latestFrameNo(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    run_id: []const u8,
) !?i64 {
    _ = allocator;
    const path_z = try std.heap.c_allocator.dupeZ(u8, db_path);
    defer std.heap.c_allocator.free(path_z);
    var db: ?*sqlite3 = null;
    if (sqlite3_open_v2(path_z.ptr, &db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) {
        _ = sqlite3_close(db);
        return error.DbOpenFailed;
    }
    defer _ = sqlite3_close(db);
    return queryMaxFrame(db, run_id) catch |err| switch (err) {
        error.RunNotFound => null,
        else => err,
    };
}

fn resolveTargetFrame(db: ?*sqlite3, run_id: []const u8, frame_no: ?i64) !i64 {
    if (frame_no) |fn_val| return fn_val;
    return try queryMaxFrame(db, run_id);
}

fn queryMaxFrame(db: ?*sqlite3, run_id: []const u8) !i64 {
    const sql = "SELECT MAX(frame_no) FROM _smithers_frames WHERE run_id=?;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, run_id) != SQLITE_OK) return error.BindFailed;
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) return error.RunNotFound;
    if (sqlite3_column_type(stmt, 0) == SQLITE_NULL) return error.RunNotFound;
    return sqlite3_column_int64(stmt, 0);
}

const KeyframeRow = struct {
    frame_no: i64,
    xml_json: []u8,
    task_index_json: []u8,
    created_at_ms: i64,

    fn deinit(self: *KeyframeRow, allocator: std.mem.Allocator) void {
        allocator.free(self.xml_json);
        allocator.free(self.task_index_json);
    }
};

fn loadKeyframe(allocator: std.mem.Allocator, db: ?*sqlite3, run_id: []const u8, target_frame: i64) !KeyframeRow {
    const sql =
        "SELECT frame_no, xml_json, task_index_json, created_at_ms" ++
        " FROM _smithers_frames WHERE run_id=? AND encoding='keyframe' AND frame_no<=?" ++
        " ORDER BY frame_no DESC LIMIT 1;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, run_id) != SQLITE_OK) return error.BindFailed;
    if (sqlite3_bind_int64(stmt, 2, target_frame) != SQLITE_OK) return error.BindFailed;
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) return error.RunNotFound;

    const frame_no = sqlite3_column_int64(stmt, 0);
    const xml = try dupColumnText(allocator, stmt, 1) orelse return error.MalformedKeyframe;
    errdefer allocator.free(xml);
    const task_index = try dupColumnText(allocator, stmt, 2) orelse try allocator.dupe(u8, "[]");
    errdefer allocator.free(task_index);
    const created_at_ms = sqlite3_column_int64(stmt, 3);
    return .{
        .frame_no = frame_no,
        .xml_json = xml,
        .task_index_json = task_index,
        .created_at_ms = created_at_ms,
    };
}

fn loadDeltas(allocator: std.mem.Allocator, db: ?*sqlite3, run_id: []const u8, keyframe_no: i64, target_frame: i64) ![][]u8 {
    const sql =
        "SELECT xml_json FROM _smithers_frames" ++
        " WHERE run_id=? AND encoding='delta' AND frame_no>? AND frame_no<=?" ++
        " ORDER BY frame_no ASC;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, run_id) != SQLITE_OK) return error.BindFailed;
    if (sqlite3_bind_int64(stmt, 2, keyframe_no) != SQLITE_OK) return error.BindFailed;
    if (sqlite3_bind_int64(stmt, 3, target_frame) != SQLITE_OK) return error.BindFailed;

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    while (true) {
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) return error.StepFailed;
        if (try dupColumnText(allocator, stmt, 0)) |text| {
            try list.append(allocator, text);
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn loadFrameTimestamp(db: ?*sqlite3, run_id: []const u8, frame_no: i64) !?i64 {
    const sql = "SELECT created_at_ms FROM _smithers_frames WHERE run_id=? AND frame_no=? LIMIT 1;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, run_id) != SQLITE_OK) return error.BindFailed;
    if (sqlite3_bind_int64(stmt, 2, frame_no) != SQLITE_OK) return error.BindFailed;
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) return null;
    return sqlite3_column_int64(stmt, 0);
}

const NodeRow = struct {
    node_id: []u8,
    state: []u8,
    iteration: i64,
    last_attempt: ?i64,
};

fn loadNodeRows(allocator: std.mem.Allocator, db: ?*sqlite3, run_id: []const u8) ![]NodeRow {
    const sql = "SELECT node_id, state, iteration, last_attempt FROM _smithers_nodes WHERE run_id=? ORDER BY iteration ASC;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, run_id) != SQLITE_OK) return error.BindFailed;
    var list: std.ArrayList(NodeRow) = .empty;
    errdefer {
        for (list.items) |row| {
            allocator.free(row.node_id);
            allocator.free(row.state);
        }
        list.deinit(allocator);
    }
    while (true) {
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) return error.StepFailed;
        const node_id = try dupColumnText(allocator, stmt, 0) orelse continue;
        errdefer allocator.free(node_id);
        const state = try dupColumnText(allocator, stmt, 1) orelse try allocator.dupe(u8, "");
        errdefer allocator.free(state);
        const iteration = sqlite3_column_int64(stmt, 2);
        const last_attempt: ?i64 = if (sqlite3_column_type(stmt, 3) == SQLITE_NULL) null else sqlite3_column_int64(stmt, 3);
        try list.append(allocator, .{
            .node_id = node_id,
            .state = state,
            .iteration = iteration,
            .last_attempt = last_attempt,
        });
    }
    return list.toOwnedSlice(allocator);
}

fn freeNodeRows(allocator: std.mem.Allocator, rows: []NodeRow) void {
    for (rows) |row| {
        allocator.free(row.node_id);
        allocator.free(row.state);
    }
    allocator.free(rows);
}

const AttemptRow = struct {
    node_id: []u8,
    iteration: i64,
    attempt: i64,
    state: []u8,
    started_at_ms: i64,
    finished_at_ms: ?i64,
};

fn loadAttemptRows(allocator: std.mem.Allocator, db: ?*sqlite3, run_id: []const u8) ![]AttemptRow {
    const sql = "SELECT node_id, iteration, attempt, state, started_at_ms, finished_at_ms FROM _smithers_attempts WHERE run_id=? ORDER BY started_at_ms ASC;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, run_id) != SQLITE_OK) return error.BindFailed;
    var list: std.ArrayList(AttemptRow) = .empty;
    errdefer {
        for (list.items) |row| {
            allocator.free(row.node_id);
            allocator.free(row.state);
        }
        list.deinit(allocator);
    }
    while (true) {
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) return error.StepFailed;
        const node_id = try dupColumnText(allocator, stmt, 0) orelse continue;
        errdefer allocator.free(node_id);
        const iteration = sqlite3_column_int64(stmt, 1);
        const attempt = sqlite3_column_int64(stmt, 2);
        const state = try dupColumnText(allocator, stmt, 3) orelse try allocator.dupe(u8, "");
        errdefer allocator.free(state);
        const started = sqlite3_column_int64(stmt, 4);
        const finished: ?i64 = if (sqlite3_column_type(stmt, 5) == SQLITE_NULL) null else sqlite3_column_int64(stmt, 5);
        try list.append(allocator, .{
            .node_id = node_id,
            .iteration = iteration,
            .attempt = attempt,
            .state = state,
            .started_at_ms = started,
            .finished_at_ms = finished,
        });
    }
    return list.toOwnedSlice(allocator);
}

fn freeAttemptRows(allocator: std.mem.Allocator, rows: []AttemptRow) void {
    for (rows) |row| {
        allocator.free(row.node_id);
        allocator.free(row.state);
    }
    allocator.free(rows);
}

fn buildLiveNodeStates(allocator: std.mem.Allocator, rows: []const NodeRow) ![]u8 {
    // Build args JSON: {"rows":[{"node_id":..,"state":..,"iteration":..,"last_attempt":..}, ...]}
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"rows\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"node_id\":{f},\"state\":{f},\"iteration\":{},\"last_attempt\":",
            .{ std.json.fmt(row.node_id, .{}), std.json.fmt(row.state, .{}), row.iteration },
        );
        if (row.last_attempt) |last| {
            try out.writer.print("{}", .{last});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    const args_json = out.written();
    var parsed = try std.json.parseFromSlice(Value, allocator, args_json, .{});
    defer parsed.deinit();
    return try devtools.nodeStateDictCall(allocator, parsed.value);
}

fn buildHistoricalNodeStates(allocator: std.mem.Allocator, rows: []const AttemptRow, frame_ts_ms: i64) ![]u8 {
    // First, convert DB rows into AttemptEntry JSON via the same route attemptEntriesCall uses,
    // then pass to nodeStatesAtTimestampCall with frameTimestampMs.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"rows\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"node_id\":{f},\"iteration\":{},\"attempt\":{},\"state\":{f},\"started_at_ms\":{},\"finished_at_ms\":",
            .{ std.json.fmt(row.node_id, .{}), row.iteration, row.attempt, std.json.fmt(row.state, .{}), row.started_at_ms },
        );
        if (row.finished_at_ms) |finished| {
            try out.writer.print("{}", .{finished});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    const attempts_args_json = out.written();
    var rows_parsed = try std.json.parseFromSlice(Value, allocator, attempts_args_json, .{});
    defer rows_parsed.deinit();
    const attempt_entries_json = try devtools.attemptEntriesCall(allocator, rows_parsed.value);
    defer allocator.free(attempt_entries_json);

    const final_args = try std.fmt.allocPrint(allocator, "{{\"attempts\":{s},\"frameTimestampMs\":{}}}", .{ attempt_entries_json, frame_ts_ms });
    defer allocator.free(final_args);
    var parsed = try std.json.parseFromSlice(Value, allocator, final_args, .{});
    defer parsed.deinit();
    return try devtools.nodeStatesAtTimestampCall(allocator, parsed.value);
}

fn buildAppliedXml(allocator: std.mem.Allocator, keyframe: Value, delta_strings: [][]u8) ![]u8 {
    // Build args: {"keyframe":<keyframe>,"deltas":[...parsed deltas...]}
    var deltas_arena = std.heap.ArenaAllocator.init(allocator);
    defer deltas_arena.deinit();
    const scratch = deltas_arena.allocator();

    var deltas_value: Value = Value{ .array = std.json.Array.init(scratch) };
    for (delta_strings) |text| {
        const parsed = std.json.parseFromSliceLeaky(Value, scratch, text, .{}) catch continue;
        try deltas_value.array.append(parsed);
    }

    var root_map = std.json.ObjectMap.init(scratch);
    try root_map.put("keyframe", keyframe);
    try root_map.put("deltas", deltas_value);
    const args = Value{ .object = root_map };
    return try devtools.applyFrameDeltasCall(allocator, args);
}

fn buildRoot(allocator: std.mem.Allocator, xml: Value, task_index: Value, node_states: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.init(scratch);
    try obj.put("xml", xml);
    try obj.put("taskIndex", task_index);
    try obj.put("nodeStates", node_states);
    const args = Value{ .object = obj };
    return try devtools.buildTreeCall(allocator, args);
}

fn freeStrings(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn bindText(stmt: ?*sqlite3_stmt, idx: c_int, value: []const u8) c_int {
    if (value.len == 0) return sqlite3_bind_text(stmt, idx, "", 0, null);
    return sqlite3_bind_text(stmt, idx, value.ptr, @intCast(value.len), null);
}

fn dupColumnText(allocator: std.mem.Allocator, stmt: ?*sqlite3_stmt, col: c_int) !?[]u8 {
    if (sqlite3_column_type(stmt, col) == SQLITE_NULL) return null;
    const ptr = sqlite3_column_text(stmt, col) orelse return null;
    const len: usize = @intCast(sqlite3_column_bytes(stmt, col));
    return try allocator.dupe(u8, ptr[0..len]);
}
