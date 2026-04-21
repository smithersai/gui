const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

pub const LogsViewer = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveLogsViewer",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        header: *gtk.Label = undefined,
        text: *gtk.TextView = undefined,
        buffer: *gtk.TextBuffer = undefined,
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

    pub fn update(self: *Self, state: *const tree_state.LiveState, node: ?*const tree_state.Node) void {
        const priv = self.private();
        const node_id = if (node) |n| if (n.task) |task| task.node_id else null else null;
        var out: std.Io.Writer.Allocating = .init(priv.alloc);
        defer out.deinit();

        var rendered: usize = 0;
        for (state.logs.items) |block| {
            if (node_id) |id| {
                const block_node = block.node_id orelse continue;
                if (!std.mem.eql(u8, block_node, id) and !std.mem.startsWith(u8, block_node, id)) continue;
            }
            if (block.timestamp_ms) |ts| {
                out.writer.print("[{d}] ", .{ts}) catch {};
            }
            out.writer.print("{s}: {s}\n\n", .{ block.role, block.content }) catch {};
            rendered += 1;
        }

        const header_text = std.fmt.allocPrintZ(priv.alloc, "{d} log block{s}", .{ rendered, if (rendered == 1) "" else "s" }) catch return;
        defer priv.alloc.free(header_text);
        priv.header.setText(header_text.ptr);

        const written = out.written();
        if (written.len == 0) {
            priv.buffer.setText("No transcript yet.", -1);
        } else {
            const z = priv.alloc.dupeZ(u8, written) catch return;
            defer priv.alloc.free(z);
            priv.buffer.setText(z.ptr, @intCast(written.len));
        }
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 8);
        self.private().header = ui.dim("0 log blocks");
        root.append(self.private().header.as(gtk.Widget));

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
