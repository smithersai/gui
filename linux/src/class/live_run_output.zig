const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

pub const LiveRunOutput = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveRunOutput",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        title: *gtk.Label = undefined,
        text: *gtk.TextView = undefined,
        buffer: *gtk.TextBuffer = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, title_text: [:0]const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc };
        try self.build(title_text);
        return self;
    }

    pub fn updateOutput(self: *Self, node: ?*const tree_state.Node) void {
        self.updateProp(node, "output", "Output is pending.");
    }

    pub fn updateDiff(self: *Self, node: ?*const tree_state.Node) void {
        self.updateProp(node, "diff", "No diff for this node.");
    }

    fn updateProp(self: *Self, node: ?*const tree_state.Node, key: []const u8, fallback: [:0]const u8) void {
        const priv = self.private();
        const target = node orelse {
            priv.buffer.setText("Select a task node.", -1);
            return;
        };
        const value = target.stringProp(key) orelse {
            priv.buffer.setText(fallback.ptr, -1);
            return;
        };
        const z = priv.alloc.dupeZ(u8, value) catch return;
        defer priv.alloc.free(z);
        priv.buffer.setText(z.ptr, @intCast(value.len));
    }

    fn build(self: *Self, title_text: [:0]const u8) !void {
        const root = gtk.Box.new(.vertical, 8);
        self.private().title = ui.dim(title_text);
        root.append(self.private().title.as(gtk.Widget));

        self.private().buffer = gtk.TextBuffer.new(null);
        self.private().text = gtk.TextView.newWithBuffer(self.private().buffer);
        self.private().text.setEditable(0);
        self.private().text.setMonospace(1);
        self.private().text.setWrapMode(.word_char);
        const scroll = ui.scrolled(self.private().text.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));
        self.as(adw.Bin).setChild(root.as(gtk.Widget));
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
