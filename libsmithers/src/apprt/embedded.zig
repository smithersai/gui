const std = @import("std");
const structs = @import("structs.zig");
const ffi = @import("../ffi.zig");
const logx = @import("../log.zig");
const App = @import("../App.zig");
const Session = @import("../session/session.zig");
const EventStream = @import("../session/event_stream.zig");
const Client = @import("../client/client.zig");
const Palette = @import("../commands/palette.zig");
const slash = @import("../commands/slash.zig");
const cwd = @import("../workspace/cwd.zig");
const Persistence = @import("../persistence/sqlite.zig");
const obs = @import("../obs.zig");

const log = std.log.scoped(.smithers_core_embedded);

pub export fn smithers_string_free(s: structs.String) void {
    ffi.stringFree(s);
}

pub export fn smithers_error_free(e: structs.Error) void {
    ffi.errorFree(e);
}

pub export fn smithers_bytes_free(b: structs.Bytes) void {
    ffi.bytesFree(b);
}

pub export fn smithers_init(argc: i32, argv: ?[*]?[*:0]u8) i32 {
    _ = argc;
    _ = argv;
    return 0;
}

pub export fn smithers_info() structs.Info {
    return .{
        .version = "0.1.0",
        .commit = "unknown",
        .platform = structs.nativePlatform(),
    };
}

pub export fn smithers_app_new(cfg: ?*const structs.RuntimeConfig) ?*App {
    log.debug("ffi smithers_app_new", .{});
    const t = logx.startTimer();
    const runtime = if (cfg) |ptr| ptr.* else structs.RuntimeConfig{};
    const result = App.create(ffi.allocator, runtime) catch |err| {
        logx.catchErr(log, "smithers_app_new", err);
        obs.record(.err, "smithers_core_embedded", "app_new", t.elapsedMs(), "{\"ok\":false}");
        return null;
    };
    obs.record(.info, "smithers_core_embedded", "app_new", t.elapsedMs(), "{\"ok\":true}");
    return result;
}

pub export fn smithers_app_free(app: ?*App) void {
    if (app) |ptr| ptr.destroy();
}

pub export fn smithers_app_tick(app: ?*App) void {
    if (app) |ptr| ptr.tick();
}

pub export fn smithers_app_userdata(app: ?*App) ?*anyopaque {
    return if (app) |ptr| ptr.userdata() else null;
}

pub export fn smithers_app_set_color_scheme(app: ?*App, scheme: structs.ColorScheme) void {
    if (app) |ptr| ptr.setColorScheme(scheme);
}

pub export fn smithers_app_open_workspace(app: ?*App, path: ?[*:0]const u8) ?*App.Workspace {
    const ptr = app orelse {
        log.warn("smithers_app_open_workspace: app is null", .{});
        return null;
    };
    const raw = ffi.spanZ(path);
    log.debug("ffi smithers_app_open_workspace path={s}", .{raw});
    return ptr.openWorkspace(raw) catch |err| {
        logx.catchWarn(log, "smithers_app_open_workspace", err);
        return null;
    };
}

pub export fn smithers_app_close_workspace(app: ?*App, ws: ?*App.Workspace) void {
    if (app) |a| if (ws) |w| a.closeWorkspace(w);
}

pub export fn smithers_app_active_workspace_path(app: ?*App) structs.String {
    return if (app) |ptr| ptr.activeWorkspacePathString() else ffi.stringDup("");
}

pub export fn smithers_app_recent_workspaces_json(app: ?*App) structs.String {
    return if (app) |ptr| ptr.recentWorkspacesJson() else ffi.stringDup("[]");
}

pub export fn smithers_app_remove_recent_workspace(app: ?*App, path: ?[*:0]const u8) void {
    const ptr = app orelse return;
    ptr.removeRecent(ffi.spanZ(path));
}

pub export fn smithers_session_new(app: ?*App, opts: structs.SessionOptions) ?*Session {
    const ptr = app orelse {
        log.warn("smithers_session_new: app is null", .{});
        obs.record(.warn, "smithers_core_embedded", "session_new", null, "{\"err\":\"app_null\"}");
        return null;
    };
    log.debug("ffi smithers_session_new kind={}", .{@intFromEnum(opts.kind)});
    const t = logx.startTimer();
    const result = Session.create(ptr, opts) catch |err| {
        logx.catchWarn(log, "smithers_session_new", err);
        var fbuf: [128]u8 = undefined;
        const f = std.fmt.bufPrint(&fbuf, "{{\"kind\":{d},\"ok\":false}}", .{@intFromEnum(opts.kind)}) catch null;
        obs.record(.err, "smithers_core_embedded", "session_new", t.elapsedMs(), f);
        return null;
    };
    var fbuf: [128]u8 = undefined;
    const f = std.fmt.bufPrint(&fbuf, "{{\"kind\":{d},\"ok\":true}}", .{@intFromEnum(opts.kind)}) catch null;
    obs.record(.info, "smithers_core_embedded", "session_new", t.elapsedMs(), f);
    obs.incrementCounter("session.created", 1);
    return result;
}

