const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const logx = @import("../log.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.smithers_gtk_shortcut_recorder);

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
        root: *gtk.Box = undefined,
        button: *gtk.Button = undefined,
        label: *gtk.Label = undefined,
        status: *gtk.Label = undefined,
        shortcut: ?[]u8 = null,
        existing: std.ArrayList([]u8) = .empty,
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
        try self.seedFallbackConflicts();
        try self.build();
        self.refreshLabel();
        return self;
    }

    pub fn value(self: *Self) ?[]const u8 {
        return self.private().shortcut;
    }

    pub fn setExistingShortcuts(self: *Self, shortcuts: []const []const u8) !void {
        const priv = self.private();
        for (priv.existing.items) |shortcut| priv.alloc.free(shortcut);
        priv.existing.clearRetainingCapacity();
        for (shortcuts) |shortcut| try priv.existing.append(priv.alloc, try priv.alloc.dupe(u8, shortcut));
        self.refreshLabel();
    }

    pub fn saveAndApply(self: *Self) bool {
        return !self.hasConflict();
    }

    fn build(self: *Self) !void {
        self.private().root = gtk.Box.new(.vertical, 4);
        self.private().button = gtk.Button.new();
        self.private().button.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(self.private().button, *Self, clicked, self, .{});

        self.private().label = ui.label("Record shortcut", "monospace");
        self.private().button.setChild(self.private().label.as(gtk.Widget));
        self.private().root.append(self.private().button.as(gtk.Widget));

        self.private().status = ui.dim("No conflict");
        self.private().root.append(self.private().status.as(gtk.Widget));

        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Self, keyPressed, self, .{});
        self.private().button.as(gtk.Widget).addController(controller.as(gtk.EventController));
        self.as(adw.Bin).setChild(self.private().root.as(gtk.Widget));
    }

    fn refreshLabel(self: *Self) void {
        const priv = self.private();
        if (priv.recording) {
            priv.label.setText("Press shortcut...");
            priv.status.setText("Recording");
        } else if (priv.shortcut) |shortcut| {
            const z = priv.alloc.dupeZ(u8, shortcut) catch |err| {
                logx.catchWarn(log, "refreshLabel dupeZ", err);
                return;
            };
            defer priv.alloc.free(z);
            priv.label.setText(z.ptr);
            priv.status.setText(if (self.hasConflict()) "Conflict with existing binding" else "Ready");
        } else {
            priv.label.setText("None");
            priv.status.setText("No shortcut set");
        }
    }

    fn seedFallbackConflicts(self: *Self) !void {
        const defaults = [_][]const u8{
            "Ctrl+K",
            "Ctrl+Q",
            "Ctrl+W",
            "Ctrl+Shift+C",
            "Ctrl+Shift+V",
            "Alt+N",
            "Alt+P",
        };
        for (defaults) |shortcut| try self.private().existing.append(self.private().alloc, try self.private().alloc.dupe(u8, shortcut));
    }

    fn hasConflict(self: *Self) bool {
        const shortcut = self.private().shortcut orelse return false;
        for (self.private().existing.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, shortcut)) return true;
        }
        return false;
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

        const formatted = formatShortcut(priv.alloc, keyval, mods) catch |err| {
            logx.catchWarn(log, "formatShortcut", err);
            return 1;
        };
        if (priv.shortcut) |old| priv.alloc.free(old);
        priv.shortcut = formatted;
        priv.recording = false;
        logx.event(log, "shortcut_recorded", "value={s} conflict={}", .{ formatted, self.hasConflict() });
        self.refreshLabel();
        return 1;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            if (priv.shortcut) |shortcut| priv.alloc.free(shortcut);
            for (priv.existing.items) |shortcut| priv.alloc.free(shortcut);
            priv.existing.deinit(priv.alloc);
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
