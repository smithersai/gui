const std = @import("std");
const logx = @import("../log.zig");

const log = std.log.scoped(.smithers_core_chat_output);

const Value = std.json.Value;

/// Truncate a JSON fragment to `max_len` bytes, replacing CR/LF with spaces,
/// so it is safe to embed in a single-line log message.
fn jsonSnippet(buf: []u8, src: []const u8) []const u8 {
    const n = @min(buf.len, src.len);
    for (src[0..n], 0..) |c, i| {
        buf[i] = switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        };
    }
    return buf[0..n];
}

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_NULL: c_int = 5;
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

pub const Error = error{
    DbOpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
} || std.mem.Allocator.Error;

pub const Block = struct {
    stable_id: []u8,
    run_id: []u8,
    node_id: []u8,
    iteration: i64,
    attempt: i64,
    role: []const u8, // borrowed string literal
    content: []u8,
    timestamp_ms: i64,

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        allocator.free(self.stable_id);
        allocator.free(self.run_id);
        allocator.free(self.node_id);
        allocator.free(self.content);
    }
};

pub fn freeBlocks(allocator: std.mem.Allocator, blocks: []Block) void {
    for (blocks) |*b| b.deinit(allocator);
    allocator.free(blocks);
}

/// Build and return JSON: {"blocks":[ChatBlock,...]}
pub fn loadChatOutputJson(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    run_id: []const u8,
) ![]u8 {
    const blocks = try loadBlocks(allocator, db_path, run_id, -1);
    defer freeBlocks(allocator, blocks);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"blocks\":[");
    for (blocks, 0..) |b, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try writeBlockJson(&out.writer, b);
    }
    try out.writer.writeAll("]}");
    return try allocator.dupe(u8, out.written());
}