pub export fn smithers_session_free(session: ?*Session) void {
    if (session) |ptr| {
        ptr.destroy();
        obs.record(.debug, "smithers_core_embedded", "session_free", null, null);
        obs.incrementCounter("session.destroyed", 1);
    }
}

pub export fn smithers_session_kind(session: ?*Session) structs.SessionKind {
    return if (session) |ptr| ptr.kind() else .terminal;
}

pub export fn smithers_session_userdata(session: ?*Session) ?*anyopaque {
    return if (session) |ptr| ptr.userdata() else null;
}

pub export fn smithers_session_title(session: ?*Session) structs.String {
    return if (session) |ptr| ptr.title() else ffi.stringDup("");
}

pub export fn smithers_session_send_text(session: ?*Session, text: ?[*]const u8, len: usize) void {
    const ptr = session orelse return;
    const raw_ptr = text orelse return;
    ptr.sendText(raw_ptr[0..len]);
}

pub export fn smithers_session_events(session: ?*Session) ?*EventStream {
    return if (session) |ptr| ptr.events() else null;
}

pub export fn smithers_event_stream_next(stream: ?*EventStream) structs.Event {
    return if (stream) |ptr| ptr.next() else .{ .tag = .none, .payload = ffi.emptyString() };
}

pub export fn smithers_event_free(ev: structs.Event) void {
    ffi.stringFree(ev.payload);
}

pub export fn smithers_event_stream_free(stream: ?*EventStream) void {
    if (stream) |ptr| ptr.destroy();
}

pub export fn smithers_client_new(app: ?*App) ?*Client {
    const ptr = app orelse {
        log.warn("smithers_client_new: app is null", .{});
        return null;
    };
    log.debug("ffi smithers_client_new", .{});
    return Client.create(ptr) catch |err| {
        logx.catchWarn(log, "smithers_client_new", err);
        return null;
    };
}

pub export fn smithers_client_free(client: ?*Client) void {
    if (client) |ptr| ptr.destroy();
}

pub export fn smithers_client_call(
    client: ?*Client,
    method: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    out_err: ?*structs.Error,
) structs.String {
    const ptr = client orelse {
        log.debug("smithers_client_call: client is null", .{});
        if (out_err) |err| err.* = ffi.errorMessage(1, "client is null");
        return ffi.stringDup("null");
    };
    const method_slice = ffi.spanZ(method);
    log.debug("ffi smithers_client_call method={s}", .{method_slice});
    const t = logx.startTimer();
    const result = ptr.call(method_slice, ffi.spanZ(args_json), out_err);
    const is_error = if (out_err) |err| err.code != 0 else false;
    // Record both a generic span and a per-method observation. The per-method
    // observation uses a stable "client.call.<method>" key so the metrics
    // snapshot can show p50/max latency by RPC.
    var fbuf: [192]u8 = undefined;
    const fields = std.fmt.bufPrint(&fbuf, "{{\"method\":\"{s}\",\"err\":{}}}", .{ method_slice, is_error }) catch null;
    obs.record(if (is_error) .warn else .debug, "smithers_core_ffi", "client_call", t.elapsedMs(), fields);
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "client.call.{s}", .{method_slice}) catch "client.call.unknown";
    obs.recordMethod(key, t.elapsedMs(), is_error);
    return result;
}

