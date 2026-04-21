const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");
const PropsTable = @import("props_table.zig").PropsTable;
const LogsViewer = @import("logs_viewer.zig").LogsViewer;
const LiveRunOutput = @import("live_run_output.zig").LiveRunOutput;

pub const NodeInspector = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersNodeInspector",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        title: *gtk.Label = undefined,
        subtitle: *gtk.Label = undefined,
        state: *gtk.Label = undefined,
        error_banner: *gtk.Label = undefined,
        props: *PropsTable = undefined,
        logs: *LogsViewer = undefined,
        output: *LiveRunOutput = undefined,
        diff: *LiveRunOutput = undefined,
        stack: *gtk.Stack = undefined,
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

    pub fn update(self: *Self, state: *const tree_state.LiveState) void {
        const priv = self.private();
        const node = state.selectedNodeConst();
        if (node) |n| {
            const title_z = std.fmt.allocPrintZ(priv.alloc, "<{s}>", .{n.name}) catch return;
            defer priv.alloc.free(title_z);
            priv.title.setText(title_z.ptr);

            const node_id = if (n.task) |task| task.node_id else "";
            const subtitle_z = std.fmt.allocPrintZ(priv.alloc, "node {d} {s}", .{ n.id, node_id }) catch return;
            defer priv.alloc.free(subtitle_z);
            priv.subtitle.setText(subtitle_z.ptr);

            const state_z = priv.alloc.dupeZ(u8, n.state().label()) catch return;
            defer priv.alloc.free(state_z);
            priv.state.setText(state_z.ptr);

            if (n.state() == .failed) {
                const error_text = n.stringProp("error") orelse "Task failed.";
                const error_z = std.fmt.allocPrintZ(priv.alloc, "Task Failed: {s}", .{error_text}) catch return;
                defer priv.alloc.free(error_z);
                priv.error_banner.setText(error_z.ptr);
                priv.error_banner.as(gtk.Widget).setVisible(1);
            } else {
                priv.error_banner.as(gtk.Widget).setVisible(0);
            }
        } else {
            priv.title.setText("Select a node to inspect");
            priv.subtitle.setText("");
            priv.state.setText("No selection");
            priv.error_banner.as(gtk.Widget).setVisible(0);
        }

        priv.props.update(node);
        priv.logs.update(state, node);
        priv.output.updateOutput(node);
        priv.diff.updateDiff(node);
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 0);

        const header = gtk.Box.new(.vertical, 3);
        ui.margin4(header.as(gtk.Widget), 10, 12, 10, 12);
        self.private().title = ui.heading("Select a node to inspect");
        self.private().title.setWrap(0);
        self.private().title.setEllipsize(.end);
        header.append(self.private().title.as(gtk.Widget));

        const meta = gtk.Box.new(.horizontal, 8);
        self.private().subtitle = ui.dim("");
        self.private().subtitle.setWrap(0);
        self.private().subtitle.setEllipsize(.middle);
        self.private().subtitle.as(gtk.Widget).setHexpand(1);
        meta.append(self.private().subtitle.as(gtk.Widget));
        self.private().state = ui.dim("No selection");
        meta.append(self.private().state.as(gtk.Widget));
        header.append(meta.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        self.private().error_banner = ui.label("", null);
        ui.margin4(self.private().error_banner.as(gtk.Widget), 8, 12, 8, 12);
        self.private().error_banner.as(gtk.Widget).setVisible(0);
        root.append(self.private().error_banner.as(gtk.Widget));

        const switcher = gtk.StackSwitcher.new();
        self.private().stack = gtk.Stack.new();
        self.private().stack.setTransitionType(.crossfade);
        switcher.setStack(self.private().stack);
        ui.margin4(switcher.as(gtk.Widget), 4, 12, 4, 12);
        root.append(switcher.as(gtk.Widget));

        self.private().props = try PropsTable.new(self.private().alloc);
        _ = self.private().stack.addTitled(self.private().props.as(gtk.Widget), "props", "Props");

        self.private().output = try LiveRunOutput.new(self.private().alloc, "Output");
        _ = self.private().stack.addTitled(self.private().output.as(gtk.Widget), "output", "Output");

        self.private().logs = try LogsViewer.new(self.private().alloc);
        _ = self.private().stack.addTitled(self.private().logs.as(gtk.Widget), "logs", "Logs");

        self.private().diff = try LiveRunOutput.new(self.private().alloc, "Diff");
        _ = self.private().stack.addTitled(self.private().diff.as(gtk.Widget), "diff", "Diff");

        self.private().stack.as(gtk.Widget).setVexpand(1);
        root.append(self.private().stack.as(gtk.Widget));
        self.private().stack.setVisibleChildName("logs");

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
