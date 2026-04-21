const builtin = @import("builtin");

// keep in sync: smithers_string_s
pub const String = extern struct {
    ptr: ?[*:0]const u8,
    len: usize,
};

// keep in sync: smithers_error_s
pub const Error = extern struct {
    code: i32,
    msg: ?[*:0]const u8,
};

// keep in sync: smithers_bytes_s
pub const Bytes = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

// keep in sync: smithers_platform_e
pub const Platform = enum(c_int) {
    invalid = 0,
    macos = 1,
    linux = 2,
};

// keep in sync: smithers_color_scheme_e
pub const ColorScheme = enum(c_int) {
    light = 0,
    dark = 1,
};

// keep in sync: smithers_action_tag_e
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

// keep in sync: smithers_action_s union payloads
pub const ActionValue = extern union {
    open_workspace: extern struct { path: ?[*:0]const u8 },
    new_session: extern struct { kind: SessionKind },
    close_session: extern struct { session: ?*anyopaque },
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

// keep in sync: smithers_action_s
pub const Action = extern struct {
    tag: ActionTag,
    u: ActionValue,
};

// keep in sync: smithers_action_target_tag_e
pub const ActionTargetTag = enum(c_int) {
    app = 0,
    session = 1,
};

// keep in sync: smithers_action_target_s
pub const ActionTarget = extern struct {
    tag: ActionTargetTag,
    u: extern union {
        app: ?*anyopaque,
        session: ?*anyopaque,
    },
};

// keep in sync: smithers_runtime_config_s
pub const RuntimeConfig = extern struct {
    userdata: ?*anyopaque = null,
    wakeup: ?*const fn (?*anyopaque) callconv(.c) void = null,
    action: ?*const fn (?*anyopaque, ActionTarget, Action) callconv(.c) bool = null,
    read_clipboard: ?*const fn (?*anyopaque, *String) callconv(.c) bool = null,
    write_clipboard: ?*const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque) callconv(.c) void = null,
    log: ?*const fn (?*anyopaque, i32, ?[*:0]const u8) callconv(.c) void = null,
};

// keep in sync: smithers_info_s
pub const Info = extern struct {
    version: [*:0]const u8,
    commit: [*:0]const u8,
    platform: Platform,
};

// keep in sync: smithers_session_kind_e
pub const SessionKind = enum(c_int) {
    terminal = 0,
    chat,
    run_inspect,
    workflow,
    memory,
    dashboard,
};

// keep in sync: smithers_session_options_s
pub const SessionOptions = extern struct {
    kind: SessionKind,
    workspace_path: ?[*:0]const u8 = null,
    target_id: ?[*:0]const u8 = null,
    userdata: ?*anyopaque = null,
};

// keep in sync: smithers_event_tag_e
pub const EventTag = enum(c_int) {
    none = 0,
    json,
    end,
    err,
};

// keep in sync: smithers_event_s
pub const Event = extern struct {
    tag: EventTag,
    payload: String,
};

// keep in sync: smithers_palette_mode_e
pub const PaletteMode = enum(c_int) {
    all = 0,
    commands,
    files,
    workflows,
    workspaces,
    runs,
};

pub fn nativePlatform() Platform {
    return switch (builtin.target.os.tag) {
        .macos => .macos,
        .linux => .linux,
        else => .invalid,
    };
}
