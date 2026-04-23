const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const logx = @import("../log.zig");
const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const MainWindow = @import("main_window.zig").MainWindow;

const log = std.log.scoped(.smithers_gtk_new_tab_picker);

pub const NewTabPicker = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersNewTabPicker",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        dialog: *adw.Dialog = undefined,
        list: *gtk.ListBox = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    const Entry = struct {
        title: [:0]const u8,
        subtitle: [:0]const u8,
        icon: [:0]const u8,
        kind: smithers.c.smithers_session_kind_e,
    };

    const entries = [_]Entry{
        .{ .title = "Terminal", .subtitle = "Start a terminal-backed session", .icon = "utilities-terminal-symbolic", .kind = smithers.c.SMITHERS_SESSION_KIND_TERMINAL },
        .{ .title = "Chat", .subtitle = "Open a markdown chat session", .icon = "mail-message-new-symbolic", .kind = smithers.c.SMITHERS_SESSION_KIND_CHAT },
        .{ .title = "Run Inspector", .subtitle = "Open a read-only run inspector tab", .icon = "view-list-symbolic", .kind = smithers.c.SMITHERS_SESSION_KIND_RUN_INSPECT },
        .{ .title = "Workflow", .subtitle = "Open a workflow-focused tab", .icon = "media-playlist-shuffle-symbolic", .kind = smithers.c.SMITHERS_SESSION_KIND_WORKFLOW },
        .{ .title = "Dashboard", .subtitle = "Open a dashboard tab", .icon = "view-grid-symbolic", .kind = smithers.c.SMITHERS_SESSION_KIND_DASHBOARD },
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().window = window;
        try self.build();
        return self;
    }

    pub fn present(self: *Self) void {
        logx.event(log, "new_tab_picker_opened", "", .{});
        self.private().dialog.present(self.private().window.as(gtk.Widget));
    }

    fn build(self: *Self) !void {
        const priv = self.private();
        priv.dialog = adw.Dialog.new();
        priv.dialog.setTitle("New Tab");
        priv.dialog.setContentWidth(460);
        priv.dialog.setContentHeight(420);

        const box = gtk.Box.new(.vertical, 12);
        ui.margin(box.as(gtk.Widget), 18);
        box.append(ui.heading("New Tab").as(gtk.Widget));
        box.append(ui.dim("Choose the Smithers session type to open.").as(gtk.Widget));

        priv.list = gtk.ListBox.new();
        priv.list.as(gtk.Widget).addCssClass("boxed-list");
        priv.list.setSelectionMode(.none);
        priv.list.setShowSeparators(1);
        for (entries, 0..) |entry, index| {
            const row = try ui.row(priv.window.allocator(), entry.icon, entry.title, entry.subtitle);
            ui.setIndex(row.as(gobject.Object), index);
            priv.list.append(row.as(gtk.Widget));
        }
        _ = gtk.ListBox.signals.row_activated.connect(priv.list, *Self, rowActivated, self, .{});
        box.append(priv.list.as(gtk.Widget));
        priv.dialog.setChild(box.as(gtk.Widget));
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = ui.getIndex(row.as(gobject.Object)) orelse {
            log.debug("rowActivated missing index", .{});
            return;
        };
        if (index >= entries.len) return;
        logx.event(log, "new_tab_picker_selected", "index={d} title={s}", .{ index, entries[index].title });
        _ = self.private().dialog.close();
        self.private().window.openSession(entries[index].kind, null) catch |err| {
            logx.catchWarn(log, "new_tab_picker.openSession", err);
            self.private().window.showToastFmt("Unable to open tab: {}", .{err});
        };
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            priv.dialog.setChild(null);
            priv.dialog.forceClose();
            priv.dialog.unref();
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
