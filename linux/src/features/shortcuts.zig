const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gtk = @import("gtk");
const logx = @import("../log.zig");

const log = std.log.scoped(.smithers_gtk_shortcuts);

pub const Action = enum(u8) {
    show_palette,
    show_palette_command_mode,
    show_palette_ask_ai,
    dismiss_palette,
    new_tab,
    reopen_closed_tab,
    close_tab,
    cycle_next_tab,
    cycle_prev_tab,
    select_workspace_by_number,
    recent_workspace_1,
    recent_workspace_2,
    recent_workspace_3,
    recent_workspace_4,
    recent_workspace_5,
    toggle_developer_debug,
    focus_sidebar,
    focus_content,
    toggle_sidebar,
    open_settings,
    quit_app,
    reload_workspace,
    open_workspace,
    new_workspace,
    split_right,
    split_down,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    toggle_split_zoom,
    next_surface,
    prev_surface,
    select_surface_by_number,
    rename_workspace,
    rename_surface,
    jump_to_unread,
    trigger_flash,
    show_notifications,
    toggle_fullscreen,
    focus_browser_address_bar,
    browser_back,
    browser_forward,
    browser_reload,
    search_within_view,
    find_next,
    find_previous,
    hide_find,
    use_selection_for_find,
    open_browser,
    global_search,
    cancel_current_operation,
    cancel_run,
    rerun,
    approve_selected,
    deny_selected,
    show_shortcut_cheat_sheet,
    linear_navigation_prefix,
    tmux_prefix,
    go_back,
    go_forward,

    pub const len = @typeInfo(Action).@"enum".fields.len;

    pub fn index(self: Action) usize {
        return @intFromEnum(self);
    }

    pub fn actionName(self: Action) [:0]const u8 {
        return action_meta[self.index()].action_name;
    }

    pub fn detailedName(self: Action) [:0]const u8 {
        return action_meta[self.index()].detailed_name;
    }

    pub fn storageKey(self: Action) []const u8 {
        return action_meta[self.index()].storage_key;
    }

    pub fn label(self: Action) []const u8 {
        return action_meta[self.index()].label;
    }

    pub fn swiftDefault(self: Action) []const u8 {
        return action_meta[self.index()].swift_default;
    }

    pub fn isPrefixOnly(self: Action) bool {
        return self == .linear_navigation_prefix or self == .tmux_prefix;
    }

    pub fn isNumbered(self: Action) bool {
        return self == .select_workspace_by_number or self == .select_surface_by_number;
    }
};

pub const actions = [_]Action{
    .show_palette,
    .show_palette_command_mode,
    .show_palette_ask_ai,
    .dismiss_palette,
    .new_tab,
    .reopen_closed_tab,
    .close_tab,
    .cycle_next_tab,
    .cycle_prev_tab,
    .select_workspace_by_number,
    .recent_workspace_1,
    .recent_workspace_2,
    .recent_workspace_3,
    .recent_workspace_4,
    .recent_workspace_5,
    .toggle_developer_debug,
    .focus_sidebar,
    .focus_content,
    .toggle_sidebar,
    .open_settings,
    .quit_app,
    .reload_workspace,
    .open_workspace,
    .new_workspace,
    .split_right,
    .split_down,
    .focus_left,
    .focus_right,
    .focus_up,
    .focus_down,
    .toggle_split_zoom,
    .next_surface,
    .prev_surface,
    .select_surface_by_number,
    .rename_workspace,
    .rename_surface,
    .jump_to_unread,
    .trigger_flash,
    .show_notifications,
    .toggle_fullscreen,
    .focus_browser_address_bar,
    .browser_back,
    .browser_forward,
    .browser_reload,
    .search_within_view,
    .find_next,
    .find_previous,
    .hide_find,
    .use_selection_for_find,
    .open_browser,
    .global_search,
    .cancel_current_operation,
    .cancel_run,
    .rerun,
    .approve_selected,
    .deny_selected,
    .show_shortcut_cheat_sheet,
    .linear_navigation_prefix,
    .tmux_prefix,
    .go_back,
    .go_forward,
};

const Meta = struct {
    action_name: [:0]const u8,
    detailed_name: [:0]const u8,
    storage_key: []const u8,
    label: []const u8,
    swift_default: []const u8,
};

