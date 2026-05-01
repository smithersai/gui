const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const markdown = @import("markdown.zig");
const smithers = @import("../smithers.zig");
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
        paned: *gtk.Paned = undefined,
        buffer: *gtk.TextBuffer = undefined,
        text_view: *gtk.TextView = undefined,
        preview: *markdown.MarkdownSurface = undefined,
        status: *gtk.Label = undefined,
        content: []u8 = &.{},
        client: smithers.c.smithers_client_t = null,
        autosave_id: ?[]u8 = null,
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

    pub fn setAutosave(self: *Self, client: smithers.c.smithers_client_t, id: []const u8) !void {
        const priv = self.private();
        if (priv.autosave_id) |old| priv.alloc.free(old);
        priv.client = client;
        priv.autosave_id = try priv.alloc.dupe(u8, id);
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

        const toolbar = gtk.Box.new(.horizontal, 6);
        ui.margin4(toolbar.as(gtk.Widget), 8, 10, 8, 10);
        try self.addTool(toolbar, "format-text-bold-symbolic", "Bold (Ctrl+B)", .bold);
        try self.addTool(toolbar, "format-text-italic-symbolic", "Italic (Ctrl+I)", .italic);
        try self.addTool(toolbar, "format-text-heading-symbolic", "Heading (Ctrl+H)", .heading);
        try self.addTool(toolbar, "format-justify-fill-symbolic", "List", .list);
        try self.addTool(toolbar, "insert-text-symbolic", "Code (Ctrl+E)", .code);
        try self.addTool(toolbar, "insert-link-symbolic", "Link (Ctrl+L)", .link);
        priv.status = ui.dim("Split preview");
        priv.status.as(gtk.Widget).setHexpand(1);
        toolbar.append(priv.status.as(gtk.Widget));
        root.append(toolbar.as(gtk.Widget));

        priv.paned = gtk.Paned.new(.horizontal);
        priv.paned.as(gtk.Widget).setVexpand(1);
        priv.paned.setPosition(480);

        priv.buffer = gtk.TextBuffer.new(null);
        const z = try priv.alloc.dupeZ(u8, priv.content);
        defer priv.alloc.free(z);
        priv.buffer.setText(z.ptr, @intCast(priv.content.len));
        _ = gtk.TextBuffer.signals.changed.connect(priv.buffer, *Self, bufferChanged, self, .{});

        priv.text_view = gtk.TextView.new();
        priv.text_view.setBuffer(priv.buffer);
        priv.text_view.setMonospace(1);
        priv.text_view.setWrapMode(.word_char);
        priv.text_view.as(gtk.Widget).addCssClass("monospace");
        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Self, keyPressed, self, .{});
        priv.text_view.as(gtk.Widget).addController(controller.as(gtk.EventController));

        const editor_scroll = ui.scrolled(priv.text_view.as(gtk.Widget));
        editor_scroll.setPolicy(.automatic, .automatic);
        editor_scroll.as(gtk.Widget).setVexpand(1);
        priv.paned.setStartChild(editor_scroll.as(gtk.Widget));

        priv.preview = try markdown.MarkdownSurface.new(priv.alloc, priv.content);
        priv.paned.setEndChild(priv.preview.as(gtk.Widget));

        root.append(priv.paned.as(gtk.Widget));
        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    const Tool = enum { bold, italic, heading, list, code, link };

    fn addTool(self: *Self, toolbar: *gtk.Box, icon: [:0]const u8, tooltip: [:0]const u8, tool: Tool) !void {
        const button = ui.iconButton(icon, tooltip);
        ui.setIndex(button.as(gobject.Object), @intFromEnum(tool));
        _ = gtk.Button.signals.clicked.connect(button, *Self, toolClicked, self, .{});
        toolbar.append(button.as(gtk.Widget));
    }

    fn toolClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        self.applyTool(@enumFromInt(index)) catch {};
    }

    fn keyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (!mods.control_mask) return 0;
        const tool: ?Tool = switch (keyval) {
            gdk.KEY_b, gdk.KEY_B => .bold,
            gdk.KEY_i, gdk.KEY_I => .italic,
            gdk.KEY_h, gdk.KEY_H => .heading,
            gdk.KEY_e, gdk.KEY_E => .code,
            gdk.KEY_l, gdk.KEY_L => .link,
            else => null,
        };
        if (tool) |value| {
            self.applyTool(value) catch {};
            return 1;
        }
        return 0;
    }

    fn applyTool(self: *Self, tool: Tool) !void {
        switch (tool) {
            .bold => try self.wrapSelection("**", "**", "bold text"),
            .italic => try self.wrapSelection("*", "*", "italic text"),
            .heading => try self.prefixCurrentLine("## "),
            .list => try self.prefixCurrentLine("- "),
            .code => try self.wrapSelection("`", "`", "code"),
            .link => try self.wrapSelection("[", "](https://)", "link text"),
        }
    }

    fn wrapSelection(self: *Self, prefix: []const u8, suffix: []const u8, placeholder: []const u8) !void {
        const priv = self.private();
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        if (priv.buffer.getSelectionBounds(&start, &end) != 0) {
            const selected_ptr = priv.buffer.getText(&start, &end, 1);
            defer glib.free(selected_ptr);
            const selected = std.mem.span(selected_ptr);
            const replacement = try std.mem.concat(priv.alloc, u8, &.{ prefix, selected, suffix });
            defer priv.alloc.free(replacement);
            const z = try priv.alloc.dupeZ(u8, replacement);
            defer priv.alloc.free(z);
            priv.buffer.delete(&start, &end);
            priv.buffer.insert(&start, z.ptr, @intCast(replacement.len));
        } else {
            const replacement = try std.mem.concat(priv.alloc, u8, &.{ prefix, placeholder, suffix });
            defer priv.alloc.free(replacement);
            const z = try priv.alloc.dupeZ(u8, replacement);
            defer priv.alloc.free(z);
            priv.buffer.insertAtCursor(z.ptr, @intCast(replacement.len));
        }
    }

    fn prefixCurrentLine(self: *Self, prefix: []const u8) !void {
        const priv = self.private();
        var iter: gtk.TextIter = undefined;
        priv.buffer.getIterAtMark(&iter, priv.buffer.getInsert());
        iter.setLineOffset(0);
        const z = try priv.alloc.dupeZ(u8, prefix);
        defer priv.alloc.free(z);
        priv.buffer.insert(&iter, z.ptr, @intCast(prefix.len));
    }

    fn bufferChanged(_: *gtk.TextBuffer, self: *Self) callconv(.c) void {
        self.syncFromBuffer() catch {};
    }

    fn syncFromBuffer(self: *Self) !void {
        const priv = self.private();
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        priv.buffer.getBounds(&start, &end);
        const ptr = priv.buffer.getText(&start, &end, 1);
        defer glib.free(ptr);
        const text = std.mem.span(ptr);
        const owned = try priv.alloc.dupe(u8, text);
        priv.alloc.free(priv.content);
        priv.content = owned;
        try priv.preview.setMarkdown(text);
        self.autosave(text);
    }

    fn autosave(self: *Self, text: []const u8) void {
        const priv = self.private();
        const id = priv.autosave_id orelse return;
        if (priv.client == null) return;
        const args = autosaveArgs(priv.alloc, id, text) catch return;
        defer priv.alloc.free(args);
        const json = smithers.callJson(priv.alloc, priv.client, "saveMarkdown", args) catch {
            priv.status.setText("Autosave failed");
            return;
        };
        defer priv.alloc.free(json);
        priv.status.setText("Saved");
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            priv.alloc.free(priv.content);
            if (priv.autosave_id) |id| priv.alloc.free(id);
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

fn autosaveArgs(alloc: std.mem.Allocator, id: []const u8, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, text.len + id.len + 48);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("markdown");
    try jw.write(text);
    try jw.endObject();
    return try out.toOwnedSlice();
}
