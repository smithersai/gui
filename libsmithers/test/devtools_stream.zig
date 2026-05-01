const std = @import("std");
const lib = @import("libsmithers");

const embedded = lib.apprt.embedded;
const structs = lib.apprt.structs;
const ffi = lib.ffi;

const SQLITE_OK = 0;
const SQLITE_DONE = 101;
const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: ?*sqlite3) c_int;
extern fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*:0]const u8,
    callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, value: [*]const u8, n: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) c_int;

const SCHEMA =
    "CREATE TABLE _smithers_frames (" ++
    "  run_id TEXT NOT NULL," ++
    "  frame_no INTEGER NOT NULL," ++
    "  created_at_ms INTEGER NOT NULL," ++
    "  xml_json TEXT NOT NULL," ++
    "  xml_hash TEXT," ++
    "  encoding TEXT NOT NULL," ++
    "  mounted_task_ids_json TEXT," ++
    "  task_index_json TEXT," ++
    "  note TEXT," ++
    "  PRIMARY KEY (run_id, frame_no)" ++
    ");" ++
    "CREATE TABLE _smithers_nodes (" ++
    "  run_id TEXT NOT NULL," ++
    "  node_id TEXT NOT NULL," ++
    "  iteration INTEGER NOT NULL DEFAULT 0," ++
    "  state TEXT," ++
    "  last_attempt INTEGER," ++
    "  updated_at_ms INTEGER," ++
    "  output_table TEXT," ++
    "  label TEXT," ++
    "  PRIMARY KEY (run_id, node_id, iteration)" ++
    ");" ++
    "CREATE TABLE _smithers_attempts (" ++
    "  run_id TEXT NOT NULL," ++
    "  node_id TEXT NOT NULL," ++
    "  iteration INTEGER NOT NULL DEFAULT 0," ++
    "  attempt INTEGER NOT NULL DEFAULT 0," ++
    "  state TEXT," ++
    "  started_at_ms INTEGER," ++
    "  finished_at_ms INTEGER," ++
    "  heartbeat_at_ms INTEGER," ++
    "  heartbeat_data_json TEXT," ++
    "  error_json TEXT" ++
    ");";

const KEYFRAME_XML =
    \\{"kind":"element","tag":"smithers:workflow","props":{"name":"demo"},"children":[]}
;

fn openDb(path_z: [*:0]const u8) !?*sqlite3 {
    var db: ?*sqlite3 = null;
    if (sqlite3_open(path_z, &db) != SQLITE_OK) {
        _ = sqlite3_close(db);
        return error.DbOpenFailed;
    }
    return db;
}

fn exec(db: ?*sqlite3, sql: [:0]const u8) !void {
    var errmsg: ?[*:0]u8 = null;
    const rc = sqlite3_exec(db, sql.ptr, null, null, &errmsg);
    if (rc != SQLITE_OK) {
        if (errmsg) |msg| sqlite3_free(msg);
        return error.ExecFailed;
    }
}

fn insertFrame(db: ?*sqlite3, run_id: []const u8, frame_no: i64, created_at: i64, xml: []const u8, encoding: []const u8) !void {
    const sql = "INSERT INTO _smithers_frames (run_id, frame_no, created_at_ms, xml_json, encoding, task_index_json) VALUES (?, ?, ?, ?, ?, '[]');";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    _ = sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), null);
    _ = sqlite3_bind_int64(stmt, 2, frame_no);
    _ = sqlite3_bind_int64(stmt, 3, created_at);
    _ = sqlite3_bind_text(stmt, 4, xml.ptr, @intCast(xml.len), null);
    _ = sqlite3_bind_text(stmt, 5, encoding.ptr, @intCast(encoding.len), null);
    if (sqlite3_step(stmt) != SQLITE_DONE) return error.StepFailed;
}

fn setupDb(allocator: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
    const rel = "smithers.db";
    try dir.writeFile(.{ .sub_path = rel, .data = "" });
    const db_path = try dir.realpathAlloc(allocator, rel);
    errdefer allocator.free(db_path);
    const db_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_z);

    const db = (try openDb(db_z.ptr)).?;
    defer _ = sqlite3_close(db);
    try exec(db, SCHEMA);
    try insertFrame(db, "run-1", 0, 1000, KEYFRAME_XML, "keyframe");
    return db_path;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setEnv(key: [*:0]const u8, value: [*:0]const u8) void {
    _ = setenv(key, value, 1);
}

fn unsetEnv(key: [*:0]const u8) void {
    _ = unsetenv(key);
}