const action_meta: [Action.len]Meta = .{
    .{ .action_name = "show-palette", .detailed_name = "app.show-palette", .storage_key = "commandPalette", .label = "Open Launcher", .swift_default = "Cmd+P" },
    .{ .action_name = "show-palette-command-mode", .detailed_name = "app.show-palette-command-mode", .storage_key = "commandPaletteCommandMode", .label = "Command Palette", .swift_default = "Cmd+Shift+P" },
    .{ .action_name = "show-palette-ask-ai", .detailed_name = "app.show-palette-ask-ai", .storage_key = "commandPaletteAskAI", .label = "Ask AI", .swift_default = "Cmd+K" },
    .{ .action_name = "dismiss-palette", .detailed_name = "app.dismiss-palette", .storage_key = "dismissPalette", .label = "Dismiss Palette", .swift_default = "Esc" },
    .{ .action_name = "new-tab", .detailed_name = "app.new-tab", .storage_key = "newTerminal", .label = "New Terminal Tab", .swift_default = "Cmd+T" },
    .{ .action_name = "reopen-closed-tab", .detailed_name = "app.reopen-closed-tab", .storage_key = "reopenClosedTab", .label = "Reopen Closed Tab", .swift_default = "Cmd+Shift+T" },
    .{ .action_name = "close-tab", .detailed_name = "app.close-tab", .storage_key = "closeCurrentTab", .label = "Close Current Tab", .swift_default = "Cmd+W" },
    .{ .action_name = "cycle-next-tab", .detailed_name = "app.cycle-next-tab", .storage_key = "nextSidebarTab", .label = "Next Sidebar Tab", .swift_default = "Cmd+Shift+]" },
    .{ .action_name = "cycle-prev-tab", .detailed_name = "app.cycle-prev-tab", .storage_key = "prevSidebarTab", .label = "Previous Sidebar Tab", .swift_default = "Cmd+Shift+[" },
    .{ .action_name = "select-workspace-by-number", .detailed_name = "app.select-workspace-by-number", .storage_key = "selectWorkspaceByNumber", .label = "Select Workspace 1-9", .swift_default = "Cmd+1" },
    .{ .action_name = "recent-workspace-1", .detailed_name = "app.recent-workspace-1", .storage_key = "recentWorkspace1", .label = "Recent Workspace 1", .swift_default = "Cmd+1" },
    .{ .action_name = "recent-workspace-2", .detailed_name = "app.recent-workspace-2", .storage_key = "recentWorkspace2", .label = "Recent Workspace 2", .swift_default = "Cmd+2" },
    .{ .action_name = "recent-workspace-3", .detailed_name = "app.recent-workspace-3", .storage_key = "recentWorkspace3", .label = "Recent Workspace 3", .swift_default = "Cmd+3" },
    .{ .action_name = "recent-workspace-4", .detailed_name = "app.recent-workspace-4", .storage_key = "recentWorkspace4", .label = "Recent Workspace 4", .swift_default = "Cmd+4" },
    .{ .action_name = "recent-workspace-5", .detailed_name = "app.recent-workspace-5", .storage_key = "recentWorkspace5", .label = "Recent Workspace 5", .swift_default = "Cmd+5" },
    .{ .action_name = "toggle-developer-debug", .detailed_name = "app.toggle-developer-debug", .storage_key = "toggleDeveloperDebug", .label = "Toggle Developer Debug", .swift_default = "Cmd+Shift+D" },
    .{ .action_name = "focus-sidebar", .detailed_name = "app.focus-sidebar", .storage_key = "focusSidebar", .label = "Focus Sidebar", .swift_default = "Alt+1" },
    .{ .action_name = "focus-content", .detailed_name = "app.focus-content", .storage_key = "focusContent", .label = "Focus Content", .swift_default = "Alt+2" },
    .{ .action_name = "toggle-sidebar", .detailed_name = "app.toggle-sidebar", .storage_key = "toggleSidebar", .label = "Toggle Sidebar", .swift_default = "Cmd+B" },
    .{ .action_name = "open-settings", .detailed_name = "app.open-settings", .storage_key = "openSettings", .label = "Open Settings", .swift_default = "Cmd+," },
    .{ .action_name = "quit-app", .detailed_name = "app.quit-app", .storage_key = "quitApp", .label = "Quit", .swift_default = "Cmd+Q" },
    .{ .action_name = "reload-workspace", .detailed_name = "app.reload-workspace", .storage_key = "refreshCurrentView", .label = "Refresh Current View", .swift_default = "Cmd+R" },
    .{ .action_name = "open-workspace", .detailed_name = "app.open-workspace", .storage_key = "openWorkspace", .label = "Open Workspace", .swift_default = "Cmd+O" },
    .{ .action_name = "new-workspace", .detailed_name = "app.new-workspace", .storage_key = "newWorkspace", .label = "New Workspace", .swift_default = "Cmd+N" },
    .{ .action_name = "split-right", .detailed_name = "app.split-right", .storage_key = "splitRight", .label = "Split Right", .swift_default = "Cmd+D" },
    .{ .action_name = "split-down", .detailed_name = "app.split-down", .storage_key = "splitDown", .label = "Split Down", .swift_default = "Cmd+Shift+D" },
    .{ .action_name = "focus-left", .detailed_name = "app.focus-left", .storage_key = "focusLeft", .label = "Focus Left", .swift_default = "Cmd+Opt+Left" },
    .{ .action_name = "focus-right", .detailed_name = "app.focus-right", .storage_key = "focusRight", .label = "Focus Right", .swift_default = "Cmd+Opt+Right" },
    .{ .action_name = "focus-up", .detailed_name = "app.focus-up", .storage_key = "focusUp", .label = "Focus Up", .swift_default = "Cmd+Opt+Up" },
    .{ .action_name = "focus-down", .detailed_name = "app.focus-down", .storage_key = "focusDown", .label = "Focus Down", .swift_default = "Cmd+Opt+Down" },
    .{ .action_name = "toggle-split-zoom", .detailed_name = "app.toggle-split-zoom", .storage_key = "toggleSplitZoom", .label = "Toggle Split Zoom", .swift_default = "Cmd+Shift+Return" },
    .{ .action_name = "next-surface", .detailed_name = "app.next-surface", .storage_key = "nextSurface", .label = "Next Surface", .swift_default = "Ctrl+Tab" },
    .{ .action_name = "prev-surface", .detailed_name = "app.prev-surface", .storage_key = "prevSurface", .label = "Previous Surface", .swift_default = "Ctrl+Shift+Tab" },
    .{ .action_name = "select-surface-by-number", .detailed_name = "app.select-surface-by-number", .storage_key = "selectSurfaceByNumber", .label = "Select Surface 1-9", .swift_default = "Ctrl+1" },
    .{ .action_name = "rename-workspace", .detailed_name = "app.rename-workspace", .storage_key = "renameWorkspace", .label = "Rename Workspace", .swift_default = "Cmd+Shift+R" },
    .{ .action_name = "rename-surface", .detailed_name = "app.rename-surface", .storage_key = "renameSurface", .label = "Rename Surface", .swift_default = "Cmd+Opt+R" },
    .{ .action_name = "jump-to-unread", .detailed_name = "app.jump-to-unread", .storage_key = "jumpToUnread", .label = "Jump to Latest Unread", .swift_default = "Cmd+Shift+U" },
    .{ .action_name = "trigger-flash", .detailed_name = "app.trigger-flash", .storage_key = "triggerFlash", .label = "Flash Focused Pane", .swift_default = "Cmd+Shift+H" },
    .{ .action_name = "show-notifications", .detailed_name = "app.show-notifications", .storage_key = "showNotifications", .label = "Show Notifications", .swift_default = "Cmd+I" },
    .{ .action_name = "toggle-fullscreen", .detailed_name = "app.toggle-fullscreen", .storage_key = "toggleFullScreen", .label = "Toggle Full Screen", .swift_default = "Cmd+Ctrl+F" },
    .{ .action_name = "focus-browser-address-bar", .detailed_name = "app.focus-browser-address-bar", .storage_key = "focusBrowserAddressBar", .label = "Focus Browser Address Bar", .swift_default = "Cmd+L" },
    .{ .action_name = "browser-back", .detailed_name = "app.browser-back", .storage_key = "browserBack", .label = "Browser Back", .swift_default = "Cmd+[" },
    .{ .action_name = "browser-forward", .detailed_name = "app.browser-forward", .storage_key = "browserForward", .label = "Browser Forward", .swift_default = "Cmd+]" },
    .{ .action_name = "browser-reload", .detailed_name = "app.browser-reload", .storage_key = "browserReload", .label = "Browser Reload", .swift_default = "Cmd+R" },
    .{ .action_name = "search-within-view", .detailed_name = "app.search-within-view", .storage_key = "find", .label = "Find", .swift_default = "Cmd+F" },
    .{ .action_name = "find-next", .detailed_name = "app.find-next", .storage_key = "findNext", .label = "Find Next", .swift_default = "Cmd+G" },
    .{ .action_name = "find-previous", .detailed_name = "app.find-previous", .storage_key = "findPrevious", .label = "Find Previous", .swift_default = "Cmd+Opt+G" },
    .{ .action_name = "hide-find", .detailed_name = "app.hide-find", .storage_key = "hideFind", .label = "Hide Find", .swift_default = "Cmd+Opt+F" },
    .{ .action_name = "use-selection-for-find", .detailed_name = "app.use-selection-for-find", .storage_key = "useSelectionForFind", .label = "Use Selection for Find", .swift_default = "Cmd+E" },
    .{ .action_name = "open-browser", .detailed_name = "app.open-browser", .storage_key = "openBrowser", .label = "Open Browser Surface", .swift_default = "Cmd+Shift+L" },
    .{ .action_name = "global-search", .detailed_name = "app.global-search", .storage_key = "globalSearch", .label = "Global Search", .swift_default = "Cmd+Shift+F" },
    .{ .action_name = "cancel-current-operation", .detailed_name = "app.cancel-current-operation", .storage_key = "cancelCurrentOperation", .label = "Cancel Current Operation", .swift_default = "Cmd+." },
    .{ .action_name = "cancel-run", .detailed_name = "app.cancel-run", .storage_key = "cancelRun", .label = "Cancel Run", .swift_default = "Cmd+." },
    .{ .action_name = "rerun", .detailed_name = "app.rerun", .storage_key = "rerun", .label = "Rerun", .swift_default = "Cmd+Shift+R" },
    .{ .action_name = "approve-selected", .detailed_name = "app.approve-selected", .storage_key = "approveSelected", .label = "Approve Selected", .swift_default = "Cmd+Return" },
    .{ .action_name = "deny-selected", .detailed_name = "app.deny-selected", .storage_key = "denySelected", .label = "Deny Selected", .swift_default = "Cmd+Backspace" },
    .{ .action_name = "show-shortcut-cheat-sheet", .detailed_name = "app.show-shortcut-cheat-sheet", .storage_key = "showShortcutCheatSheet", .label = "Shortcut Cheat Sheet", .swift_default = "Cmd+/" },
    .{ .action_name = "linear-navigation-prefix", .detailed_name = "app.linear-navigation-prefix", .storage_key = "linearNavigationPrefix", .label = "Navigation Chord Prefix", .swift_default = "G" },
    .{ .action_name = "tmux-prefix", .detailed_name = "app.tmux-prefix", .storage_key = "tmuxPrefix", .label = "Tmux-Style Chord Prefix", .swift_default = "Ctrl+B" },
    .{ .action_name = "go-back", .detailed_name = "app.go-back", .storage_key = "goBack", .label = "Go Back", .swift_default = "Cmd+[" },
    .{ .action_name = "go-forward", .detailed_name = "app.go-forward", .storage_key = "goForward", .label = "Go Forward", .swift_default = "Cmd+]" },
};

