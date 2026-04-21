const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const MainWindow = @import("main_window.zig").MainWindow;

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
        nav_list: *gtk.ListBox = undefined,
        session_list: *gtk.ListBox = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    const NavEntry = struct {
        nav: MainWindow.Nav,
        title: [:0]const u8,
        icon: [:0]const u8,
    };

    const nav_entries = [_]NavEntry{
        .{ .nav = .dashboard, .title = "Dashboard", .icon = "view-grid-symbolic" },
        .{ .nav = .workflows, .title = "Workflows", .icon = "media-playlist-shuffle-symbolic" },
        .{ .nav = .runs, .title = "Runs", .icon = "media-playback-start-symbolic" },
        .{ .nav = .approvals, .title = "Approvals", .icon = "security-high-symbolic" },
        .{ .nav = .agents, .title = "Agents", .icon = "system-users-symbolic" },
        .{ .nav = .workspaces, .title = "Workspaces", .icon = "folder-symbolic" },
        .{ .nav = .settings, .title = "Settings", .icon = "emblem-system-symbolic" },
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

        if (priv.window.activeWorkspace()) |path| {
            const z = alloc.dupeZ(u8, path) catch return;
            defer alloc.free(z);
            priv.workspace_label.setText(z.ptr);
        } else {
            priv.workspace_label.setText("No workspace");
        }

        ui.clearList(priv.nav_list);
        for (nav_entries, 0..) |entry, index| {
            const row = ui.row(alloc, entry.icon, entry.title, null) catch continue;
            ui.setIndex(row.as(gobject.Object), index);
            priv.nav_list.append(row.as(gtk.Widget));
        }

        ui.clearList(priv.session_list);
        const count = priv.window.sessionCount();
        if (count == 0) {
            const row = ui.row(alloc, "tab-new-symbolic", "No sessions", "Create one with Ctrl+N.") catch return;
            row.setSelectable(0);
            row.setActivatable(0);
            priv.session_list.append(row.as(gtk.Widget));
        } else {
            for (0..count) |index| {
                const session = priv.window.sessionAt(index) orelse continue;
                const title = session.title(alloc) catch fallback: {
                    break :fallback alloc.dupe(u8, "Session") catch continue;
                };
                defer alloc.free(title);
                const row = ui.row(alloc, session.iconName(), title, session.kindLabel()) catch continue;
                ui.setIndex(row.as(gobject.Object), index);
                priv.session_list.append(row.as(gtk.Widget));
            }
        }
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 12);
        ui.margin(root.as(gtk.Widget), 12);

        const header = gtk.Box.new(.horizontal, 6);
        const title = ui.heading("Smithers");
        title.as(gtk.Widget).setHexpand(1);
        header.append(title.as(gtk.Widget));
        const add = ui.iconButton("tab-new-symbolic", "New tab");
        _ = gtk.Button.signals.clicked.connect(add, *Self, newTabClicked, self, .{});
        header.append(add.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        self.private().workspace_label = ui.dim("No workspace");
        self.private().workspace_label.setEllipsize(.middle);
        root.append(self.private().workspace_label.as(gtk.Widget));

        const nav_title = ui.dim("NAVIGATION");
        root.append(nav_title.as(gtk.Widget));
        self.private().nav_list = gtk.ListBox.new();
        self.private().nav_list.as(gtk.Widget).addCssClass("navigation-sidebar");
        self.private().nav_list.setSelectionMode(.none);
        _ = gtk.ListBox.signals.row_activated.connect(
            self.private().nav_list,
            *Self,
            navActivated,
            self,
            .{},
        );
        root.append(self.private().nav_list.as(gtk.Widget));

        const sessions_title = ui.dim("SESSIONS");
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
        root.append(self.private().session_list.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn navActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = ui.getIndex(row.as(gobject.Object)) orelse return;
        if (index >= nav_entries.len) return;
        self.private().window.showNav(nav_entries[index].nav);
    }

    fn sessionActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = ui.getIndex(row.as(gobject.Object)) orelse return;
        self.private().window.showSession(index);
    }

    fn newTabClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
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
