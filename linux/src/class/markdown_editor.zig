const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const markdown = @import("markdown.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const MarkdownEditor = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersMarkdownEditor",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        stack: *gtk.Stack = undefined,
        buffer: *gtk.TextBuffer = undefined,
        text_view: *gtk.TextView = undefined,
        preview: *markdown.MarkdownSurface = undefined,
        content: []u8 = &.{},
        preview_visible: bool = false,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, content: []const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .content = try alloc.dupe(u8, content),
        };
        try self.build();
        return self;
    }

    pub fn setMarkdown(self: *Self, content: []const u8) !void {
        const priv = self.private();
        const owned = try priv.alloc.dupe(u8, content);
        priv.alloc.free(priv.content);
        priv.content = owned;
        const z = try priv.alloc.dupeZ(u8, content);
        defer priv.alloc.free(z);
        priv.buffer.setText(z.ptr, @intCast(content.len));
        try priv.preview.setMarkdown(content);
    }

    fn build(self: *Self) !void {
        const priv = self.private();
        const root = gtk.Box.new(.vertical, 0);

        const toolbar = gtk.Box.new(.horizontal, 8);
        ui.margin4(toolbar.as(gtk.Widget), 8, 10, 8, 10);
        const edit = ui.iconButton("document-edit-symbolic", "Edit markdown");
        ui.setIndex(edit.as(gobject.Object), 0);
        _ = gtk.Button.signals.clicked.connect(edit, *Self, modeClicked, self, .{});
        toolbar.append(edit.as(gtk.Widget));
        const preview = ui.iconButton("view-paged-symbolic", "Preview markdown");
        ui.setIndex(preview.as(gobject.Object), 1);
        _ = gtk.Button.signals.clicked.connect(preview, *Self, modeClicked, self, .{});
        toolbar.append(preview.as(gtk.Widget));
        root.append(toolbar.as(gtk.Widget));

        priv.stack = gtk.Stack.new();
        priv.stack.setTransitionType(.crossfade);
        priv.stack.as(gtk.Widget).setVexpand(1);

        priv.buffer = gtk.TextBuffer.new(null);
        const z = try priv.alloc.dupeZ(u8, priv.content);
        defer priv.alloc.free(z);
        priv.buffer.setText(z.ptr, @intCast(priv.content.len));
        priv.text_view = gtk.TextView.new();
        priv.text_view.setBuffer(priv.buffer);
        priv.text_view.setMonospace(1);
        priv.text_view.setWrapMode(.word_char);
        priv.text_view.as(gtk.Widget).addCssClass("monospace");
        const editor_scroll = ui.scrolled(priv.text_view.as(gtk.Widget));
        editor_scroll.as(gtk.Widget).setVexpand(1);
        _ = priv.stack.addTitled(editor_scroll.as(gtk.Widget), "edit", "Edit");

        priv.preview = try markdown.MarkdownSurface.new(priv.alloc, priv.content);
        _ = priv.stack.addTitled(priv.preview.as(gtk.Widget), "preview", "Preview");
        priv.stack.setVisibleChildName("edit");

        root.append(priv.stack.as(gtk.Widget));
        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn modeClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        const priv = self.private();
        if (index == 0) {
            priv.preview_visible = false;
            priv.stack.setVisibleChildName("edit");
        } else {
            priv.preview_visible = true;
            priv.preview.setMarkdown(priv.content) catch {};
            priv.stack.setVisibleChildName("preview");
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            priv.alloc.free(priv.content);
            priv.preview.unref();
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
