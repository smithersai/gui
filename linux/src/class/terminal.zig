const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const have_vte = false;
pub const dependency_status = "vte-2.91-gtk4 unavailable on this host; using GtkTextView fallback";

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
        buffer: *gtk.TextBuffer = undefined,
        entry: *gtk.Entry = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, session: smithers.c.smithers_session_t) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc, .session = session };
        try self.build();
        try self.appendOutput("Terminal backend: GtkTextView fallback\n");
        try self.appendOutput(dependency_status ++ "\n");
        return self;
    }

    pub fn appendOutput(self: *Self, text: []const u8) !void {
        const z = try self.private().alloc.dupeZ(u8, text);
        defer self.private().alloc.free(z);
        self.private().buffer.insertAtCursor(z.ptr, @intCast(text.len));
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 0);
        self.private().buffer = gtk.TextBuffer.new(null);
        const view = gtk.TextView.new();
        view.setBuffer(self.private().buffer);
        view.setEditable(0);
        view.setMonospace(1);
        view.setWrapMode(.char);
        view.as(gtk.Widget).addCssClass("monospace");
        const scroll = ui.scrolled(view.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));

        const input = gtk.Box.new(.horizontal, 8);
        ui.margin(input.as(gtk.Widget), 8);
        self.private().entry = gtk.Entry.new();
        self.private().entry.setPlaceholderText("Send text to terminal session");
        self.private().entry.as(gtk.Widget).setHexpand(1);
        _ = gtk.Entry.signals.activate.connect(self.private().entry, *Self, entryActivated, self, .{});
        input.append(self.private().entry.as(gtk.Widget));
        const send = ui.iconButton("mail-send-symbolic", "Send");
        _ = gtk.Button.signals.clicked.connect(send, *Self, sendClicked, self, .{});
        input.append(send.as(gtk.Widget));
        root.append(input.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn sendInput(self: *Self) void {
        const text = std.mem.span(self.private().entry.as(gtk.Editable).getText());
        if (text.len == 0) return;
        if (self.private().session) |session| {
            smithers.c.smithers_session_send_text(session, text.ptr, text.len);
        }
        self.appendOutput(text) catch {};
        self.appendOutput("\n") catch {};
        self.private().entry.as(gtk.Editable).setText("");
    }

    fn sendClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.sendInput();
    }

    fn entryActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.sendInput();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            priv.buffer.unref();
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
