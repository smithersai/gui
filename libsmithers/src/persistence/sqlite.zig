const std = @import("std");
const ffi = @import("../ffi.zig");
const structs = @import("../apprt/structs.zig");

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

var sqlite_write_mutex: std.Thread.Mutex = .{};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: ?*sqlite3) c_int;
extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
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
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
extern fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;

pub const Persistence = @This();

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},
db: ?*sqlite3,

pub fn open(allocator: std.mem.Allocator, db_path: []const u8) !*Persistence {
    const path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(path_z);

    var db: ?*sqlite3 = null;
    if (sqlite3_open(path_z.ptr, &db) != SQLITE_OK) {
        defer _ = sqlite3_close(db);
        return error.OpenFailed;
    }
    errdefer _ = sqlite3_close(db);
    if (sqlite3_busy_timeout(db, 5000) != SQLITE_OK) return error.BusyTimeoutFailed;

    const p = try allocator.create(Persistence);
    errdefer allocator.destroy(p);
    p.* = .{ .allocator = allocator, .db = db };

    sqlite_write_mutex.lock();
    defer sqlite_write_mutex.unlock();
    try configureConnection(db);
    try p.ensureSchema();
    return p;
}

pub fn close(self: *Persistence) void {
    self.mutex.lock();
    const db = self.db;
    self.db = null;
    _ = sqlite3_close(db);
    self.mutex.unlock();
    self.allocator.destroy(self);
}

pub fn loadSessions(self: *Persistence, workspace_path: []const u8) structs.String {
    self.mutex.lock();
    defer self.mutex.unlock();
    const sql =
        \\SELECT sessions_json
        \\FROM workspace_sessions
        \\WHERE workspace_path = ?
        \\LIMIT 1;
    ;
    const stmt = self.prepare(sql) catch return ffi.stringDup("[]");
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, workspace_path) != SQLITE_OK) return ffi.stringDup("[]");
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) return ffi.stringDup("[]");
    const text = sqlite3_column_text(stmt, 0) orelse return ffi.stringDup("[]");
    const len: usize = @intCast(sqlite3_column_bytes(stmt, 0));
    return ffi.stringDup(text[0..len]);
}

pub fn saveSessions(self: *Persistence, workspace_path: []const u8, sessions_json: []const u8) structs.Error {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (!isValidJsonArray(sessions_json)) return ffi.errorMessage(2, "sessions_json must be a JSON array");
    sqlite_write_mutex.lock();
    defer sqlite_write_mutex.unlock();
    const sql =
        \\INSERT INTO workspace_sessions (workspace_path, sessions_json, updated_at)
        \\VALUES (?, ?, strftime('%s', 'now'))
        \\ON CONFLICT(workspace_path) DO UPDATE SET
        \\  sessions_json = excluded.sessions_json,
        \\  updated_at = excluded.updated_at;
    ;
    const stmt = self.prepare(sql) catch |err| return ffi.errorFrom("prepare save sessions", err);
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, workspace_path) != SQLITE_OK) return self.lastError();
    if (bindText(stmt, 2, sessions_json) != SQLITE_OK) return self.lastError();
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_DONE) return self.lastError();
    return ffi.errorSuccess();
}

