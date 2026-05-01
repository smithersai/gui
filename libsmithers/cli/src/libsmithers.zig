const std = @import("std");

pub const AppOpaque = opaque {};
pub const SessionOpaque = opaque {};
pub const ClientOpaque = opaque {};
pub const WorkspaceOpaque = opaque {};
pub const PaletteOpaque = opaque {};
pub const PersistenceOpaque = opaque {};
pub const WorkflowOpaque = opaque {};
pub const EventStreamOpaque = opaque {};

pub const App = ?*AppOpaque;
pub const Session = ?*SessionOpaque;
pub const Client = ?*ClientOpaque;
pub const Workspace = ?*WorkspaceOpaque;
pub const Palette = ?*PaletteOpaque;
pub const Persistence = ?*PersistenceOpaque;
pub const Workflow = ?*WorkflowOpaque;
pub const EventStream = ?*EventStreamOpaque;
pub const Userdata = ?*anyopaque;

pub const String = extern struct {
    ptr: ?[*:0]const u8,
    len: usize,
};

pub const Error = extern struct {
    code: i32,
    msg: ?[*:0]const u8,
};

pub const Bytes = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const Platform = enum(c_int) {
    invalid = 0,
    macos = 1,
    linux = 2,
};

pub const ColorScheme = enum(c_int) {
    light = 0,
    dark = 1,
};

pub const ActionTag = enum(c_int) {
    none = 0,
    open_workspace,
    close_workspace,
    new_session,
    close_session,
    focus_session,
    present_command_palette,
    dismiss_command_palette,
    show_toast,
    desktop_notify,
    run_started,
    run_finished,
    run_state_changed,
    approval_requested,
    clipboard_write,
    open_url,
    config_changed,
    _max,
};

pub const ActionValue = extern union {
    open_workspace: extern struct { path: ?[*:0]const u8 },
    new_session: extern struct { kind: SessionKind },
    close_session: extern struct { session: Session },
    toast: extern struct {
        title: ?[*:0]const u8,
        body: ?[*:0]const u8,
        kind: i32,
    },
    desktop_notify: extern struct {
        title: ?[*:0]const u8,
        body: ?[*:0]const u8,
    },
    open_url: extern struct { url: ?[*:0]const u8 },
    clipboard_write: extern struct { text: ?[*:0]const u8 },
    run_event: extern struct { run_id: ?[*:0]const u8 },
    _reserved: [64]u8,
};

pub const Action = extern struct {
    tag: ActionTag,
    u: ActionValue,
};

pub const ActionTargetTag = enum(c_int) {
    app = 0,
    session = 1,
};

pub const ActionTarget = extern struct {
    tag: ActionTargetTag,
    u: extern union {
        app: App,
        session: Session,
    },
};

pub const RuntimeConfig = extern struct {
    userdata: Userdata = null,
    wakeup: ?*const fn (Userdata) callconv(.c) void = null,
    action: ?*const fn (App, ActionTarget, Action) callconv(.c) bool = null,
    read_clipboard: ?*const fn (Userdata, *String) callconv(.c) bool = null,
    write_clipboard: ?*const fn (Userdata, ?[*:0]const u8) callconv(.c) void = null,
    state_changed: ?*const fn (Userdata) callconv(.c) void = null,
    log: ?*const fn (Userdata, i32, ?[*:0]const u8) callconv(.c) void = null,
    recents_db_path: ?[*:0]const u8 = null,
};

pub const Info = extern struct {
    version: [*:0]const u8,
    commit: [*:0]const u8,
    platform: Platform,
};

pub const SessionKind = enum(c_int) {
    terminal = 0,
    chat,
    run_inspect,
    workflow,
    memory,
    dashboard,
};

pub const SessionOptions = extern struct {
    kind: SessionKind,
    workspace_path: ?[*:0]const u8 = null,
    target_id: ?[*:0]const u8 = null,
    userdata: Userdata = null,
};

pub const EventTag = enum(c_int) {
    none = 0,
    json,
    end,
    err,
};

pub const Event = extern struct {
    tag: EventTag,
    payload: String,
};

pub const PaletteMode = enum(c_int) {
    all = 0,
    commands,
    files,
    workflows,
    workspaces,
    runs,
};

pub extern fn smithers_string_free(s: String) void;
pub extern fn smithers_error_free(e: Error) void;
pub extern fn smithers_bytes_free(b: Bytes) void;