fn drainSnapshot(stream: anytype, expected_frame: i64) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const ev = embedded.smithers_event_stream_next(stream);
        if (ev.tag == .json) {
            defer embedded.smithers_event_free(ev);
            const payload = std.mem.sliceTo(ev.payload.ptr.?, 0);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("snapshot", parsed.value.object.get("type").?.string);
            try std.testing.expectEqual(expected_frame, parsed.value.object.get("frameNo").?.integer);
            return;
        }
        embedded.smithers_event_free(ev);
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
    return error.TimedOutWaitingForSnapshot;
}

test "streamDevTools emits initial snapshot with type field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try setupDb(std.testing.allocator, tmp.dir);
    defer std.testing.allocator.free(db_path);

    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);
    setEnv("SMITHERS_DB_PATH", db_path_z.ptr);
    defer unsetEnv("SMITHERS_DB_PATH");
    setEnv("SMITHERS_DEVTOOLS_POLL_MS", "10000");
    defer unsetEnv("SMITHERS_DEVTOOLS_POLL_MS");

    const app = embedded.smithers_app_new(null).?;
    defer embedded.smithers_app_free(app);
    const client = embedded.smithers_client_new(app).?;
    defer embedded.smithers_client_free(client);

    var err: structs.Error = undefined;
    const stream = embedded.smithers_client_stream(client, "streamDevTools", "{\"runId\":\"run-1\"}", &err).?;
    defer embedded.smithers_event_stream_free(stream);
    defer embedded.smithers_error_free(err);
    try std.testing.expectEqual(@as(i32, 0), err.code);

    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const ev = embedded.smithers_event_stream_next(stream);
        if (ev.tag == .json) {
            defer embedded.smithers_event_free(ev);
            const payload = std.mem.sliceTo(ev.payload.ptr.?, 0);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value == .object);
            try std.testing.expectEqualStrings("snapshot", parsed.value.object.get("type").?.string);
            try std.testing.expectEqualStrings("run-1", parsed.value.object.get("runId").?.string);
            const root = parsed.value.object.get("root").?;
            try std.testing.expect(root == .object);
            try std.testing.expectEqualStrings("workflow", root.object.get("type").?.string);
            return;
        }
        embedded.smithers_event_free(ev);
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
    return error.NoSnapshotEvent;
}

test "getDevToolsSnapshot returns flat envelope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try setupDb(std.testing.allocator, tmp.dir);
    defer std.testing.allocator.free(db_path);

    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);
    setEnv("SMITHERS_DB_PATH", db_path_z.ptr);
    defer unsetEnv("SMITHERS_DB_PATH");

    const app = embedded.smithers_app_new(null).?;
    defer embedded.smithers_app_free(app);
    const client = embedded.smithers_client_new(app).?;
    defer embedded.smithers_client_free(client);

    var err: structs.Error = undefined;
    const result = embedded.smithers_client_call(client, "getDevToolsSnapshot", "{\"runId\":\"run-1\"}", &err);
    defer embedded.smithers_string_free(result);
    defer embedded.smithers_error_free(err);
    try std.testing.expectEqual(@as(i32, 0), err.code);

    const payload = std.mem.sliceTo(result.ptr.?, 0);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("run-1", parsed.value.object.get("runId").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("frameNo").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("seq").?.integer);
    try std.testing.expect(parsed.value.object.get("root").? == .object);
    try std.testing.expect(parsed.value.object.get("type") == null);
}

test "streamDevTools pushes additional snapshot when new frame appears" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try setupDb(std.testing.allocator, tmp.dir);
    defer std.testing.allocator.free(db_path);

    const db_path_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);
    setEnv("SMITHERS_DB_PATH", db_path_z.ptr);
    defer unsetEnv("SMITHERS_DB_PATH");
    setEnv("SMITHERS_DEVTOOLS_POLL_MS", "25");
    defer unsetEnv("SMITHERS_DEVTOOLS_POLL_MS");

    const app = embedded.smithers_app_new(null).?;
    defer embedded.smithers_app_free(app);
    const client = embedded.smithers_client_new(app).?;
    defer embedded.smithers_client_free(client);

    var err: structs.Error = undefined;
    const stream = embedded.smithers_client_stream(client, "streamDevTools", "{\"runId\":\"run-1\"}", &err).?;
    defer embedded.smithers_event_stream_free(stream);
    defer embedded.smithers_error_free(err);

    try drainSnapshot(stream, 0);

    // Insert a second keyframe at frame_no=1.
    const db = (try openDb(db_path_z.ptr)).?;
    defer _ = sqlite3_close(db);
    try insertFrame(db, "run-1", 1, 2000, KEYFRAME_XML, "keyframe");

    try drainSnapshot(stream, 1);
}