pub const ChatSessionRow = struct {
    session_id: []u8,
    session_json: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub fn loadChatSessions(self: *Persistence, allocator: std.mem.Allocator, workspace_path: []const u8) ![]ChatSessionRow {
    self.mutex.lock();
    defer self.mutex.unlock();
    const sql =
        \\SELECT session_id, session_json, created_at_ms, updated_at_ms
        \\FROM workspace_chat_sessions
        \\WHERE workspace_path = ?
        \\ORDER BY updated_at_ms DESC, created_at_ms DESC;
    ;
    const stmt = try self.prepare(sql);
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, workspace_path) != SQLITE_OK) return error.BindFailed;

    var list: std.ArrayList(ChatSessionRow) = .empty;
    errdefer {
        for (list.items) |row| {
            allocator.free(row.session_id);
            allocator.free(row.session_json);
        }
        list.deinit(allocator);
    }

    while (true) {
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) return error.StepFailed;

        const id_ptr = sqlite3_column_text(stmt, 0) orelse return error.NullColumn;
        const id_len: usize = @intCast(sqlite3_column_bytes(stmt, 0));
        const json_ptr = sqlite3_column_text(stmt, 1) orelse return error.NullColumn;
        const json_len: usize = @intCast(sqlite3_column_bytes(stmt, 1));
        const created_at_ms = sqlite3_column_int64(stmt, 2);
        const updated_at_ms = sqlite3_column_int64(stmt, 3);

        const session_id = try allocator.dupe(u8, id_ptr[0..id_len]);
        errdefer allocator.free(session_id);
        const session_json = try allocator.dupe(u8, json_ptr[0..json_len]);
        errdefer allocator.free(session_json);
        try list.append(allocator, .{
            .session_id = session_id,
            .session_json = session_json,
            .created_at_ms = created_at_ms,
            .updated_at_ms = updated_at_ms,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeChatSessions(allocator: std.mem.Allocator, rows: []ChatSessionRow) void {
    for (rows) |row| {
        allocator.free(row.session_id);
        allocator.free(row.session_json);
    }
    allocator.free(rows);
}

pub fn upsertChatSession(
    self: *Persistence,
    workspace_path: []const u8,
    session_id: []const u8,
    session_json: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (!isValidJsonObject(session_json)) return error.InvalidJson;
    sqlite_write_mutex.lock();
    defer sqlite_write_mutex.unlock();
    const sql =
        \\INSERT INTO workspace_chat_sessions (
        \\  workspace_path,
        \\  session_id,
        \\  session_json,
        \\  created_at_ms,
        \\  updated_at_ms
        \\)
        \\VALUES (?, ?, ?, ?, ?)
        \\ON CONFLICT(workspace_path, session_id) DO UPDATE SET
        \\  session_json = excluded.session_json,
        \\  created_at_ms = excluded.created_at_ms,
        \\  updated_at_ms = excluded.updated_at_ms;
    ;
    const stmt = try self.prepare(sql);
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, workspace_path) != SQLITE_OK) return error.BindFailed;
    if (bindText(stmt, 2, session_id) != SQLITE_OK) return error.BindFailed;
    if (bindText(stmt, 3, session_json) != SQLITE_OK) return error.BindFailed;
    if (sqlite3_bind_int64(stmt, 4, created_at_ms) != SQLITE_OK) return error.BindFailed;
    if (sqlite3_bind_int64(stmt, 5, updated_at_ms) != SQLITE_OK) return error.BindFailed;
    if (sqlite3_step(stmt) != SQLITE_DONE) return error.StepFailed;
}

