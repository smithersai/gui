const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

pub const PropsTable = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLivePropsTable",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        list: *gtk.ListBox = undefined,
        empty: *gtk.Label = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc };
        try self.build();
        return self;
    }

    pub fn update(self: *Self, node: ?*const tree_state.Node) void {
        const priv = self.private();
        priv.list.removeAll();

        const target = node orelse {
            priv.empty.setText("Select a node to inspect props.");
            priv.empty.as(gtk.Widget).setVisible(1);
            return;
        };

        if (target.props.items.len == 0) {
            priv.empty.setText("No props");
            priv.empty.as(gtk.Widget).setVisible(1);
            return;
        }

        priv.empty.as(gtk.Widget).setVisible(0);
        for (target.props.items) |prop| {
            const row = propRow(priv.alloc, prop) catch continue;
            priv.list.append(row.as(gtk.Widget));
        }
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 8);
        self.private().empty = ui.dim("No props");
        root.append(self.private().empty.as(gtk.Widget));

        self.private().list = gtk.ListBox.new();
        self.private().list.setSelectionMode(.none);
        self.private().list.as(gtk.Widget).addCssClass("boxed-list");
        root.append(self.private().list.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn propRow(alloc: std.mem.Allocator, prop: tree_state.Prop) !*gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.setActivatable(0);

        const box = gtk.Box.new(.horizontal, 10);
        ui.margin4(box.as(gtk.Widget), 6, 8, 6, 8);

        const key_z = try alloc.dupeZ(u8, prop.key);
        defer alloc.free(key_z);
        const key = ui.label(key_z, "monospace");
        key.as(gtk.Widget).setSizeRequest(120, -1);
        key.setWrap(0);
        key.setEllipsize(.end);
        box.append(key.as(gtk.Widget));

        const value_z = try alloc.dupeZ(u8, prop.rendered);
        defer alloc.free(value_z);
        const value = ui.label(value_z, null);
        value.as(gtk.Widget).setHexpand(1);
        value.setSelectable(1);
        value.setWrap(1);
        value.setWrapMode(.word_char);
        box.append(value.as(gtk.Widget));

        row.setChild(box.as(gtk.Widget));
        return row;
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