pub const default_accel: [Action.len][]const u8 = .{
    "<Primary>p",
    "<Primary><Shift>p",
    "<Primary>k",
    "Escape",
    "<Primary>t",
    "<Primary><Shift>t",
    "<Primary>w",
    "<Primary><Shift>bracketright",
    "<Primary><Shift>bracketleft",
    "<Primary>1",
    "<Primary>1",
    "<Primary>2",
    "<Primary>3",
    "<Primary>4",
    "<Primary>5",
    "<Primary><Shift>d",
    "<Alt>1",
    "<Alt>2",
    "<Primary>b",
    "<Primary>comma",
    "<Primary>q",
    "<Primary>r",
    "<Primary>o",
    "<Primary>n",
    "<Primary>d",
    "<Primary><Shift>d",
    "<Primary><Alt>Left",
    "<Primary><Alt>Right",
    "<Primary><Alt>Up",
    "<Primary><Alt>Down",
    "<Primary><Shift>Return",
    "<Control>Tab",
    "<Control><Shift>Tab",
    "<Control>1",
    "<Primary><Shift>r",
    "<Primary><Alt>r",
    "<Primary><Shift>u",
    "<Primary><Shift>h",
    "<Primary>i",
    "F11",
    "<Primary>l",
    "<Primary>bracketleft",
    "<Primary>bracketright",
    "<Primary>r",
    "<Primary>f",
    "<Primary>g",
    "<Primary><Alt>g",
    "<Primary><Alt>f",
    "<Primary>e",
    "<Primary><Shift>l",
    "<Primary><Shift>f",
    "<Primary>period",
    "<Primary>period",
    "<Primary><Shift>r",
    "<Primary>Return",
    "<Primary>BackSpace",
    "<Primary>slash",
    "g",
    "<Control>b",
    "<Primary>bracketleft",
    "<Primary>bracketright",
};

