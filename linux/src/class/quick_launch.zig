const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const QuickLaunchConfirmSheet = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersQuickLaunchConfirmSheet",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        dialog: *adw.Dialog = undefined,
        command_label: *gtk.Label = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, command: []const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc };
        try self.build(command);
        return self;
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        self.private().dialog.present(parent);
    }

    pub fn close(self: *Self) void {
        _ = self.private().dialog.close();
    }

    fn build(self: *Self, command: []const u8) !void {
        const priv = self.private();
        priv.dialog = adw.Dialog.new();
        priv.dialog.setTitle("Quick Launch");
        priv.dialog.setContentWidth(520);

        const root = gtk.Box.new(.vertical, 14);
        ui.margin(root.as(gtk.Widget), 18);
        root.append(ui.heading("Run command?").as(gtk.Widget));
        root.append(ui.dim("Review the command before it is sent to Smithers.").as(gtk.Widget));

        const command_z = try priv.alloc.dupeZ(u8, command);
        defer priv.alloc.free(command_z);
        priv.command_label = ui.label(command_z, "monospace");
        priv.command_label.setSelectable(1);
        priv.command_label.as(gtk.Widget).addCssClass("card");
        ui.margin(priv.command_label.as(gtk.Widget), 10);
        root.append(priv.command_label.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = ui.textButton("Cancel", false);
        _ = gtk.Button.signals.clicked.connect(cancel, *Self, cancelClicked, self, .{});
        buttons.append(cancel.as(gtk.Widget));
        const launch = ui.textButton("Launch", true);
        _ = gtk.Button.signals.clicked.connect(launch, *Self, launchClicked, self, .{});
        buttons.append(launch.as(gtk.Widget));
        root.append(buttons.as(gtk.Widget));

        priv.dialog.setChild(root.as(gtk.Widget));
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.close();
    }

    fn launchClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.close();
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