/// Load chat blocks for a run. If `after_seq >= 0`, only returns blocks
/// that were produced by events with seq > after_seq OR by attempts that
/// started after any previously-seen attempt. Prompt/response_text blocks
/// for attempts are always included when after_seq < 0 (initial load) and
/// skipped when after_seq >= 0 (they are stable and already emitted).
pub fn loadBlocks(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    run_id: []const u8,
    after_seq: i64,
) ![]Block {
    const path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(path_z);

    var db: ?*sqlite3 = null;
    if (sqlite3_open_v2(path_z.ptr, &db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) {
        _ = sqlite3_close(db);
        return error.DbOpenFailed;
    }
    defer _ = sqlite3_close(db);
    _ = sqlite3_busy_timeout(db, 5000);

    const attempts = try loadAttempts(allocator, db, run_id);
    defer freeAttempts(allocator, attempts);

    const events = try loadEvents(allocator, db, run_id, after_seq);
    defer freeEvents(allocator, events);

    // Build a set of attempt keys that have events (to decide "agent attempts")
    var keys_with_events = std.StringHashMap(void).init(allocator);
    defer {
        var it = keys_with_events.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        keys_with_events.deinit();
    }
    for (events) |ev| {
        var parsed = (parseEvent(allocator, ev) catch |err| {
            logx.catchDebug(log, "parseEvent(key-pass)", err);
            continue;
        }) orelse continue;
        defer parsed.deinit(allocator);
        const key = try std.fmt.allocPrint(allocator, "{s}:{}:{}", .{ parsed.node_id, parsed.iteration, parsed.attempt });
        if (!keys_with_events.contains(key)) {
            try keys_with_events.put(key, {});
        } else {
            allocator.free(key);
        }
    }

    var list: std.ArrayList(Block) = .empty;
    errdefer {
        for (list.items) |*b| b.deinit(allocator);
        list.deinit(allocator);
    }

    // Track per-attempt: did we emit any stdout block? Used to decide fallback.
    var stdout_seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = stdout_seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        stdout_seen.deinit();
    }

    // First pass: emit prompt blocks for agent attempts (only on initial load).
    if (after_seq < 0) {
        for (attempts) |a| {
            if (!isAgentAttempt(a, &keys_with_events)) continue;
            const prompt = extractPromptFromMeta(a.meta_json) orelse continue;
            if (prompt.len == 0) continue;
            const stable = try std.fmt.allocPrint(
                allocator,
                "prompt:{s}:{}:{}",
                .{ a.node_id, a.iteration, a.attempt },
            );
            const content = try allocator.dupe(u8, prompt);
            try list.append(allocator, .{
                .stable_id = stable,
                .run_id = try allocator.dupe(u8, run_id),
                .node_id = try allocator.dupe(u8, a.node_id),
                .iteration = a.iteration,
                .attempt = a.attempt,
                .role = "user",
                .content = content,
                .timestamp_ms = a.started_at_ms,
            });
        }
    }

    // Second pass: emit event-derived blocks.
    for (events) |ev| {
        var parsed = (parseEvent(allocator, ev) catch |err| {
            logx.catchDebug(log, "parseEvent(emit-pass)", err);
            continue;
        }) orelse continue;
        defer parsed.deinit(allocator);
        const role: []const u8 = if (std.mem.eql(u8, parsed.stream, "stderr")) "stderr" else "assistant";
        if (std.mem.eql(u8, parsed.stream, "stdout")) {
            const k = try std.fmt.allocPrint(allocator, "{s}:{}:{}", .{ parsed.node_id, parsed.iteration, parsed.attempt });
            if (!stdout_seen.contains(k)) {
                try stdout_seen.put(k, {});
            } else {
                allocator.free(k);
            }
        }
        const stable = try std.fmt.allocPrint(allocator, "event:{}", .{ev.seq});
        try list.append(allocator, .{
            .stable_id = stable,
            .run_id = try allocator.dupe(u8, run_id),
            .node_id = try allocator.dupe(u8, parsed.node_id),
            .iteration = parsed.iteration,
            .attempt = parsed.attempt,
            .role = role,
            .content = try allocator.dupe(u8, parsed.text),
            .timestamp_ms = ev.timestamp_ms,
        });
    }

    // Third pass: fallback response_text blocks (only on initial load).
    if (after_seq < 0) {
        for (attempts) |a| {
            if (!isAgentAttempt(a, &keys_with_events)) continue;
            const resp = a.response_text orelse continue;
            if (trimmedLen(resp) == 0) continue;
            const key = try std.fmt.allocPrint(allocator, "{s}:{}:{}", .{ a.node_id, a.iteration, a.attempt });
            defer allocator.free(key);
            if (stdout_seen.contains(key)) continue;
            const stable = try std.fmt.allocPrint(
                allocator,
                "response:{s}:{}:{}",
                .{ a.node_id, a.iteration, a.attempt },
            );
            try list.append(allocator, .{
                .stable_id = stable,
                .run_id = try allocator.dupe(u8, run_id),
                .node_id = try allocator.dupe(u8, a.node_id),
                .iteration = a.iteration,
                .attempt = a.attempt,
                .role = "assistant",
                .content = try allocator.dupe(u8, std.mem.trim(u8, resp, &std.ascii.whitespace)),
                .timestamp_ms = a.finished_at_ms orelse a.started_at_ms,
            });
        }
    }

    const slice = try list.toOwnedSlice(allocator);
    std.sort.pdq(Block, slice, {}, lessThanBlock);
    return slice;
}

fn lessThanBlock(_: void, a: Block, b: Block) bool {
    if (a.timestamp_ms != b.timestamp_ms) return a.timestamp_ms < b.timestamp_ms;
    return std.mem.order(u8, a.stable_id, b.stable_id) == .lt;
}

fn trimmedLen(s: []const u8) usize {
    return std.mem.trim(u8, s, &std.ascii.whitespace).len;
}

// ---- Attempt row loading ----

const AttemptRow = struct {
    node_id: []u8,
    iteration: i64,
    attempt: i64,
    state: []u8,
    started_at_ms: i64,
    finished_at_ms: ?i64,
    response_text: ?[]u8,
    meta_json: ?[]u8,
};

fn freeAttempts(allocator: std.mem.Allocator, rows: []AttemptRow) void {
    for (rows) |r| {
        allocator.free(r.node_id);
        allocator.free(r.state);
        if (r.response_text) |t| allocator.free(t);
        if (r.meta_json) |t| allocator.free(t);
    }
    allocator.free(rows);
}

