const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const logx = @import("../log.zig");
const App = @import("../App.zig");
const Common = @import("../class.zig").Common;
const shortcuts = @import("../features/shortcuts.zig");
const MainWindow = @import("main_window.zig").MainWindow;

const log = std.log.scoped(.smithers_gtk_application);

pub const Application = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Application;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersApplication",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        opts: App.Options = .{},
        core_app: smithers.c.smithers_app_t = null,
        client: smithers.c.smithers_client_t = null,
        palette: smithers.c.smithers_palette_t = null,
        main_window: ?*MainWindow = null,
        shortcut_bindings: shortcuts.Bindings = .{},
        clipboard: CachedClipboard = .{},
        running: bool = false,
        needs_refresh: std.atomic.Value(bool) = .init(false),
        did_deinit: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, opts: App.Options) !*Self {
        adw.init();

        const self = gobject.ext.newInstance(Self, .{
            .application_id = "sh.smithers.GUI",
            .flags = gio.ApplicationFlags.flags_default_flags,
        });
        errdefer self.unref();

        const priv = self.private();
        priv.* = .{
            .alloc = alloc,
            .opts = opts,
        };

        if (smithers.c.smithers_init(0, null) != smithers.c.SMITHERS_SUCCESS) {
            return error.SmithersInitFailed;
        }

        var cfg = std.mem.zeroes(smithers.c.smithers_runtime_config_s);
        cfg.userdata = self;
        cfg.wakeup = wakeupCallback;
        cfg.action = actionCallback;
        cfg.read_clipboard = readClipboardCallback;
        cfg.write_clipboard = writeClipboardCallback;
        cfg.state_changed = stateChangedCallback;
        cfg.log = logCallback;

        priv.core_app = smithers.c.smithers_app_new(&cfg);
        if (priv.core_app == null) return error.CoreAppCreateFailed;
        priv.client = smithers.c.smithers_client_new(priv.core_app);
        if (priv.client == null) return error.ClientCreateFailed;
        priv.palette = smithers.c.smithers_palette_new(priv.core_app);
        if (priv.palette == null) return error.PaletteCreateFailed;

        if (shortcuts.defaultPath(alloc)) |path| {
            defer alloc.free(path);
            priv.shortcut_bindings = shortcuts.load(alloc, path) catch |err| loaded: {
                log.warn("shortcuts.load from {s} failed: {s}", .{ path, @errorName(err) });
                break :loaded .{ .allocator = alloc };
            };
        } else |err| {
            logx.catchWarn(log, "shortcuts.defaultPath", err);
            priv.shortcut_bindings = .{ .allocator = alloc };
        }

        adw.StyleManager.getDefault().setColorScheme(.force_dark);

        const css =
            \\ @define-color base_bg_color #0B0D14;
            \\ @define-color surface1_color #11141F;
            \\ @define-color surface2_color #161A28;
            \\ @define-color accent_color #4C8DFF;
            \\ @define-color success_color #34D399;
            \\ @define-color warning_color #FBBF24;
            \\ @define-color error_color #F87171;
            \\ @define-color info_color #60A5FA;
            \\ @define-color border_color rgba(255, 255, 255, 0.06);
            \\ @define-color border_hover_color rgba(255, 255, 255, 0.12);
            \\ @define-color window_bg_color @base_bg_color;
            \\ @define-color window_fg_color rgba(255, 255, 255, 0.90);
            \\ @define-color view_bg_color @surface1_color;
            \\ @define-color view_fg_color rgba(255, 255, 255, 0.90);
            \\ @define-color headerbar_bg_color @base_bg_color;
            \\ @define-color headerbar_fg_color rgba(255, 255, 255, 0.75);
            \\ @define-color popover_bg_color @surface2_color;
            \\ @define-color popover_fg_color rgba(255, 255, 255, 0.90);
            \\ @define-color card_bg_color @surface1_color;
            \\ @define-color card_fg_color rgba(255, 255, 255, 0.90);
            \\
            \\ window, dialog, .background {
            \\     background-color: @base_bg_color;
            \\     color: @window_fg_color;
            \\ }
            \\ headerbar {
            \\     background-color: @base_bg_color;
            \\     box-shadow: none;
            \\     border-bottom: 1px solid @border_color;
            \\     min-height: 44px;
            \\ }
            \\ headerbar title {
            \\     font-weight: 600;
            \\     font-size: 13px;
            \\ }
            \\ .title-1 {
            \\     font-size: 26px;
            \\     font-weight: 700;
            \\     letter-spacing: -0.01em;
            \\ }
            \\ .title-2 {
            \\     font-size: 16px;
            \\     font-weight: 600;
            \\ }
            \\ .caption {
            \\     font-size: 10px;
            \\     font-weight: 600;
            \\     letter-spacing: 0.08em;
            \\     text-transform: uppercase;
            \\     color: rgba(255, 255, 255, 0.45);
            \\ }
            \\ .navigation-sidebar {
            \\     background-color: @surface1_color;
            \\     border-right: 1px solid @border_color;
            \\     padding: 0;
            \\ }
            \\ .navigation-sidebar > list,
            \\ .navigation-sidebar list {
            \\     background-color: transparent;
            \\ }
            \\ .navigation-sidebar row {
            \\     background-color: transparent;
            \\     background-image: none;
            \\     border: none;
            \\     border-radius: 6px;
            \\     margin: 1px 4px;
            \\     padding: 0;
            \\     min-height: 30px;
            \\     transition: background-color 0.12s ease-out, color 0.12s ease-out;
            \\     color: rgba(255, 255, 255, 0.70);
            \\ }
            \\ .navigation-sidebar row > box,
            \\ .navigation-sidebar row .header,
            \\ .navigation-sidebar row.activatable {
            \\     padding: 4px 8px;
            \\     min-height: 30px;
            \\ }
            \\ .navigation-sidebar row.activatable {
            \\     box-shadow: none;
            \\ }
            \\ .navigation-sidebar row .title {
            \\     font-weight: 500;
            \\     font-size: 13px;
            \\ }
            \\ .navigation-sidebar row .subtitle {
            \\     font-size: 11px;
            \\     opacity: 0.7;
            \\ }
            \\ .navigation-sidebar row image {
            \\     -gtk-icon-size: 16px;
            \\     margin-right: 4px;
            \\ }
            \\ .navigation-sidebar row:hover {
            \\     background-color: rgba(255, 255, 255, 0.05);
            \\     color: rgba(255, 255, 255, 0.95);
            \\ }
            \\ .navigation-sidebar row:selected, .navigation-sidebar row.selected {
            \\     background-color: rgba(76, 141, 255, 0.15);
            \\     color: #FFFFFF;
            \\ }
            \\ button {
            \\     background-color: rgba(255, 255, 255, 0.04);
            \\     color: rgba(255, 255, 255, 0.88);
            \\     border: 1px solid transparent;
            \\     border-radius: 6px;
            \\     transition: all 0.12s ease-out;
            \\     min-height: 28px;
            \\     padding: 4px 12px;
            \\ }
            \\ button:hover {
            \\     background-color: rgba(255, 255, 255, 0.08);
            \\     color: #FFFFFF;
            \\ }
            \\ button:active {
            \\     background-color: rgba(255, 255, 255, 0.12);
            \\ }
            \\ button.suggested-action {
            \\     background-color: @accent_color;
            \\     color: #FFFFFF;
            \\     border-color: transparent;
            \\     font-weight: 600;
            \\ }
            \\ button.suggested-action:hover {
            \\     background-color: shade(@accent_color, 1.1);
            \\ }
            \\ button.destructive-action {
            \\     background-color: @error_color;
            \\     color: #FFFFFF;
            \\ }
            \\ button.flat, button.image-button {
            \\     background-color: transparent;
            \\     border-color: transparent;
            \\ }
            \\ button.flat:hover, button.image-button:hover {
            \\     background-color: rgba(255, 255, 255, 0.06);
            \\ }
            \\ button.dash-tab {
            \\     background-color: transparent;
            \\     border: none;
            \\     border-bottom: 2px solid transparent;
            \\     border-radius: 0;
            \\     padding: 8px 14px;
            \\     color: rgba(255, 255, 255, 0.55);
            \\     font-weight: 500;
            \\     min-height: 32px;
            \\ }
            \\ button.dash-tab:hover {
            \\     background-color: transparent;
            \\     color: rgba(255, 255, 255, 0.90);
            \\ }
            \\ button.dash-tab.active {
            \\     color: #FFFFFF;
            \\     border-bottom-color: @accent_color;
            \\ }
            \\ .dash-tabs {
            \\     border-bottom: 1px solid @border_color;
            \\     padding: 0 8px;
            \\ }
            \\ button.link-button {
            \\     background-color: transparent;
            \\     border: none;
            \\     color: rgba(255, 255, 255, 0.60);
            \\     padding: 4px 8px;
            \\ }
            \\ button.link-button:hover {
            \\     background-color: transparent;
            \\     color: @accent_color;
            \\ }
            \\ entry {
            \\     background-color: rgba(255, 255, 255, 0.04);
            \\     color: rgba(255, 255, 255, 0.92);
            \\     border: 1px solid @border_color;
            \\     border-radius: 6px;
            \\     padding: 6px 10px;
            \\     transition: all 0.15s ease-out;
            \\ }
            \\ entry:focus-within {
            \\     border-color: @accent_color;
            \\     background-color: rgba(255, 255, 255, 0.06);
            \\ }
            \\ .boxed-list {
            \\     background-color: @surface1_color;
            \\     border-radius: 10px;
            \\     border: 1px solid @border_color;
            \\     box-shadow: none;
            \\ }
            \\ .boxed-list row, list.boxed-list row {
            \\     background-color: transparent;
            \\     border-bottom: 1px solid @border_color;
            \\     transition: background-color 0.12s ease-out;
            \\     min-height: 44px;
            \\ }
            \\ .boxed-list row:last-child, list.boxed-list row:last-child {
            \\     border-bottom: none;
            \\ }
            \\ .boxed-list row.activatable:hover {
            \\     background-color: rgba(255, 255, 255, 0.03);
            \\ }
            \\ .boxed-list row:selected {
            \\     background-color: rgba(76, 141, 255, 0.10);
            \\ }
            \\ .card {
            \\     background-color: @surface1_color;
            \\     border-radius: 10px;
            \\     border: 1px solid @border_color;
            \\     box-shadow: none;
            \\ }
            \\ .metric-card {
            \\     background-color: @surface1_color;
            \\     border-radius: 10px;
            \\     border: 1px solid @border_color;
            \\     padding: 14px 16px;
            \\     transition: border-color 0.15s ease-out;
            \\ }
            \\ .metric-card:hover {
            \\     border-color: @border_hover_color;
            \\ }
            \\ .metric-card.primary .metric-value {
            \\     color: #FFFFFF;
            \\ }
            \\ .metric-card.secondary {
            \\     background-color: transparent;
            \\     border-color: @border_color;
            \\     padding: 10px 14px;
            \\ }
            \\ .metric-value {
            \\     font-size: 28px;
            \\     font-weight: 700;
            \\     color: rgba(255, 255, 255, 0.95);
            \\     letter-spacing: -0.02em;
            \\ }
            \\ .metric-value.compact {
            \\     font-size: 20px;
            \\ }
            \\ .metric-label {
            \\     font-size: 12px;
            \\     font-weight: 600;
            \\     color: rgba(255, 255, 255, 0.85);
            \\ }
            \\ .metric-detail {
            \\     font-size: 11px;
            \\     color: rgba(255, 255, 255, 0.50);
            \\ }
            \\ .dim-label {
            \\     color: rgba(255, 255, 255, 0.55);
            \\ }
            \\ scrollbar slider {
            \\     background-color: rgba(255, 255, 255, 0.12);
            \\     border-radius: 4px;
            \\     min-width: 6px;
            \\     min-height: 6px;
            \\ }
            \\ scrollbar slider:hover {
            \\     background-color: rgba(255, 255, 255, 0.25);
            \\ }
            \\ popover > contents {
            \\     background-color: @surface2_color;
            \\     border: 1px solid @border_color;
            \\     border-radius: 10px;
            \\     box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
            \\ }
            \\ tooltip {
            \\     background-color: @surface2_color;
            \\     color: rgba(255, 255, 255, 0.90);
            \\     border: 1px solid @border_color;
            \\     border-radius: 6px;
            \\     box-shadow: 0 2px 8px rgba(0, 0, 0, 0.30);
            \\ }
            \\ splitview > separator {
            \\     background-color: @border_color;
            \\     min-width: 1px;
            \\ }
            \\ statuspage > scrolledwindow > viewport > box {
            \\     margin: 0;
            \\ }
        ;
        const provider = gtk.CssProvider.new();
        provider.loadFromString(css);
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.addProviderForDisplay(display, provider.as(gtk.StyleProvider), 600);
        }
        provider.unref();

        self.installActions();
        _ = gio.Application.signals.activate.connect(
            self.as(gio.Application),
            *Self,
            activateCallback,
            self,
            .{},
        );

        return self;
    }

    pub fn deinit(self: *Self) void {
        const priv = self.private();
        if (priv.did_deinit) return;
        priv.did_deinit = true;

        if (priv.main_window) |win| {
            win.unref();
            priv.main_window = null;
        }
        shortcuts.setCallback(null, null);
        priv.shortcut_bindings.deinit();
        priv.clipboard.deinit(priv.alloc);
        if (priv.palette) |p| {
            smithers.c.smithers_palette_free(p);
            priv.palette = null;
        }
        if (priv.client) |c| {
            smithers.c.smithers_client_free(c);
            priv.client = null;
        }
        if (priv.core_app) |app| {
            smithers.c.smithers_app_free(app);
            priv.core_app = null;
        }
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.private().alloc;
    }

    pub fn core(self: *Self) smithers.c.smithers_app_t {
        return self.private().core_app;
    }

    pub fn client(self: *Self) smithers.c.smithers_client_t {
        return self.private().client;
    }

    pub fn palette(self: *Self) smithers.c.smithers_palette_t {
        return self.private().palette;
    }

    pub fn run(self: *Self) !void {
        logx.event(log, "application_run_start", "", .{});
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) {
            log.err("glib MainContext acquire failed", .{});
            return error.ContextAcquireFailed;
        }
        defer glib.MainContext.release(ctx);

        var err: ?*glib.Error = null;
        if (self.as(gio.Application).register(null, &err) == 0) {
            if (err) |e| {
                defer e.free();
                log.err("failed to register application: {s}", .{e.f_message orelse "unknown"});
            }
            return error.ApplicationRegisterFailed;
        }

        self.as(gio.Application).activate();
        self.private().running = true;

        while (self.private().running) {
            _ = glib.MainContext.iteration(ctx, 1);
            if (self.private().core_app) |app| smithers.c.smithers_app_tick(app);
            if (self.private().main_window) |win| win.tick();
            self.drainPendingUiWork();

            const windows = @as(?*glib.List, self.as(gtk.Application).getWindows());
            if (windows == null and !self.private().opts.smoke) self.private().running = false;
        }

        while (glib.MainContext.iteration(ctx, 0) != 0) {}
    }

    pub fn quit(self: *Self) void {
        logx.event(log, "application_quit", "", .{});
        self.private().running = false;
        self.as(gio.Application).quit();
    }

    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }

    pub fn queueRefresh(self: *Self) void {
        self.private().needs_refresh.store(true, .seq_cst);
        self.wakeup();
    }

    pub fn showToast(self: *Self, title: []const u8) void {
        if (self.private().main_window) |win| win.showToast(title);
    }

    pub fn presentCommandPalette(self: *Self) void {
        if (self.private().main_window) |win| win.presentCommandPalette();
    }

    fn installActions(self: *Self) void {
        shortcuts.setCallback(actionShortcutActivated, self);
        shortcuts.register(self.as(adw.Application), self.private().shortcut_bindings);
    }

    fn drainPendingUiWork(self: *Self) void {
        if (!self.private().needs_refresh.swap(false, .seq_cst)) return;
        if (self.private().main_window) |win| win.refreshVisible();
    }

    fn ensureWindow(self: *Self) !*MainWindow {
        const priv = self.private();
        if (priv.main_window) |win| return win;

        const win = try MainWindow.new(self);
        priv.main_window = win.ref();
        win.unref();
        return priv.main_window.?;
    }

    fn activateCallback(_: *gio.Application, self: *Self) callconv(.c) void {
        logx.event(log, "application_activate", "", .{});
        const win = self.ensureWindow() catch |err| {
            logx.catchErr(log, "ensureWindow", err);
            self.quit();
            return;
        };
        win.as(gtk.Window).present();

        if (self.private().opts.show_palette) win.presentCommandPalette();
        if (self.private().opts.smoke) {
            _ = glib.timeoutAdd(750, smokeQuit, self);
        }
    }

    fn smokeQuit(userdata: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        self.quit();
        return 0;
    }

    fn actionShortcutActivated(action: shortcuts.Action, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return));
        self.handleShortcutAction(action);
    }

    fn handleShortcutAction(self: *Self, action: shortcuts.Action) void {
        switch (action) {
            .show_palette,
            .show_palette_command_mode,
            .show_palette_ask_ai,
            .show_shortcut_cheat_sheet,
            => self.presentCommandPalette(),

            .dismiss_palette => if (self.private().main_window) |win| win.dismissCommandPalette(),
            .new_tab, .split_right, .split_down => if (self.private().main_window) |win| win.presentNewTabPicker(),
            .close_tab => if (self.private().main_window) |win| win.closeCurrentSession(),
            .reopen_closed_tab => self.showToast("Reopen closed tab is not available yet"),

            .cycle_next_tab, .next_surface => if (self.private().main_window) |win| win.cycleSession(1),
            .cycle_prev_tab, .prev_surface => if (self.private().main_window) |win| win.cycleSession(-1),
            .select_workspace_by_number, .select_surface_by_number => self.showToast("Use the numbered workspace shortcuts"),
            .recent_workspace_1 => if (self.private().main_window) |win| win.openRecentWorkspace(0),
            .recent_workspace_2 => if (self.private().main_window) |win| win.openRecentWorkspace(1),
            .recent_workspace_3 => if (self.private().main_window) |win| win.openRecentWorkspace(2),
            .recent_workspace_4 => if (self.private().main_window) |win| win.openRecentWorkspace(3),
            .recent_workspace_5 => if (self.private().main_window) |win| win.openRecentWorkspace(4),

            .focus_sidebar => if (self.private().main_window) |win| win.focusSidebar(),
            .focus_content => if (self.private().main_window) |win| win.focusContent(),
            .toggle_sidebar => if (self.private().main_window) |win| win.toggleSidebar(),
            .open_settings => if (self.private().main_window) |win| win.showNav(.settings),
            .quit_app => self.quit(),
            .reload_workspace, .browser_reload => if (self.private().main_window) |win| win.refreshVisible(),
            .open_workspace => if (self.private().main_window) |win| win.showNav(.workspaces),
            .new_workspace => self.showToast("New workspace is not available yet"),
            .toggle_fullscreen => if (self.private().main_window) |win| win.toggleFullscreen(),

            .toggle_developer_debug => self.showToast("Developer debug is not available in this build"),
            .focus_left, .focus_up => if (self.private().main_window) |win| win.cycleSession(-1),
            .focus_right, .focus_down => if (self.private().main_window) |win| win.cycleSession(1),
            .toggle_split_zoom => self.showToast("Split zoom is not available yet"),
            .rename_workspace => self.showToast("Rename workspace is not available yet"),
            .rename_surface => self.showToast("Rename surface is not available yet"),
            .jump_to_unread => self.showToast("No unread pane is available"),
            .trigger_flash => self.showToast("Focused pane flash is not available yet"),
            .show_notifications => self.showToast("No notifications"),
            .focus_browser_address_bar => self.showToast("No browser surface is focused"),
            .browser_back, .go_back => self.showToast("Back is not available in this view"),
            .browser_forward, .go_forward => self.showToast("Forward is not available in this view"),
            .search_within_view, .global_search, .hide_find => self.presentCommandPalette(),
            .find_next => self.showToast("Find next is not available in this view"),
            .find_previous => self.showToast("Find previous is not available in this view"),
            .use_selection_for_find => self.showToast("Use selection for find is not available in this view"),
            .open_browser => self.showToast("Open browser surface is not available yet"),
            .cancel_current_operation => self.showToast("No cancellable operation"),
            .cancel_run => self.showToast("No run selection"),
            .rerun => self.showToast("No run selection"),
            .approve_selected => self.showToast("No approval selection"),
            .deny_selected => self.showToast("No approval selection"),
            .linear_navigation_prefix, .tmux_prefix => {},
        }
    }

    fn wakeupCallback(userdata: smithers.c.smithers_userdata_t) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return));
        self.wakeup();
    }

    fn stateChangedCallback(userdata: smithers.c.smithers_userdata_t) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return));
        self.queueRefresh();
    }

    fn actionCallback(
        app: smithers.c.smithers_app_t,
        target: smithers.c.smithers_action_target_s,
        action: smithers.c.smithers_action_s,
    ) callconv(.c) bool {
        const self: *Self = @ptrCast(@alignCast(smithers.c.smithers_app_userdata(app) orelse return false));
        switch (action.tag) {
            smithers.c.SMITHERS_ACTION_NONE => return true,
            smithers.c.SMITHERS_ACTION_OPEN_WORKSPACE => {
                const path = std.mem.span(action.u.open_workspace.path);
                if (self.private().main_window) |win| return win.workspaceOpenedFromCore(path);
                return false;
            },
            smithers.c.SMITHERS_ACTION_CLOSE_WORKSPACE => {
                if (self.private().main_window) |win| win.workspaceClosedFromCore();
                return true;
            },
            smithers.c.SMITHERS_ACTION_NEW_SESSION => {
                if (self.private().main_window) |win| {
                    if (targetSession(target)) |session| {
                        if (win.showSessionHandle(session)) return true;
                        if (win.isOpeningSession()) return true;
                        return (win.adoptSessionHandle(session) catch |err| {
                            logx.catchWarn(log, "adoptSessionHandle", err);
                            return false;
                        });
                    }
                    win.openSession(action.u.new_session.kind, null) catch |err| {
                        logx.catchWarn(log, "openSession from core action", err);
                        return false;
                    };
                    return true;
                }
                return false;
            },
            smithers.c.SMITHERS_ACTION_PRESENT_COMMAND_PALETTE => {
                self.presentCommandPalette();
                return true;
            },
            smithers.c.SMITHERS_ACTION_DISMISS_COMMAND_PALETTE => {
                if (self.private().main_window) |win| win.dismissCommandPalette();
                return true;
            },
            smithers.c.SMITHERS_ACTION_CLOSE_SESSION => {
                if (self.private().main_window) |win| {
                    const session = if (action.u.close_session.session != null) action.u.close_session.session else targetSession(target);
                    if (session) |handle| {
                        _ = win.closeSessionHandle(handle);
                    } else {
                        win.closeCurrentSession();
                    }
                }
                return true;
            },
            smithers.c.SMITHERS_ACTION_FOCUS_SESSION => {
                const session = targetSession(target) orelse return false;
                if (self.private().main_window) |win| return win.showSessionHandle(session);
                return false;
            },
            smithers.c.SMITHERS_ACTION_DESKTOP_NOTIFY => {
                const title = std.mem.span(action.u.desktop_notify.title);
                if (title.len > 0) self.showToast(title);
                return true;
            },
            smithers.c.SMITHERS_ACTION_RUN_STARTED, smithers.c.SMITHERS_ACTION_RUN_FINISHED, smithers.c.SMITHERS_ACTION_RUN_STATE_CHANGED, smithers.c.SMITHERS_ACTION_APPROVAL_REQUESTED, smithers.c.SMITHERS_ACTION_CONFIG_CHANGED => {
                self.queueRefresh();
                return true;
            },
            smithers.c.SMITHERS_ACTION_SHOW_TOAST => {
                const title = std.mem.span(action.u.toast.title);
                self.showToast(title);
                return true;
            },
            smithers.c.SMITHERS_ACTION_CLIPBOARD_WRITE => {
                writeClipboardCallback(self, action.u.clipboard_write.text);
                return true;
            },
            smithers.c.SMITHERS_ACTION_OPEN_URL => {
                var err: ?*glib.Error = null;
                const ok = gio.AppInfo.launchDefaultForUri(action.u.open_url.url, null, &err);
                if (err) |e| {
                    defer e.free();
                    log.warn("open url failed: {s}", .{e.f_message orelse "unknown"});
                }
                return ok != 0;
            },
            else => {
                log.warn("unhandled core action: {s}", .{smithers.actionName(action.tag)});
                return false;
            },
        }
    }

    fn targetSession(target: smithers.c.smithers_action_target_s) ?smithers.c.smithers_session_t {
        return switch (target.tag) {
            smithers.c.SMITHERS_ACTION_TARGET_SESSION => target.u.session,
            else => null,
        };
    }

    fn readClipboardCallback(
        userdata: smithers.c.smithers_userdata_t,
        out: [*c]smithers.c.smithers_string_s,
    ) callconv(.c) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        if (out == null) return false;

        self.refreshClipboardCache();
        const value = self.private().clipboard.borrowed() orelse return false;
        out.* = value;
        return true;
    }

    fn writeClipboardCallback(userdata: smithers.c.smithers_userdata_t, text: [*c]const u8) callconv(.c) void {
        if (text == null) return;
        const self: ?*Self = if (userdata) |ptr| @ptrCast(@alignCast(ptr)) else null;
        if (self) |app| {
            const slice = std.mem.span(text);
            app.private().clipboard.set(app.allocator(), slice) catch |err| {
                log.warn("failed to cache clipboard write: {}", .{err});
            };
        }

        const display = gdk.Display.getDefault() orelse return;
        display.getClipboard().setText(text);
    }

    fn refreshClipboardCache(self: *Self) void {
        const priv = self.private();
        if (priv.clipboard.read_pending) return;

        const display = gdk.Display.getDefault() orelse return;
        const request = priv.alloc.create(ClipboardReadRequest) catch |err| {
            log.warn("failed to allocate clipboard read request: {}", .{err});
            return;
        };
        request.* = .{ .app = self.ref() };
        priv.clipboard.read_pending = true;
        display.getClipboard().readTextAsync(null, clipboardReadText, request);
    }

    fn clipboardReadText(
        source: ?*gobject.Object,
        res: *gio.AsyncResult,
        userdata: ?*anyopaque,
    ) callconv(.c) void {
        const request: *ClipboardReadRequest = @ptrCast(@alignCast(userdata orelse return));
        const self = request.app;
        const alloc = self.allocator();
        const priv = self.private();
        defer self.unref();
        defer alloc.destroy(request);
        defer priv.clipboard.read_pending = false;

        const clipboard = gobject.ext.cast(gdk.Clipboard, source orelse return) orelse return;
        var err: ?*glib.Error = null;
        const cstr_ = clipboard.readTextFinish(res, &err);
        if (err) |e| {
            defer e.free();
            log.warn("failed to read clipboard: {s}", .{e.f_message orelse "unknown"});
            return;
        }
        const cstr = cstr_ orelse return;
        defer glib.free(cstr);

        const text = std.mem.sliceTo(cstr, 0);
        if (priv.did_deinit) return;
        priv.clipboard.set(alloc, text) catch |cache_err| {
            log.warn("failed to cache clipboard read: {}", .{cache_err});
        };
    }

    const ClipboardReadRequest = struct {
        app: *Self,
    };

    const CachedClipboard = struct {
        // GTK4 clipboard reads are async while libsmithers asks synchronously.
        // We return this borrowed cache to core and refresh it in the background.
        text: ?[:0]u8 = null,
        read_pending: bool = false,

        fn deinit(self: *CachedClipboard, alloc: std.mem.Allocator) void {
            if (self.text) |text| alloc.free(text);
            self.* = .{};
        }

        fn set(self: *CachedClipboard, alloc: std.mem.Allocator, text: []const u8) !void {
            const owned = try alloc.dupeZ(u8, text);
            if (self.text) |old| alloc.free(old);
            self.text = owned;
        }

        fn borrowed(self: *const CachedClipboard) ?smithers.c.smithers_string_s {
            const text = self.text orelse return null;
            return .{
                .ptr = text.ptr,
                .len = text.len,
            };
        }
    };

    fn logCallback(_: smithers.c.smithers_userdata_t, level: i32, msg: [*c]const u8) callconv(.c) void {
        const text = std.mem.span(msg);
        switch (level) {
            0, 1 => log.debug("{s}", .{text}),
            2 => log.info("{s}", .{text}),
            3 => log.warn("{s}", .{text}),
            else => log.err("{s}", .{text}),
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.deinit();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
    };
};
