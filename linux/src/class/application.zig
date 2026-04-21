const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const App = @import("../App.zig");
const Common = @import("../class.zig").Common;
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
        running: bool = false,
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

        _ = smithers.c.smithers_init(0, null);

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
        priv.palette = smithers.c.smithers_palette_new(priv.core_app);

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
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;
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

            const windows = @as(?*glib.List, self.as(gtk.Application).getWindows());
            if (windows == null and !self.private().opts.smoke) self.private().running = false;
        }
    }

    pub fn quit(self: *Self) void {
        self.private().running = false;
        self.as(gio.Application).quit();
    }

    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }

    pub fn showToast(self: *Self, title: []const u8) void {
        if (self.private().main_window) |win| win.showToast(title);
    }

    pub fn presentCommandPalette(self: *Self) void {
        if (self.private().main_window) |win| win.presentCommandPalette();
    }

    fn installActions(self: *Self) void {
        const palette_action = gio.SimpleAction.new("command-palette", null);
        _ = gio.SimpleAction.signals.activate.connect(
            palette_action,
            *Self,
            actionPresentPalette,
            self,
            .{},
        );
        self.as(gio.ActionMap).addAction(palette_action.as(gio.Action));

        const new_tab_action = gio.SimpleAction.new("new-tab", null);
        _ = gio.SimpleAction.signals.activate.connect(
            new_tab_action,
            *Self,
            actionNewTab,
            self,
            .{},
        );
        self.as(gio.ActionMap).addAction(new_tab_action.as(gio.Action));

        const palette_accels = [_:null]?[*:0]const u8{"<Control>k"};
        self.as(gtk.Application).setAccelsForAction("app.command-palette", &palette_accels);
        const new_tab_accels = [_:null]?[*:0]const u8{"<Control>t"};
        self.as(gtk.Application).setAccelsForAction("app.new-tab", &new_tab_accels);
    }

    fn ensureWindow(self: *Self) !*MainWindow {
        const priv = self.private();
        if (priv.main_window) |win| return win;

        const win = try MainWindow.new(self);
        priv.main_window = win.ref();
        return win;
    }

    fn activateCallback(_: *gio.Application, self: *Self) callconv(.c) void {
        const win = self.ensureWindow() catch |err| {
            log.err("failed to create main window: {}", .{err});
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

    fn actionPresentPalette(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.presentCommandPalette();
    }

    fn actionNewTab(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        if (self.private().main_window) |win| win.presentNewTabPicker();
    }

    fn wakeupCallback(userdata: smithers.c.smithers_userdata_t) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return));
        self.wakeup();
    }

    fn stateChangedCallback(userdata: smithers.c.smithers_userdata_t) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return));
        if (self.private().main_window) |win| win.refreshVisible();
    }

    fn actionCallback(
        _: smithers.c.smithers_app_t,
        _: smithers.c.smithers_action_target_s,
        action: smithers.c.smithers_action_s,
    ) callconv(.c) bool {
        const app = gio.Application.getDefault() orelse return false;
        const self = gobject.ext.cast(Self, app) orelse return false;
        switch (action.tag) {
            smithers.c.SMITHERS_ACTION_OPEN_WORKSPACE => {
                const path = std.mem.span(action.u.open_workspace.path);
                if (self.private().main_window) |win| win.openWorkspace(path) catch return false;
                return true;
            },
            smithers.c.SMITHERS_ACTION_PRESENT_COMMAND_PALETTE => {
                self.presentCommandPalette();
                return true;
            },
            smithers.c.SMITHERS_ACTION_DISMISS_COMMAND_PALETTE => return true,
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

    fn readClipboardCallback(_: smithers.c.smithers_userdata_t, _: [*c]smithers.c.smithers_string_s) callconv(.c) bool {
        return false;
    }

    fn writeClipboardCallback(_: smithers.c.smithers_userdata_t, text: [*c]const u8) callconv(.c) void {
        const display = gdk.Display.getDefault() orelse return;
        display.getClipboard().setText(text);
    }

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