fn loadAttempts(allocator: std.mem.Allocator, db: ?*sqlite3, run_id: []const u8) ![]AttemptRow {
    const sql =
        "SELECT node_id, iteration, attempt, state, started_at_ms, finished_at_ms, response_text, meta_json" ++
        " FROM _smithers_attempts WHERE run_id=? ORDER BY started_at_ms ASC;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, run_id) != SQLITE_OK) return error.BindFailed;

    var list: std.ArrayList(AttemptRow) = .empty;
    errdefer {
        for (list.items) |r| {
            allocator.free(r.node_id);
            allocator.free(r.state);
            if (r.response_text) |t| allocator.free(t);
            if (r.meta_json) |t| allocator.free(t);
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
        const resp = try dupColumnText(allocator, stmt, 6);
        errdefer if (resp) |t| allocator.free(t);
        const meta = try dupColumnText(allocator, stmt, 7);
        errdefer if (meta) |t| allocator.free(t);
        try list.append(allocator, .{
            .node_id = node_id,
            .iteration = iteration,
            .attempt = attempt,
            .state = state,
            .started_at_ms = started,
            .finished_at_ms = finished,
            .response_text = resp,
            .meta_json = meta,
        });
    }
    return try list.toOwnedSlice(allocator);
}

// ---- Event row loading ----

const EventRow = struct {
    seq: i64,
    timestamp_ms: i64,
    type_str: []u8,
    payload_json: []u8,
};

fn freeEvents(allocator: std.mem.Allocator, rows: []EventRow) void {
    for (rows) |r| {
        allocator.free(r.type_str);
        allocator.free(r.payload_json);
    }
    allocator.free(rows);
}

fn loadEvents(allocator: std.mem.Allocator, db: ?*sqlite3, run_id: []const u8, after_seq: i64) ![]EventRow {
    const sql = if (after_seq < 0)
        "SELECT seq, timestamp_ms, type, payload_json FROM _smithers_events" ++
            " WHERE run_id=? AND type IN ('NodeOutput','AgentEvent') ORDER BY seq ASC;"
    else
        "SELECT seq, timestamp_ms, type, payload_json FROM _smithers_events" ++
            " WHERE run_id=? AND seq>? AND type IN ('NodeOutput','AgentEvent') ORDER BY seq ASC;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, run_id) != SQLITE_OK) return error.BindFailed;
    if (after_seq >= 0) {
        if (sqlite3_bind_int64(stmt, 2, after_seq) != SQLITE_OK) return error.BindFailed;
    }

    var list: std.ArrayList(EventRow) = .empty;
    errdefer {
        for (list.items) |r| {
            allocator.free(r.type_str);
            allocator.free(r.payload_json);
        }
        list.deinit(allocator);
    }

    while (true) {
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) return error.StepFailed;
        const seq = sqlite3_column_int64(stmt, 0);
        const ts = sqlite3_column_int64(stmt, 1);
        const type_str = try dupColumnText(allocator, stmt, 2) orelse continue;
        errdefer allocator.free(type_str);
        const payload = try dupColumnText(allocator, stmt, 3) orelse try allocator.dupe(u8, "{}");
        errdefer allocator.free(payload);
        try list.append(allocator, .{
            .seq = seq,
            .timestamp_ms = ts,
            .type_str = type_str,
            .payload_json = payload,
        });
    }
    return try list.toOwnedSlice(allocator);
}

// ---- Event parsing ----

const ParsedEvent = struct {
    seq: i64,
    timestamp_ms: i64,
    node_id: []u8,
    iteration: i64,
    attempt: i64,
    stream: []const u8, // "stdout" or "stderr"
    text: []u8,

    fn deinit(self: *ParsedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.text);
    }
};