pub export fn smithers_client_stream(
    client: ?*Client,
    method: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    out_err: ?*structs.Error,
) ?*EventStream {
    const ptr = client orelse {
        log.debug("smithers_client_stream: client is null", .{});
        if (out_err) |err| err.* = ffi.errorMessage(1, "client is null");
        return null;
    };
    const method_slice = ffi.spanZ(method);
    log.debug("ffi smithers_client_stream method={s}", .{method_slice});
    const t = logx.startTimer();
    const result = ptr.stream(method_slice, ffi.spanZ(args_json), out_err);
    const is_error = result == null or (if (out_err) |err| err.code != 0 else false);
    var fbuf: [192]u8 = undefined;
    const fields = std.fmt.bufPrint(&fbuf, "{{\"method\":\"{s}\",\"err\":{}}}", .{ method_slice, is_error }) catch null;
    obs.record(if (is_error) .warn else .info, "smithers_core_ffi", "client_stream_open", t.elapsedMs(), fields);
    obs.incrementCounter(if (is_error) "client.stream_open.error" else "client.stream_open.ok", 1);
    return result;
}

pub export fn smithers_palette_new(app: ?*App) ?*Palette {
    const ptr = app orelse {
        log.warn("smithers_palette_new: app is null", .{});
        return null;
    };
    log.debug("ffi smithers_palette_new", .{});
    return Palette.create(ptr) catch |err| {
        logx.catchWarn(log, "smithers_palette_new", err);
        return null;
    };
}

pub export fn smithers_palette_free(palette: ?*Palette) void {
    if (palette) |ptr| ptr.destroy();
}

pub export fn smithers_palette_set_mode(palette: ?*Palette, mode: structs.PaletteMode) void {
    if (palette) |ptr| ptr.setMode(mode);
}

pub export fn smithers_palette_set_query(palette: ?*Palette, query: ?[*:0]const u8) void {
    if (palette) |ptr| ptr.setQuery(ffi.spanZ(query));
}

pub export fn smithers_palette_items_json(palette: ?*Palette) structs.String {
    return if (palette) |ptr| ptr.itemsJson() else ffi.stringDup("[]");
}

pub export fn smithers_palette_activate(palette: ?*Palette, item_id: ?[*:0]const u8) structs.Error {
    const ptr = palette orelse {
        log.warn("smithers_palette_activate: palette is null", .{});
        return ffi.errorMessage(1, "palette is null");
    };
    const id_slice = ffi.spanZ(item_id);
    log.debug("ffi smithers_palette_activate item_id={s}", .{id_slice});
    return ptr.activate(id_slice);
}

pub export fn smithers_slashcmd_parse(input: ?[*:0]const u8) structs.String {
    const input_slice = ffi.spanZ(input);
    log.debug("ffi smithers_slashcmd_parse input_len={d}", .{input_slice.len});
    const json = slash.parseJson(input_slice) catch |err| {
        logx.catchWarn(log, "smithers_slashcmd_parse", err);
        return ffi.stringDup("{\"command\":null,\"args\":[],\"mode\":\"error\"}");
    };
    defer ffi.allocator.free(json);
    return ffi.stringDup(json);
}

pub export fn smithers_cwd_resolve(requested: ?[*:0]const u8) structs.String {
    log.debug("ffi smithers_cwd_resolve", .{});
    const resolved = cwd.resolveC(requested) catch |err| {
        logx.catchWarn(log, "smithers_cwd_resolve", err);
        return ffi.stringDup("");
    };
    defer ffi.allocator.free(resolved);
    return ffi.stringDup(resolved);
}

pub export fn smithers_persistence_open(db_path: ?[*:0]const u8, out_err: ?*structs.Error) ?*Persistence {
    if (out_err) |err| err.* = ffi.errorSuccess();
    const path_slice = ffi.spanZ(db_path);
    log.info("ffi smithers_persistence_open path={s}", .{path_slice});
    const p = Persistence.open(ffi.allocator, path_slice) catch |err| {
        logx.catchDebug(log, "smithers_persistence_open", err);
        if (out_err) |out| out.* = ffi.errorFrom("persistence open", err);
        return null;
    };
    return p;
}

pub export fn smithers_persistence_close(p: ?*Persistence) void {
    if (p) |ptr| ptr.close();
}

pub export fn smithers_persistence_load_sessions(p: ?*Persistence, workspace_path: ?[*:0]const u8) structs.String {
    return if (p) |ptr| ptr.loadSessions(ffi.spanZ(workspace_path)) else ffi.stringDup("[]");
}

pub export fn smithers_persistence_save_sessions(
    p: ?*Persistence,
    workspace_path: ?[*:0]const u8,
    sessions_json: ?[*:0]const u8,
) structs.Error {
    return if (p) |ptr|
        ptr.saveSessions(ffi.spanZ(workspace_path), ffi.spanZ(sessions_json))
    else
        ffi.errorMessage(1, "persistence is null");
}

test {
    _ = smithers_info;
}
