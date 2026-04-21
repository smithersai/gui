const std = @import("std");
const structs = @import("structs.zig");
const ffi = @import("../ffi.zig");
const App = @import("../App.zig");
const Session = @import("../session/session.zig");
const EventStream = @import("../session/event_stream.zig");
const Client = @import("../client/client.zig");
const Palette = @import("../commands/palette.zig");
const slash = @import("../commands/slash.zig");
const cwd = @import("../workspace/cwd.zig");
const Persistence = @import("../persistence/sqlite.zig");

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
    const runtime = if (cfg) |ptr| ptr.* else structs.RuntimeConfig{};
    return App.create(ffi.allocator, runtime) catch null;
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
    const ptr = app orelse return null;
    const raw = ffi.spanZ(path);
    return ptr.openWorkspace(raw) catch null;
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

pub export fn smithers_session_new(app: ?*App, opts: structs.SessionOptions) ?*Session {
    const ptr = app orelse return null;
    return Session.create(ptr, opts) catch null;
}

pub export fn smithers_session_free(session: ?*Session) void {
    if (session) |ptr| ptr.destroy();
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
    const ptr = app orelse return null;
    return Client.create(ptr) catch null;
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
        if (out_err) |err| err.* = ffi.errorMessage(1, "client is null");
        return ffi.stringDup("null");
    };
    return ptr.call(ffi.spanZ(method), ffi.spanZ(args_json), out_err);
}

pub export fn smithers_client_stream(
    client: ?*Client,
    method: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    out_err: ?*structs.Error,
) ?*EventStream {
    const ptr = client orelse {
        if (out_err) |err| err.* = ffi.errorMessage(1, "client is null");
        return null;
    };
    return ptr.stream(ffi.spanZ(method), ffi.spanZ(args_json), out_err);
}

pub export fn smithers_palette_new(app: ?*App) ?*Palette {
    const ptr = app orelse return null;
    return Palette.create(ptr) catch null;
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
    return if (palette) |ptr| ptr.activate(ffi.spanZ(item_id)) else ffi.errorMessage(1, "palette is null");
}

pub export fn smithers_slashcmd_parse(input: ?[*:0]const u8) structs.String {
    const json = slash.parseJson(ffi.spanZ(input)) catch return ffi.stringDup("{\"command\":null,\"args\":[],\"mode\":\"error\"}");
    defer ffi.allocator.free(json);
    return ffi.stringDup(json);
}

pub export fn smithers_cwd_resolve(requested: ?[*:0]const u8) structs.String {
    const resolved = cwd.resolveC(requested) catch return ffi.stringDup("");
    defer ffi.allocator.free(resolved);
    return ffi.stringDup(resolved);
}

pub export fn smithers_persistence_open(db_path: ?[*:0]const u8, out_err: ?*structs.Error) ?*Persistence {
    if (out_err) |err| err.* = ffi.errorSuccess();
    const p = Persistence.open(ffi.allocator, ffi.spanZ(db_path)) catch |err| {
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