const default_accel_z: [Action.len][:0]const u8 = .{
    "<Primary>p",
    "<Primary><Shift>p",
    "<Primary>k",
    "Escape",
    "<Primary>t",
    "<Primary><Shift>t",
    "<Primary>w",
    "<Primary><Shift>bracketright",
    "<Primary><Shift>bracketleft",
    "<Primary>1",
    "<Primary>1",
    "<Primary>2",
    "<Primary>3",
    "<Primary>4",
    "<Primary>5",
    "<Primary><Shift>d",
    "<Alt>1",
    "<Alt>2",
    "<Primary>b",
    "<Primary>comma",
    "<Primary>q",
    "<Primary>r",
    "<Primary>o",
    "<Primary>n",
    "<Primary>d",
    "<Primary><Shift>d",
    "<Primary><Alt>Left",
    "<Primary><Alt>Right",
    "<Primary><Alt>Up",
    "<Primary><Alt>Down",
    "<Primary><Shift>Return",
    "<Control>Tab",
    "<Control><Shift>Tab",
    "<Control>1",
    "<Primary><Shift>r",
    "<Primary><Alt>r",
    "<Primary><Shift>u",
    "<Primary><Shift>h",
    "<Primary>i",
    "F11",
    "<Primary>l",
    "<Primary>bracketleft",
    "<Primary>bracketright",
    "<Primary>r",
    "<Primary>f",
    "<Primary>g",
    "<Primary><Alt>g",
    "<Primary><Alt>f",
    "<Primary>e",
    "<Primary><Shift>l",
    "<Primary><Shift>f",
    "<Primary>period",
    "<Primary>period",
    "<Primary><Shift>r",
    "<Primary>Return",
    "<Primary>BackSpace",
    "<Primary>slash",
    "g",
    "<Control>b",
    "<Primary>bracketleft",
    "<Primary>bracketright",
};