pub extern fn smithers_init(argc: i32, argv: ?[*]?[*:0]u8) i32;
pub extern fn smithers_info() Info;

pub extern fn smithers_app_new(cfg: ?*const RuntimeConfig) App;
pub extern fn smithers_app_free(app: App) void;
pub extern fn smithers_app_tick(app: App) void;
pub extern fn smithers_app_userdata(app: App) Userdata;
pub extern fn smithers_app_set_color_scheme(app: App, scheme: ColorScheme) void;
pub extern fn smithers_app_open_workspace(app: App, path: ?[*:0]const u8) Workspace;
pub extern fn smithers_app_close_workspace(app: App, ws: Workspace) void;
pub extern fn smithers_app_active_workspace_path(app: App) String;
pub extern fn smithers_app_recent_workspaces_json(app: App) String;
pub extern fn smithers_app_remove_recent_workspace(app: App, path: ?[*:0]const u8) void;

pub extern fn smithers_session_new(app: App, opts: SessionOptions) Session;
pub extern fn smithers_session_free(session: Session) void;
pub extern fn smithers_session_kind(session: Session) SessionKind;
pub extern fn smithers_session_userdata(session: Session) Userdata;
pub extern fn smithers_session_title(session: Session) String;
pub extern fn smithers_session_send_text(session: Session, text: ?[*]const u8, len: usize) void;
pub extern fn smithers_session_events(session: Session) EventStream;

pub extern fn smithers_event_stream_next(stream: EventStream) Event;
pub extern fn smithers_event_free(ev: Event) void;
pub extern fn smithers_event_stream_free(stream: EventStream) void;

pub extern fn smithers_client_new(app: App) Client;
pub extern fn smithers_client_free(client: Client) void;
pub extern fn smithers_client_call(
    client: Client,
    method: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    out_err: ?*Error,
) String;
pub extern fn smithers_client_stream(
    client: Client,
    method: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    out_err: ?*Error,
) EventStream;

pub extern fn smithers_palette_new(app: App) Palette;
pub extern fn smithers_palette_free(palette: Palette) void;
pub extern fn smithers_palette_set_mode(palette: Palette, mode: PaletteMode) void;
pub extern fn smithers_palette_set_query(palette: Palette, query: ?[*:0]const u8) void;
pub extern fn smithers_palette_items_json(palette: Palette) String;
pub extern fn smithers_palette_activate(palette: Palette, item_id: ?[*:0]const u8) Error;

pub extern fn smithers_slashcmd_parse(input: ?[*:0]const u8) String;
pub extern fn smithers_cwd_resolve(requested: ?[*:0]const u8) String;

pub extern fn smithers_persistence_open(db_path: ?[*:0]const u8, out_err: ?*Error) Persistence;
pub extern fn smithers_persistence_close(p: Persistence) void;
pub extern fn smithers_persistence_load_sessions(p: Persistence, workspace_path: ?[*:0]const u8) String;
pub extern fn smithers_persistence_save_sessions(
    p: Persistence,
    workspace_path: ?[*:0]const u8,
    sessions_json: ?[*:0]const u8,
) Error;

pub fn stringSlice(s: String) []const u8 {
    const ptr = s.ptr orelse return "";
    return ptr[0..s.len];
}

pub fn errorMessage(e: Error) []const u8 {
    const ptr = e.msg orelse return "";
    return std.mem.sliceTo(ptr, 0);
}

pub fn platformName(platform: Platform) []const u8 {
    return switch (platform) {
        .invalid => "invalid",
        .macos => "macos",
        .linux => "linux",
    };
}

pub fn kindName(kind: SessionKind) []const u8 {
    return switch (kind) {
        .terminal => "terminal",
        .chat => "chat",
        .run_inspect => "run-inspect",
        .workflow => "workflow",
        .memory => "memory",
        .dashboard => "dashboard",
    };
}

pub fn modeName(mode: PaletteMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .commands => "commands",
        .files => "files",
        .workflows => "workflows",
        .workspaces => "workspaces",
        .runs => "runs",
    };
}

test "new session action payload mirrors C ABI" {
    const action = Action{
        .tag = .new_session,
        .u = .{ .new_session = .{ .kind = .terminal } },
    };
    try std.testing.expectEqual(ActionTag.new_session, action.tag);
    try std.testing.expectEqual(SessionKind.terminal, action.u.new_session.kind);
}
