const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const ShortcutRecorder = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersShortcutRecorder",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        button: *gtk.Button = undefined,
        label: *gtk.Label = undefined,
        shortcut: ?[]u8 = null,
        recording: bool = false,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, current: ?[]const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .shortcut = if (current) |shortcut_value| try alloc.dupe(u8, shortcut_value) else null,
        };
        try self.build();
        self.refreshLabel();
        return self;
    }

    pub fn value(self: *Self) ?[]const u8 {
        return self.private().shortcut;
    }

    fn build(self: *Self) !void {
        self.private().button = gtk.Button.new();
        self.private().button.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(self.private().button, *Self, clicked, self, .{});

        self.private().label = ui.label("Record shortcut", "monospace");
        self.private().button.setChild(self.private().label.as(gtk.Widget));

        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Self, keyPressed, self, .{});
        self.private().button.as(gtk.Widget).addController(controller.as(gtk.EventController));
        self.as(adw.Bin).setChild(self.private().button.as(gtk.Widget));
    }

    fn refreshLabel(self: *Self) void {
        const priv = self.private();
        if (priv.recording) {
            priv.label.setText("Press shortcut...");
        } else if (priv.shortcut) |shortcut| {
            const z = priv.alloc.dupeZ(u8, shortcut) catch return;
            defer priv.alloc.free(z);
            priv.label.setText(z.ptr);
        } else {
            priv.label.setText("None");
        }
    }

    fn clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().recording = true;
        self.refreshLabel();
        _ = self.private().button.as(gtk.Widget).grabFocus();
    }

    fn keyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        if (!priv.recording) return 0;
        if (keyval == gdk.KEY_Escape) {
            priv.recording = false;
            self.refreshLabel();
            return 1;
        }

        const formatted = formatShortcut(priv.alloc, keyval, mods) catch return 1;
        if (priv.shortcut) |old| priv.alloc.free(old);
        priv.shortcut = formatted;
        priv.recording = false;
        self.refreshLabel();
        return 1;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            if (priv.shortcut) |shortcut| priv.alloc.free(shortcut);
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

fn formatShortcut(alloc: std.mem.Allocator, keyval: c_uint, mods: gdk.ModifierType) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, 32);
    defer out.deinit();
    if (mods.control_mask) try out.writer.writeAll("Ctrl+");
    if (mods.shift_mask) try out.writer.writeAll("Shift+");
    if (mods.alt_mask) try out.writer.writeAll("Alt+");
    if (mods.super_mask) try out.writer.writeAll("Super+");
    const name = gdk.keyvalName(keyval) orelse "Unknown";
    try out.writer.writeAll(std.mem.span(name));
    return try out.toOwnedSlice();
}