pub const StoredShortcut = struct {
    key: []const u8,
    command: bool = false,
    shift: bool = false,
    option: bool = false,
    control: bool = false,
    keyCode: ?u16 = null,
    chordKey: ?[]const u8 = null,
    chordCommand: bool = false,
    chordShift: bool = false,
    chordOption: bool = false,
    chordControl: bool = false,
    chordKeyCode: ?u16 = null,

    pub fn clone(self: StoredShortcut, alloc: std.mem.Allocator) !StoredShortcut {
        var out = self;
        out.key = try alloc.dupe(u8, self.key);
        errdefer alloc.free(out.key);
        if (self.chordKey) |chord| out.chordKey = try alloc.dupe(u8, chord);
        return out;
    }

    pub fn deinit(self: *StoredShortcut, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        if (self.chordKey) |chord| alloc.free(chord);
        self.* = .{ .key = "" };
    }

    pub fn hasChord(self: StoredShortcut) bool {
        return self.chordKey != null;
    }
};

pub const Bindings = struct {
    allocator: ?std.mem.Allocator = null,
    overrides: [Action.len]?StoredShortcut = [_]?StoredShortcut{null} ** Action.len,
    override_accels: [Action.len]?[:0]u8 = [_]?[:0]u8{null} ** Action.len,

    pub fn deinit(self: *Bindings) void {
        const alloc = self.allocator orelse return;
        for (&self.overrides, &self.override_accels) |*shortcut, *accel_slot| {
            if (shortcut.*) |*value| value.deinit(alloc);
            shortcut.* = null;
            if (accel_slot.*) |owned| alloc.free(owned);
            accel_slot.* = null;
        }
        self.allocator = null;
    }

    pub fn accel(self: *const Bindings, action: Action) [:0]const u8 {
        if (self.override_accels[action.index()]) |value| return value;
        return default_accel_z[action.index()];
    }

    pub fn overrideFor(self: *const Bindings, action: Action) ?StoredShortcut {
        return self.overrides[action.index()];
    }

    pub fn setOverride(self: *Bindings, alloc: std.mem.Allocator, action: Action, shortcut: StoredShortcut) !void {
        if (self.allocator == null) self.allocator = alloc;
        const owned_shortcut = try normalizedShortcut(action, shortcut).clone(alloc);
        errdefer {
            var mutable = owned_shortcut;
            mutable.deinit(alloc);
        }

        const owned_accel = try acceleratorFromShortcut(alloc, owned_shortcut);
        errdefer if (owned_accel) |accel_value| alloc.free(accel_value);

        self.clearOverride(action);
        self.overrides[action.index()] = owned_shortcut;
        self.override_accels[action.index()] = owned_accel;
    }

    pub fn clearOverride(self: *Bindings, action: Action) void {
        const alloc = self.allocator orelse return;
        const index = action.index();
        if (self.overrides[index]) |*value| value.deinit(alloc);
        self.overrides[index] = null;
        if (self.override_accels[index]) |owned| alloc.free(owned);
        self.override_accels[index] = null;
    }
};