fn ensureSchema(self: *Persistence) !void {
    const sql =
        \\CREATE TABLE IF NOT EXISTS workspace_sessions (
        \\  workspace_path TEXT PRIMARY KEY NOT NULL,
        \\  sessions_json TEXT NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS workspace_chat_sessions (
        \\  workspace_path TEXT NOT NULL,
        \\  session_id TEXT NOT NULL,
        \\  session_json TEXT NOT NULL,
        \\  created_at_ms INTEGER NOT NULL,
        \\  updated_at_ms INTEGER NOT NULL,
        \\  PRIMARY KEY (workspace_path, session_id)
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_workspace_chat_sessions_restore
        \\ON workspace_chat_sessions(workspace_path, updated_at_ms DESC, created_at_ms DESC);
        \\CREATE TABLE IF NOT EXISTS recent_workspaces (
        \\  path TEXT PRIMARY KEY NOT NULL,
        \\  display_name TEXT NOT NULL,
        \\  last_opened INTEGER NOT NULL,
        \\  sort_key INTEGER NOT NULL DEFAULT 0
        \\);
    ;
    var errmsg: ?[*:0]u8 = null;
    const rc = sqlite3_exec(self.db, sql, null, null, &errmsg);
    if (rc != SQLITE_OK) {
        if (errmsg) |msg| sqlite3_free(msg);
        return error.SchemaFailed;
    }
}

pub const RecentRow = struct {
    path: []u8,
    display_name: []u8,
    last_opened: i64,
};

pub fn loadRecents(self: *Persistence, allocator: std.mem.Allocator) ![]RecentRow {
    self.mutex.lock();
    defer self.mutex.unlock();
    const sql =
        \\SELECT path, display_name, last_opened
        \\FROM recent_workspaces
        \\ORDER BY sort_key DESC, last_opened DESC
        \\LIMIT 20;
    ;
    const stmt = try self.prepare(sql);
    defer _ = sqlite3_finalize(stmt);

    var list: std.ArrayList(RecentRow) = .empty;
    errdefer {
        for (list.items) |row| {
            allocator.free(row.path);
            allocator.free(row.display_name);
        }
        list.deinit(allocator);
    }

    while (true) {
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) return error.StepFailed;
        const path_ptr = sqlite3_column_text(stmt, 0) orelse return error.NullColumn;
        const path_len: usize = @intCast(sqlite3_column_bytes(stmt, 0));
        const display_ptr = sqlite3_column_text(stmt, 1) orelse return error.NullColumn;
        const display_len: usize = @intCast(sqlite3_column_bytes(stmt, 1));
        const last_opened = sqlite3_column_int64(stmt, 2);

        const path = try allocator.dupe(u8, path_ptr[0..path_len]);
        errdefer allocator.free(path);
        const display = try allocator.dupe(u8, display_ptr[0..display_len]);
        errdefer allocator.free(display);
        try list.append(allocator, .{
            .path = path,
            .display_name = display,
            .last_opened = last_opened,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeRecents(allocator: std.mem.Allocator, rows: []RecentRow) void {
    for (rows) |row| {
        allocator.free(row.path);
        allocator.free(row.display_name);
    }
    allocator.free(rows);
}

pub fn upsertRecent(self: *Persistence, path: []const u8, display_name: []const u8, last_opened: i64) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    sqlite_write_mutex.lock();
    defer sqlite_write_mutex.unlock();

    const sort_key = std.time.microTimestamp();
    {
        const sql =
            \\INSERT INTO recent_workspaces (path, display_name, last_opened, sort_key)
            \\VALUES (?, ?, ?, ?)
            \\ON CONFLICT(path) DO UPDATE SET
            \\  display_name = excluded.display_name,
            \\  last_opened = excluded.last_opened,
            \\  sort_key = excluded.sort_key;
        ;
        const stmt = try self.prepare(sql);
        defer _ = sqlite3_finalize(stmt);
        if (bindText(stmt, 1, path) != SQLITE_OK) return error.BindFailed;
        if (bindText(stmt, 2, display_name) != SQLITE_OK) return error.BindFailed;
        if (sqlite3_bind_int64(stmt, 3, last_opened) != SQLITE_OK) return error.BindFailed;
        if (sqlite3_bind_int64(stmt, 4, sort_key) != SQLITE_OK) return error.BindFailed;
        if (sqlite3_step(stmt) != SQLITE_DONE) return error.StepFailed;
    }

    const trim_sql =
        \\DELETE FROM recent_workspaces
        \\WHERE path NOT IN (
        \\  SELECT path FROM recent_workspaces
        \\  ORDER BY sort_key DESC, last_opened DESC
        \\  LIMIT 20
        \\);
    ;
    var errmsg: ?[*:0]u8 = null;
    const rc = sqlite3_exec(self.db, trim_sql, null, null, &errmsg);
    if (rc != SQLITE_OK) {
        if (errmsg) |msg| sqlite3_free(msg);
        return error.StepFailed;
    }
}

pub fn removeRecent(self: *Persistence, path: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    sqlite_write_mutex.lock();
    defer sqlite_write_mutex.unlock();

    const sql = "DELETE FROM recent_workspaces WHERE path = ?;";
    const stmt = try self.prepare(sql);
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, path) != SQLITE_OK) return error.BindFailed;
    if (sqlite3_step(stmt) != SQLITE_DONE) return error.StepFailed;
}

fn configureConnection(db: ?*sqlite3) !void {
    const sql =
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA busy_timeout=5000;
    ;
    var errmsg: ?[*:0]u8 = null;
    const rc = sqlite3_exec(db, sql, null, null, &errmsg);
    if (rc != SQLITE_OK) {
        if (errmsg) |msg| sqlite3_free(msg);
        return error.ConfigureFailed;
    }
}

fn prepare(self: *Persistence, sql: [:0]const u8) !?*sqlite3_stmt {
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    return stmt;
}

fn bindText(stmt: ?*sqlite3_stmt, idx: c_int, value: []const u8) c_int {
    if (value.len == 0) return sqlite3_bind_text(stmt, idx, "", 0, null);
    return sqlite3_bind_text(stmt, idx, value.ptr, @intCast(value.len), null);
}

fn lastError(self: *Persistence) structs.Error {
    const msg = std.mem.sliceTo(sqlite3_errmsg(self.db), 0);
    return ffi.errorMessage(1, msg);
}

fn isValidJsonArray(input: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, ffi.allocator, input, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .array;
}

fn isValidJsonObject(input: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, ffi.allocator, input, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

test "sqlite sessions round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = "sessions.sqlite";
    try tmp.dir.writeFile(.{ .sub_path = rel, .data = "" });
    const db_path = try tmp.dir.realpathAlloc(std.testing.allocator, rel);
    defer std.testing.allocator.free(db_path);

    var p = try Persistence.open(std.testing.allocator, db_path);
    defer p.close();
    const err = p.saveSessions("/tmp/repo", "[{\"id\":\"s1\"}]");
    defer ffi.errorFree(err);
    try std.testing.expectEqual(@as(i32, 0), err.code);
    const loaded = p.loadSessions("/tmp/repo");
    defer ffi.stringFree(loaded);
    try std.testing.expectEqualStrings("[{\"id\":\"s1\"}]", std.mem.sliceTo(loaded.ptr.?, 0));
}

test "sqlite chat sessions round trip without touching workspace sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = "sessions.sqlite";
    try tmp.dir.writeFile(.{ .sub_path = rel, .data = "" });
    const db_path = try tmp.dir.realpathAlloc(std.testing.allocator, rel);
    defer std.testing.allocator.free(db_path);

    var p = try Persistence.open(std.testing.allocator, db_path);
    defer p.close();

    const workspace = "/tmp/repo";
    const legacy_json = "[{\"kind\":\"terminal\",\"terminalTab\":{\"terminalId\":\"term-1\"}}]";
    const save_err = p.saveSessions(workspace, legacy_json);
    defer ffi.errorFree(save_err);
    try std.testing.expectEqual(@as(i32, 0), save_err.code);

    try p.upsertChatSession(
        workspace,
        "chat-1",
        "{\"id\":\"chat-1\",\"kind\":\"chat\",\"title\":\"Chat\",\"workspacePath\":\"/tmp/repo\",\"messages\":[]}",
        100,
        200,
    );

    const loaded_sessions = p.loadSessions(workspace);
    defer ffi.stringFree(loaded_sessions);
    try std.testing.expectEqualStrings(legacy_json, std.mem.sliceTo(loaded_sessions.ptr.?, 0));

    const rows = try p.loadChatSessions(std.testing.allocator, workspace);
    defer Persistence.freeChatSessions(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("chat-1", rows[0].session_id);
}