fn parseEvent(allocator: std.mem.Allocator, ev: EventRow) !?ParsedEvent {
    var parsed = std.json.parseFromSlice(Value, allocator, ev.payload_json, .{}) catch |err| {
        var buf: [80]u8 = undefined;
        const snippet = jsonSnippet(&buf, ev.payload_json);
        log.warn("parseEvent json failed seq={d} type={s} err={s} snippet=\"{s}\"", .{ ev.seq, ev.type_str, @errorName(err), snippet });
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const node_id_val = obj.get("nodeId") orelse return null;
    const node_id_str = if (node_id_val == .string) node_id_val.string else return null;
    const iteration = intFromValue(obj.get("iteration")) orelse 0;
    const attempt = intFromValue(obj.get("attempt")) orelse 1;

    if (std.mem.eql(u8, ev.type_str, "NodeOutput")) {
        const text_val = obj.get("text") orelse return null;
        if (text_val != .string or text_val.string.len == 0) return null;
        const stream_val = obj.get("stream");
        const stream_str: []const u8 = blk: {
            if (stream_val) |sv| if (sv == .string) {
                if (std.mem.eql(u8, sv.string, "stderr")) break :blk "stderr";
            };
            break :blk "stdout";
        };
        return .{
            .seq = ev.seq,
            .timestamp_ms = ev.timestamp_ms,
            .node_id = try allocator.dupe(u8, node_id_str),
            .iteration = iteration,
            .attempt = attempt,
            .stream = stream_str,
            .text = try allocator.dupe(u8, text_val.string),
        };
    }

    if (std.mem.eql(u8, ev.type_str, "AgentEvent")) {
        const event_val = obj.get("event") orelse return null;
        if (event_val != .object) return null;
        const ev_obj = event_val.object;
        const ev_type = (ev_obj.get("type") orelse return null);
        if (ev_type != .string or !std.mem.eql(u8, ev_type.string, "action")) return null;
        const phase_opt = ev_obj.get("phase");
        const phase: []const u8 = if (phase_opt) |p| (if (p == .string) p.string else "") else "";
        const action_val = ev_obj.get("action") orelse return null;
        if (action_val != .object) return null;
        const action = action_val.object;
        const kind: []const u8 = blk: {
            const k = action.get("kind") orelse break :blk "unknown";
            if (k == .string) break :blk k.string;
            break :blk "unknown";
        };
        const title: []const u8 = blk: {
            const t = action.get("title") orelse break :blk "";
            if (t == .string) break :blk t.string;
            break :blk "";
        };
        const message: []const u8 = blk: {
            const m = ev_obj.get("message") orelse break :blk "";
            if (m == .string) break :blk m.string;
            break :blk "";
        };
        const entry_type: []const u8 = blk: {
            const e = ev_obj.get("entryType") orelse break :blk "";
            if (e == .string) break :blk e.string;
            break :blk "";
        };
        const detail_val = action.get("detail");
        const detail_obj: ?std.json.ObjectMap = blk: {
            if (detail_val) |dv| if (dv == .object) break :blk dv.object;
            break :blk null;
        };

        const text = buildAgentActionText(allocator, kind, phase, title, message, entry_type, detail_obj) catch |err| {
            logx.catchWarn(log, "buildAgentActionText", err);
            return null;
        };
        if (text.len == 0) {
            allocator.free(text);
            return null;
        }
        return .{
            .seq = ev.seq,
            .timestamp_ms = ev.timestamp_ms,
            .node_id = try allocator.dupe(u8, node_id_str),
            .iteration = iteration,
            .attempt = attempt,
            .stream = "stdout",
            .text = text,
        };
    }

    return null;
}

fn buildAgentActionText(
    allocator: std.mem.Allocator,
    kind: []const u8,
    phase: []const u8,
    title: []const u8,
    message: []const u8,
    entry_type: []const u8,
    detail: ?std.json.ObjectMap,
) ![]u8 {
    if (std.mem.eql(u8, kind, "tool") or std.mem.eql(u8, kind, "command")) {
        if (std.mem.eql(u8, phase, "started")) {
            var input_buf: ?[]u8 = null;
            defer if (input_buf) |b| allocator.free(b);
            if (detail) |d| if (d.get("input")) |inp| {
                input_buf = try jsonStringify(allocator, inp);
            };
            if (input_buf) |ib| {
                if (ib.len > 0) {
                    const truncated = try truncate(allocator, ib, 200);
                    defer allocator.free(truncated);
                    return try std.fmt.allocPrint(allocator, "[tool] {s}: {s}", .{ title, truncated });
                }
            }
            return try std.fmt.allocPrint(allocator, "[tool] {s}", .{title});
        }
        if (std.mem.eql(u8, phase, "completed")) {
            var output_src: []const u8 = "";
            var owned: ?[]u8 = null;
            defer if (owned) |o| allocator.free(o);
            if (detail) |d| if (d.get("output")) |out| {
                if (out == .string) {
                    output_src = out.string;
                } else {
                    owned = try jsonStringify(allocator, out);
                    output_src = owned.?;
                }
            };
            if (output_src.len == 0) output_src = message;
            if (output_src.len == 0) output_src = "done";
            const truncated = try truncate(allocator, output_src, 200);
            defer allocator.free(truncated);
            return try std.fmt.allocPrint(allocator, "[tool] {s} → {s}", .{ title, truncated });
        }
        return try allocator.dupe(u8, "");
    }
    if (std.mem.eql(u8, kind, "file_change")) {
        if (detail) |d| if (d.get("changes")) |ch| if (ch == .array) {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(allocator);
            try list.appendSlice(allocator, "[file_change] ");
            for (ch.array.items, 0..) |item, i| {
                if (i > 0) try list.appendSlice(allocator, ", ");
                if (item == .object) {
                    const t = blk: {
                        const v = item.object.get("type") orelse break :blk "change";
                        if (v == .string) break :blk v.string;
                        break :blk "change";
                    };
                    const f = blk: {
                        if (item.object.get("file")) |v| if (v == .string) break :blk v.string;
                        if (item.object.get("path")) |v| if (v == .string) break :blk v.string;
                        break :blk "?";
                    };
                    try list.writer(allocator).print("{s}: {s}", .{ t, f });
                }
            }
            return try allocator.dupe(u8, list.items);
        };
        const label = if (title.len > 0) title else if (message.len > 0) message else "files changed";
        return try std.fmt.allocPrint(allocator, "[file_change] {s}", .{label});
    }
    if (std.mem.eql(u8, kind, "reasoning")) {
        if (message.len == 0) return try allocator.dupe(u8, "");
        const truncated = try truncate(allocator, message, 300);
        defer allocator.free(truncated);
        return try std.fmt.allocPrint(allocator, "[reasoning] {s}", .{truncated});
    }
    if (std.mem.eql(u8, kind, "note") and std.mem.eql(u8, entry_type, "thought")) {
        if (message.len == 0) return try allocator.dupe(u8, "");
        const truncated = try truncate(allocator, message, 300);
        defer allocator.free(truncated);
        return try std.fmt.allocPrint(allocator, "[thought] {s}", .{truncated});
    }
    if (std.mem.eql(u8, kind, "web_search")) {
        const label = if (title.len > 0) title else if (message.len > 0) message else "searching";
        return try std.fmt.allocPrint(allocator, "[web_search] {s}", .{label});
    }
    return try allocator.dupe(u8, "");
}

fn truncate(allocator: std.mem.Allocator, s: []const u8, max: usize) ![]u8 {
    if (s.len <= max) return try allocator.dupe(u8, s);
    const ellipsis = "…";
    var out = try allocator.alloc(u8, max + ellipsis.len);
    @memcpy(out[0..max], s[0..max]);
    @memcpy(out[max..], ellipsis);
    return out;
}

fn jsonStringify(allocator: std.mem.Allocator, v: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(v, .{}, &out.writer);
    return try allocator.dupe(u8, out.written());
}

fn intFromValue(v: ?Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

// ---- Agent-attempt predicate ----

fn isAgentAttempt(a: AttemptRow, keys_with_events: *std.StringHashMap(void)) bool {
    if (metaKindIsAgent(a.meta_json)) return true;
    if (a.response_text) |t| if (trimmedLen(t) > 0) return true;
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}:{}:{}", .{ a.node_id, a.iteration, a.attempt }) catch return false;
    return keys_with_events.contains(key);
}

fn metaKindIsAgent(meta: ?[]const u8) bool {
    const m = meta orelse return false;
    if (m.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSlice(Value, arena.allocator(), m, .{}) catch |err| {
        var buf: [80]u8 = undefined;
        const snippet = jsonSnippet(&buf, m);
        log.debug("metaKindIsAgent parse failed err={s} snippet=\"{s}\"", .{ @errorName(err), snippet });
        return false;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const kind = parsed.value.object.get("kind") orelse return false;
    if (kind != .string) return false;
    return std.mem.eql(u8, kind.string, "agent");
}

fn extractPromptFromMeta(meta: ?[]const u8) ?[]const u8 {
    const m = meta orelse return null;
    if (m.len == 0) return null;
    // Use page allocator for a throwaway parse; we only need to return a
    // slice that lives as long as the caller's `meta` buffer — but the
    // parsed string is copied into arena. So we dupe into a static buffer
    // via allocPrint? No — caller dupes. Let's parse and copy.
    // Simpler: scan for "prompt":"..." manually. But handling escapes is
    // hard. Instead, parse and copy out into caller allocator via caller.
    // Since this function returns a borrow, let's just do manual scan for
    // the JSON string. Fallback: return null on failure.
    return extractJsonStringField(m, "prompt");
}

/// Scan `json` for the first occurrence of `"<field>":"..."` and return the
/// decoded string value. Returns null if not found or on decode failure.
/// The returned slice points into a thread-local buffer — caller must copy
/// before the next call. For correctness we actually allocate via
/// page_allocator and leak; callers always dupe immediately. To avoid
/// leaking we instead return a slice into the source after unescaping in
/// place-free style: only handles simple strings without backslash escapes.
/// If the value contains escapes we fall back to std.json.
fn extractJsonStringField(json: []const u8, field: []const u8) ?[]const u8 {
    // Build the needle "field":"
    var needle_buf: [64]u8 = undefined;
    if (field.len + 4 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = idx + needle.len;
    const start = i;
    var has_escape = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (c == '\\') {
            has_escape = true;
            i += 1;
            continue;
        }
        if (c == '"') break;
    }
    if (i >= json.len) return null;
    if (!has_escape) return json[start..i];

    // Fallback: full JSON parse into a static TLS buffer (leaks per call but
    // bounded; meta is small). To avoid per-call leaks, we use a small TLS
    // arena reset on each call.
    return extractWithParser(json, field);
}

threadlocal var prompt_scratch: [16 * 1024]u8 = undefined;
threadlocal var prompt_scratch_len: usize = 0;

fn extractWithParser(json: []const u8, field: []const u8) ?[]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(&prompt_scratch);
    const alloc = fba.allocator();
    var parsed = std.json.parseFromSlice(Value, alloc, json, .{}) catch |err| {
        var buf: [80]u8 = undefined;
        const snippet = jsonSnippet(&buf, json);
        log.debug("extractWithParser field={s} err={s} snippet=\"{s}\"", .{ field, @errorName(err), snippet });
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get(field) orelse return null;
    if (v != .string) return null;
    // Copy into the scratch region past the parser's usage (we keep the
    // alloc; the caller immediately dupes).
    const start = fba.end_index;
    if (start + v.string.len > prompt_scratch.len) return null;
    @memcpy(prompt_scratch[start .. start + v.string.len], v.string);
    prompt_scratch_len = start + v.string.len;
    return prompt_scratch[start..prompt_scratch_len];
}

// ---- JSON writing ----

pub fn writeBlockJson(writer: anytype, b: Block) !void {
    try writer.writeAll("{\"id\":null");
    try writer.print(",\"itemId\":{f}", .{std.json.fmt(b.stable_id, .{})});
    try writer.print(",\"runId\":{f}", .{std.json.fmt(b.run_id, .{})});
    try writer.print(",\"nodeId\":{f}", .{std.json.fmt(b.node_id, .{})});
    try writer.print(",\"attempt\":{}", .{b.attempt});
    try writer.print(",\"role\":{f}", .{std.json.fmt(b.role, .{})});
    try writer.print(",\"content\":{f}", .{std.json.fmt(b.content, .{})});
    try writer.print(",\"timestampMs\":{}", .{b.timestamp_ms});
    try writer.writeAll("}");
}

// ---- Helpers (shared with Snapshot.zig in spirit) ----

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