pub const Callback = *const fn (action: Action, userdata: ?*anyopaque) callconv(.c) void;

var callback: ?Callback = null;
var callback_userdata: ?*anyopaque = null;

pub fn setCallback(cb: ?Callback, userdata: ?*anyopaque) void {
    callback = cb;
    callback_userdata = userdata;
}

pub fn emit(action: Action) void {
    if (callback) |cb| cb(action, callback_userdata);
}

pub fn defaultPath(alloc: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
        defer alloc.free(xdg);
        return try std.fs.path.join(alloc, &.{ xdg, "smithers-gtk", "shortcuts.json" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &.{ home, ".config", "smithers-gtk", "shortcuts.json" });
}

pub fn load(alloc: std.mem.Allocator, path: []const u8) !Bindings {
    var bindings = Bindings{ .allocator = alloc };
    errdefer bindings.deinit();

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            log.debug("shortcuts load: no overrides file at {s}", .{path});
            return bindings;
        },
        else => {
            logx.catchWarn(log, "shortcuts load readFile", err);
            return err;
        },
    };
    defer alloc.free(bytes);
    if (std.mem.trim(u8, bytes, &std.ascii.whitespace).len == 0) return bindings;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();

    const root = object(&parsed.value) orelse return bindings;
    var section = root;
    var shortcuts_value: std.json.Value = undefined;
    if (root.get("shortcuts")) |value| {
        shortcuts_value = value;
        if (object(&shortcuts_value)) |shortcuts_obj| section = shortcuts_obj;
    }
    if (section.get("bindings")) |value| {
        var bindings_value = value;
        if (object(&bindings_value)) |bindings_obj| try loadBindingsObject(alloc, bindings_obj, &bindings);
    }
    try loadLegacyShortcutObject(alloc, section, &bindings);
    return bindings;
}

pub fn save(alloc: std.mem.Allocator, path: []const u8, bindings: Bindings) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("shortcuts");
    try jw.beginObject();
    try jw.objectField("bindings");
    try jw.beginObject();
    for (actions) |action| {
        const shortcut = bindings.overrideFor(action) orelse continue;
        try jw.objectField(action.storageKey());
        try writeShortcut(&jw, shortcut);
    }
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();

    const data = try out.toOwnedSlice();
    defer alloc.free(data);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

