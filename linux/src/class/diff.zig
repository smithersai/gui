const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const diff_hunk = @import("diff_hunk.zig");
const diff_parser = @import("../features/diff_parser.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const UnifiedDiffView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersUnifiedDiffView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        body: *gtk.Box = undefined,
        diff_text: []u8 = &.{},
        parsed: ?diff_parser.Result = null,
        expanded: bool = true,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, diff_text: []const u8, path: []const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .diff_text = try alloc.dupe(u8, diff_text),
        };
        try self.build();
        try self.parseAndRender(path);
        return self;
    }

    pub fn setDiff(self: *Self, diff_text: []const u8, path: []const u8) !void {
        const priv = self.private();
        const owned = try priv.alloc.dupe(u8, diff_text);
        priv.alloc.free(priv.diff_text);
        priv.diff_text = owned;
        try self.parseAndRender(path);
    }

    fn build(self: *Self) !void {
        const body = gtk.Box.new(.vertical, 12);
        ui.margin(body.as(gtk.Widget), 14);
        self.private().body = body;
        const scroll = ui.scrolled(body.as(gtk.Widget));
        scroll.setPolicy(.automatic, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        self.as(adw.Bin).setChild(scroll.as(gtk.Widget));
    }

    fn parseAndRender(self: *Self, path: []const u8) !void {
        const priv = self.private();
        if (priv.parsed) |*parsed| parsed.deinit(priv.alloc);
        priv.parsed = try diff_parser.parse(priv.alloc, priv.diff_text, .{ .path = path, .strict = false });
        try self.render();
    }

    fn render(self: *Self) !void {
        const priv = self.private();
        ui.clearBox(priv.body);
        const parsed = priv.parsed orelse {
            priv.body.append(ui.dim("(no changes)").as(gtk.Widget));
            return;
        };

        if (parsed.file.hunks.items.len == 0 and !parsed.file.is_binary) {
            priv.body.append(ui.dim("(no changes)").as(gtk.Widget));
            return;
        }

        priv.body.append((try fileHeader(priv.alloc, parsed.file)).as(gtk.Widget));
        if (parsed.file.partial_parse) {
            priv.body.append(ui.dim("Partial parse: some hunks could not be rendered.").as(gtk.Widget));
        }
        if (parsed.file.mode_changes.items.len > 0) {
            const mode_box = gtk.Box.new(.vertical, 2);
            for (parsed.file.mode_changes.items) |mode| {
                const z = try priv.alloc.dupeZ(u8, mode);
                defer priv.alloc.free(z);
                mode_box.append(ui.dim(z).as(gtk.Widget));
            }
            priv.body.append(mode_box.as(gtk.Widget));
        }

        if (parsed.file.is_binary) {
            priv.body.append((try binaryRow(priv.alloc, parsed.file.binary_size_bytes)).as(gtk.Widget));
            return;
        }

        for (parsed.file.hunks.items) |hunk| {
            priv.body.append((try diff_hunk.hunkWidget(priv.alloc, hunk)).as(gtk.Widget));
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            priv.alloc.free(priv.diff_text);
            if (priv.parsed) |*parsed| parsed.deinit(priv.alloc);
            priv.parsed = null;
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

fn fileHeader(alloc: std.mem.Allocator, file: diff_parser.File) !*gtk.Widget {
    const row = gtk.Box.new(.horizontal, 8);
    row.as(gtk.Widget).addCssClass("card");
    ui.margin(row.as(gtk.Widget), 10);

    const badge_z = try alloc.dupeZ(u8, file.status.badge());
    defer alloc.free(badge_z);
    const badge = ui.label(badge_z, "heading");
    badge.setWidthChars(2);
    row.append(badge.as(gtk.Widget));

    const title = if (file.old_path) |old|
        try std.fmt.allocPrintSentinel(alloc, "{s} (from {s})", .{ file.path, old }, 0)
    else
        try alloc.dupeZ(u8, file.path);
    defer alloc.free(title);
    const path = ui.label(title, "monospace");
    path.setWrap(0);
    path.setEllipsize(.middle);
    path.as(gtk.Widget).setHexpand(1);
    row.append(path.as(gtk.Widget));

    if (file.additions() > 0) {
        const add_z = try std.fmt.allocPrintSentinel(alloc, "+{d}", .{file.additions()}, 0);
        defer alloc.free(add_z);
        row.append(ui.label(add_z, "success").as(gtk.Widget));
    }
    if (file.deletions() > 0) {
        const del_z = try std.fmt.allocPrintSentinel(alloc, "-{d}", .{file.deletions()}, 0);
        defer alloc.free(del_z);
        row.append(ui.label(del_z, "error").as(gtk.Widget));
    }
    return row.as(gtk.Widget);
}

fn binaryRow(alloc: std.mem.Allocator, size: ?usize) !*gtk.Widget {
    const text = if (size) |bytes| try std.fmt.allocPrintSentinel(alloc, "Binary file ({d} bytes)", .{bytes}, 0) else try alloc.dupeZ(u8, "Binary file");
    defer alloc.free(text);
    return ui.label(text, "warning").as(gtk.Widget);
}
