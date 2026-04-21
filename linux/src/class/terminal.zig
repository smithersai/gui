const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ghostty = @import("../features/ghostty.zig");
const smithers = @import("../smithers.zig");
const Common = @import("../class.zig").Common;

pub const have_vte = false;
pub const dependency_status = "ghostty GTK surface embedded";

pub const TerminalSurface = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersTerminalSurface",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        session: smithers.c.smithers_session_t = null,
        surface: ?*ghostty.Surface = null,
        widget: ?*gtk.Widget = null,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, session: smithers.c.smithers_session_t) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc, .session = session };
        try self.build();
        return self;
    }

    pub fn appendOutput(_: *Self, _: []const u8) !void {
        // Ghostty owns terminal IO/rendering. This method remains for the
        // previous fallback interface and is intentionally a no-op.
    }

    pub fn resize(self: *Self, _: usize, _: usize) void {
        if (self.private().surface) |surface| ghostty.redraw(surface);
    }

    pub fn copySelection(self: *Self) bool {
        const surface = self.private().surface orelse return false;
        return ghostty.bindingAction(surface, "copy_to_clipboard");
    }

    pub fn pasteFromClipboard(self: *Self) bool {
        const surface = self.private().surface orelse return false;
        return ghostty.bindingAction(surface, "paste_from_clipboard");
    }

    pub fn title(self: *Self) ?[*:0]const u8 {
        const surface = self.private().surface orelse return null;
        return ghostty.title(surface);
    }

    fn build(self: *Self) !void {
        const surface = try ghostty.newSurface();
        errdefer ghostty.freeSurface(surface);

        const widget = ghostty.widget(surface);
        widget.setHexpand(1);
        widget.setVexpand(1);
        widget.setFocusOnClick(1);

        self.private().surface = surface;
        self.private().widget = widget;
        self.as(adw.Bin).setChild(widget);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            if (priv.surface) |surface| {
                ghostty.freeSurface(surface);
                priv.surface = null;
            }
            priv.widget = null;
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