pub fn register(app: *adw.Application, bindings: Bindings) void {
    logx.event(log, "shortcuts_register", "action_count={d}", .{actions.len});
    const action_map = app.as(gio.ActionMap);
    const gtk_app = app.as(gtk.Application);
    inline for (actions) |action| {
        const simple = gio.SimpleAction.new(action.actionName(), null);
        defer simple.unref();
        _ = gio.SimpleAction.signals.activate.connect(
            simple,
            *ActionContext,
            activated,
            actionContext(action),
            .{},
        );
        action_map.addAction(simple.as(gio.Action));

        const accel_value = bindings.accel(action);
        if (accel_value.len == 0 or action.isPrefixOnly()) {
            const none = [_:null]?[*:0]const u8{};
            gtk_app.setAccelsForAction(action.detailedName(), &none);
        } else {
            const accels = [_:null]?[*:0]const u8{accel_value.ptr};
            gtk_app.setAccelsForAction(action.detailedName(), &accels);
        }
    }
}

pub fn fromName(name: []const u8) ?Action {
    for (actions) |action| {
        if (std.mem.eql(u8, name, action.storageKey())) return action;
        if (std.mem.eql(u8, name, action.actionName())) return action;
        if (std.mem.eql(u8, name, @tagName(action))) return action;
    }
    return null;
}

pub fn gtkAcceleratorParses(accel: [:0]const u8) bool {
    var key: c_uint = 0;
    var mods: gdk.ModifierType = .flags_no_modifier_mask;
    return gtk.acceleratorParse(accel.ptr, &key, &mods) != 0 and key != 0;
}

fn loadBindingsObject(alloc: std.mem.Allocator, bindings_obj: *std.json.ObjectMap, bindings: *Bindings) !void {
    var iter = bindings_obj.iterator();
    while (iter.next()) |entry| {
        const action = fromName(entry.key_ptr.*) orelse continue;
        const shortcut = parseShortcut(alloc, entry.value_ptr) orelse continue;
        defer {
            var mutable = shortcut;
            mutable.deinit(alloc);
        }
        try bindings.setOverride(alloc, action, shortcut);
    }
}

fn loadLegacyShortcutObject(alloc: std.mem.Allocator, section: *std.json.ObjectMap, bindings: *Bindings) !void {
    var iter = section.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "bindings")) continue;
        const action = fromName(entry.key_ptr.*) orelse continue;
        const shortcut = parseShortcut(alloc, entry.value_ptr) orelse continue;
        defer {
            var mutable = shortcut;
            mutable.deinit(alloc);
        }
        try bindings.setOverride(alloc, action, shortcut);
    }
}

fn parseShortcut(alloc: std.mem.Allocator, value: *std.json.Value) ?StoredShortcut {
    const obj = object(value) orelse return null;
    const key = stringField(obj, "key") orelse return null;
    var shortcut = StoredShortcut{
        .key = alloc.dupe(u8, key) catch |err| {
            logx.catchWarn(log, "parseShortcut.dupe key", err);
            return null;
        },
        .command = boolField(obj, "command"),
        .shift = boolField(obj, "shift"),
        .option = boolField(obj, "option"),
        .control = boolField(obj, "control"),
        .keyCode = u16Field(obj, "keyCode"),
        .chordCommand = boolField(obj, "chordCommand"),
        .chordShift = boolField(obj, "chordShift"),
        .chordOption = boolField(obj, "chordOption"),
        .chordControl = boolField(obj, "chordControl"),
        .chordKeyCode = u16Field(obj, "chordKeyCode"),
    };
    errdefer shortcut.deinit(alloc);
    if (stringField(obj, "chordKey")) |chord| {
        if (chord.len > 0) shortcut.chordKey = alloc.dupe(u8, chord) catch |err| {
            logx.catchWarn(log, "parseShortcut.dupe chordKey", err);
            return null;
        };
    }
    return shortcut;
}

