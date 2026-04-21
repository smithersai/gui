const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const browser_surface = @import("browser_surface.zig");
const smithers = @import("../smithers.zig");
const terminal = @import("terminal.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const DeveloperDebugView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersDeveloperDebugView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        list: *gtk.ListBox = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc };
        try self.build();
        try self.refresh();
        return self;
    }

    pub fn refresh(self: *Self) !void {
        const priv = self.private();
        ui.clearList(priv.list);
        const info = smithers.c.smithers_info();
        try self.addRow("libsmithers version", std.mem.span(info.version));
        try self.addRow("libsmithers commit", std.mem.span(info.commit));
        try self.addRow("platform", switch (info.platform) {
            smithers.c.SMITHERS_PLATFORM_LINUX => "linux",
            smithers.c.SMITHERS_PLATFORM_MACOS => "macos",
            else => "invalid",
        });
        try self.addRow("terminal backend", if (terminal.have_vte) "vte-gtk4" else terminal.dependency_status);
        try self.addRow("browser backend", if (browser_surface.have_webkit) "webkitgtk-6.0" else browser_surface.dependency_status);
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 12);
        ui.margin(root.as(gtk.Widget), 18);
        const header = gtk.Box.new(.horizontal, 8);
        header.append(ui.heading("Developer Debug").as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh diagnostics");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        self.private().list = gtk.ListBox.new();
        self.private().list.as(gtk.Widget).addCssClass("boxed-list");
        self.private().list.setSelectionMode(.none);
        self.private().list.setShowSeparators(1);
        root.append(self.private().list.as(gtk.Widget));
        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn addRow(self: *Self, label: []const u8, value: []const u8) !void {
        const priv = self.private();
        const row = gtk.ListBoxRow.new();
        const box = gtk.Box.new(.horizontal, 12);
        ui.margin(box.as(gtk.Widget), 10);
        const label_z = try priv.alloc.dupeZ(u8, label);
        defer priv.alloc.free(label_z);
        const value_z = try priv.alloc.dupeZ(u8, value);
        defer priv.alloc.free(value_z);
        const left = ui.label(label_z, "dim-label");
        left.setWidthChars(22);
        box.append(left.as(gtk.Widget));
        const right = ui.label(value_z, "monospace");
        right.setSelectable(1);
        right.as(gtk.Widget).setHexpand(1);
        box.append(right.as(gtk.Widget));
        row.setChild(box.as(gtk.Widget));
        priv.list.append(row.as(gtk.Widget));
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh() catch {};
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
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
