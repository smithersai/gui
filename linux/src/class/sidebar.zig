const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const logx = @import("../log.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const MainWindow = @import("main_window.zig").MainWindow;

const log = std.log.scoped(.smithers_gtk_sidebar);

pub const Sidebar = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersSidebar",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        workspace_label: *gtk.Label = undefined,
        dashboard_list: *gtk.ListBox = undefined,
        session_list: *gtk.ListBox = undefined,
        settings_list: *gtk.ListBox = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().window = window;
        try self.build();
        self.refresh();
        return self;
    }

    pub fn refresh(self: *Self) void {
        const priv = self.private();
        const alloc = priv.window.allocator();
        const count = priv.window.sessionCount();
        logx.event(log, "sidebar_refresh", "sessions={d}", .{count});

        if (priv.window.activeWorkspace()) |path| {
            const z = alloc.dupeZ(u8, path) catch |err| {
                logx.catchWarn(log, "sidebar.refresh workspace dupeZ", err);
                return;
            };
            defer alloc.free(z);
            priv.workspace_label.setText(z.ptr);
            priv.workspace_label.as(gtk.Widget).setVisible(1);
        } else {
            priv.workspace_label.as(gtk.Widget).setVisible(0);
        }

        ui.clearList(priv.dashboard_list);
        const dash_row = ui.row(alloc, "view-grid-symbolic", "Dashboard", null) catch |err| {
            logx.catchWarn(log, "sidebar.refresh dashboard row", err);
            return;
        };
        priv.dashboard_list.append(dash_row.as(gtk.Widget));

        ui.clearList(priv.settings_list);
        const set_row = ui.row(alloc, "emblem-system-symbolic", "Settings", null) catch |err| {
            logx.catchWarn(log, "sidebar.refresh settings row", err);
            return;
        };
        priv.settings_list.append(set_row.as(gtk.Widget));

        ui.clearList(priv.session_list);
        if (count == 0) {
            const row = ui.row(alloc, "tab-new-symbolic", "No sessions", "Create one with Ctrl+N.") catch |err| {
                logx.catchWarn(log, "sidebar.refresh empty row", err);
                return;
            };
            row.as(gtk.ListBoxRow).setSelectable(0);
            row.as(gtk.ListBoxRow).setActivatable(0);
            priv.session_list.append(row.as(gtk.Widget));
        } else {
            for (0..count) |index| {
                const session = priv.window.sessionAt(index) orelse continue;
                const title = session.title(alloc) catch fallback: {
                    logx.catchDebug(log, "sidebar.refresh session title", error.TitleFailed);
                    break :fallback alloc.dupe(u8, "Session") catch |err| {
                        logx.catchWarn(log, "sidebar.refresh session title fallback", err);
                        continue;
                    };
                };
                defer alloc.free(title);
                const row = ui.row(alloc, session.iconName(), title, session.kindLabel()) catch |err| {
                    logx.catchWarn(log, "sidebar.refresh session row", err);
                    continue;
                };
                ui.setIndex(row.as(gobject.Object), index);
                priv.session_list.append(row.as(gtk.Widget));
            }
        }
    }

    fn build(self: *Self) !void {
        const outer = gtk.Box.new(.vertical, 0);

        const root = gtk.Box.new(.vertical, 6);
        ui.margin4(root.as(gtk.Widget), 14, 8, 8, 8);
        root.as(gtk.Widget).setVexpand(1);

        const header = gtk.Box.new(.horizontal, 6);
        ui.margin4(header.as(gtk.Widget), 0, 4, 6, 4);
        const title = ui.heading("Smithers");
        title.as(gtk.Widget).setHexpand(1);
        header.append(title.as(gtk.Widget));
        const add = ui.iconButton("tab-new-symbolic", "New tab");
        _ = gtk.Button.signals.clicked.connect(add, *Self, newTabClicked, self, .{});
        header.append(add.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        self.private().workspace_label = ui.label("No workspace", "dim-label");
        self.private().workspace_label.setEllipsize(.middle);
        ui.margin4(self.private().workspace_label.as(gtk.Widget), 0, 4, 8, 4);
        root.append(self.private().workspace_label.as(gtk.Widget));

        self.private().dashboard_list = gtk.ListBox.new();
        self.private().dashboard_list.as(gtk.Widget).addCssClass("navigation-sidebar");
        self.private().dashboard_list.setSelectionMode(.none);
        _ = gtk.ListBox.signals.row_activated.connect(
            self.private().dashboard_list,
            *Self,
            dashboardActivated,
            self,
            .{},
        );
        root.append(self.private().dashboard_list.as(gtk.Widget));

        const sessions_title = ui.label("SESSIONS", "caption");
        ui.margin4(sessions_title.as(gtk.Widget), 14, 4, 4, 12);
        root.append(sessions_title.as(gtk.Widget));
        self.private().session_list = gtk.ListBox.new();
        self.private().session_list.as(gtk.Widget).addCssClass("navigation-sidebar");
        self.private().session_list.setSelectionMode(.none);
        _ = gtk.ListBox.signals.row_activated.connect(
            self.private().session_list,
            *Self,
            sessionActivated,
            self,
            .{},
        );
        
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setChild(self.private().session_list.as(gtk.Widget));
        root.append(scroll.as(gtk.Widget));

        outer.append(root.as(gtk.Widget));

        const sep = gtk.Separator.new(.horizontal);
        outer.append(sep.as(gtk.Widget));

        self.private().settings_list = gtk.ListBox.new();
        self.private().settings_list.as(gtk.Widget).addCssClass("navigation-sidebar");
        self.private().settings_list.setSelectionMode(.none);
        ui.margin4(self.private().settings_list.as(gtk.Widget), 12, 12, 12, 12);
        _ = gtk.ListBox.signals.row_activated.connect(
            self.private().settings_list,
            *Self,
            settingsActivated,
            self,
            .{},
        );
        outer.append(self.private().settings_list.as(gtk.Widget));

        self.as(adw.Bin).setChild(outer.as(gtk.Widget));
    }

    fn dashboardActivated(_: *gtk.ListBox, _: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        logx.event(log, "sidebar_nav", "target=dashboard", .{});
        self.private().window.showNav(.dashboard);
    }

    fn settingsActivated(_: *gtk.ListBox, _: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        logx.event(log, "sidebar_nav", "target=settings", .{});
        self.private().window.showNav(.settings);
    }

    fn sessionActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = ui.getIndex(row.as(gobject.Object)) orelse {
            log.debug("sessionActivated missing index", .{});
            return;
        };
        logx.event(log, "sidebar_session_selected", "index={d}", .{index});
        self.private().window.showSession(index);
    }

    fn newTabClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        logx.event(log, "sidebar_new_tab_clicked", "", .{});
        self.private().window.presentNewTabPicker();
    }

    fn dispose(self: *Self) callconv(.c) void {
        if (!self.private().did_dispose) {
            self.private().did_dispose = true;
            self.as(adw.Bin).setChild(null);
        }
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