fn writeShortcut(jw: *std.json.Stringify, shortcut: StoredShortcut) !void {
    try jw.beginObject();
    try jw.objectField("key");
    try jw.write(shortcut.key);
    try jw.objectField("command");
    try jw.write(shortcut.command);
    try jw.objectField("shift");
    try jw.write(shortcut.shift);
    try jw.objectField("option");
    try jw.write(shortcut.option);
    try jw.objectField("control");
    try jw.write(shortcut.control);
    if (shortcut.keyCode) |key_code| {
        try jw.objectField("keyCode");
        try jw.write(key_code);
    }
    if (shortcut.chordKey) |chord_key| {
        try jw.objectField("chordKey");
        try jw.write(chord_key);
        try jw.objectField("chordCommand");
        try jw.write(shortcut.chordCommand);
        try jw.objectField("chordShift");
        try jw.write(shortcut.chordShift);
        try jw.objectField("chordOption");
        try jw.write(shortcut.chordOption);
        try jw.objectField("chordControl");
        try jw.write(shortcut.chordControl);
        if (shortcut.chordKeyCode) |chord_key_code| {
            try jw.objectField("chordKeyCode");
            try jw.write(chord_key_code);
        }
    }
    try jw.endObject();
}

fn normalizedShortcut(action: Action, shortcut: StoredShortcut) StoredShortcut {
    if (!action.isNumbered()) return shortcut;
    const digit_source = shortcut.chordKey orelse shortcut.key;
    if (digit_source.len != 1 or digit_source[0] < '1' or digit_source[0] > '9') return shortcut;
    var normalized = shortcut;
    if (shortcut.hasChord()) {
        normalized.chordKey = "1";
    } else {
        normalized.key = "1";
    }
    return normalized;
}

fn acceleratorFromShortcut(alloc: std.mem.Allocator, shortcut: StoredShortcut) !?[:0]u8 {
    if (shortcut.hasChord()) return null;
    const key_name = gtkKeyName(shortcut.key) orelse return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (shortcut.command) try out.writer.writeAll("<Primary>");
    if (shortcut.shift) try out.writer.writeAll("<Shift>");
    if (shortcut.option) try out.writer.writeAll("<Alt>");
    if (shortcut.control) try out.writer.writeAll("<Control>");
    try out.writer.writeAll(key_name);
    return try out.toOwnedSliceSentinel(0);
}

fn gtkKeyName(key: []const u8) ?[]const u8 {
    if (key.len == 1) {
        return switch (key[0]) {
            '\t' => "Tab",
            '\r' => "Return",
            ' ' => "space",
            '[' => "bracketleft",
            ']' => "bracketright",
            '/' => "slash",
            '.' => "period",
            ',' => "comma",
            ';' => "semicolon",
            '\'' => "apostrophe",
            '\\' => "backslash",
            '`' => "grave",
            '-' => "minus",
            '=' => "equal",
            else => key,
        };
    }
    if (std.mem.eql(u8, key, "\xE2\x86\x90")) return "Left";
    if (std.mem.eql(u8, key, "\xE2\x86\x92")) return "Right";
    if (std.mem.eql(u8, key, "\xE2\x86\x91")) return "Up";
    if (std.mem.eql(u8, key, "\xE2\x86\x93")) return "Down";
    return null;
}

fn object(value: *std.json.Value) ?*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*obj| obj,
        else => null,
    };
}

fn stringField(obj: *std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

fn boolField(obj: *std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

fn u16Field(obj: *std.json.ObjectMap, key: []const u8) ?u16 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u16)) @intCast(i) else null,
        else => null,
    };
}

const ActionContext = struct {
    action: Action,
};

var action_contexts: [Action.len]ActionContext = contexts: {
    var out: [Action.len]ActionContext = undefined;
    for (actions) |action| out[action.index()] = .{ .action = action };
    break :contexts out;
};

fn actionContext(action: Action) *ActionContext {
    return &action_contexts[action.index()];
}

fn activated(_: *gio.SimpleAction, _: ?*glib.Variant, context: *ActionContext) callconv(.c) void {
    emit(context.action);
}

comptime {
    if (actions.len != Action.len) @compileError("shortcuts.actions must cover every Action variant");
    if (action_meta.len != Action.len) @compileError("shortcut action metadata must cover every Action variant");
    if (default_accel.len != Action.len) @compileError("default_accel must cover every Action variant");
    if (default_accel_z.len != Action.len) @compileError("default_accel_z must cover every Action variant");
}
