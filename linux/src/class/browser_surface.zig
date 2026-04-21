const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const have_webkit = false;
pub const dependency_status = "webkitgtk-6.0 unavailable on this host; using external-browser fallback";

pub const BrowserSearchEngine = enum {
    duckduckgo,
    google,
    bing,
};

pub fn resolveUrl(alloc: std.mem.Allocator, raw: []const u8, engine: BrowserSearchEngine) !?[]u8 {
    const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (value.len == 0) return null;
    if (std.mem.indexOf(u8, value, "://") != null) return try alloc.dupe(u8, value);
    if (std.mem.startsWith(u8, value, "localhost") or std.mem.startsWith(u8, value, "127.0.0.1") or std.mem.indexOfScalar(u8, value, ':') != null) {
        return try std.fmt.allocPrint(alloc, "http://{s}", .{value});
    }
    if (std.mem.indexOfScalar(u8, value, '.') != null) {
        return try std.fmt.allocPrint(alloc, "https://{s}", .{value});
    }
    const encoded = try percentEncode(alloc, value);
    defer alloc.free(encoded);
    return switch (engine) {
        .duckduckgo => try std.fmt.allocPrint(alloc, "https://duckduckgo.com/?q={s}", .{encoded}),
        .google => try std.fmt.allocPrint(alloc, "https://www.google.com/search?q={s}", .{encoded}),
        .bing => try std.fmt.allocPrint(alloc, "https://www.bing.com/search?q={s}", .{encoded}),
    };
}

pub const BrowserSurface = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersBrowserSurface",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        entry: *gtk.Entry = undefined,
        title: *gtk.Label = undefined,
        current_url: ?[]u8 = null,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, initial_url: ?[]const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc };
        try self.build();
        if (initial_url) |url| self.navigate(url) catch {};
        return self;
    }

    pub fn navigate(self: *Self, raw: []const u8) !void {
        const priv = self.private();
        const resolved = (try resolveUrl(priv.alloc, raw, .duckduckgo)) orelse return;
        if (priv.current_url) |old| priv.alloc.free(old);
        priv.current_url = resolved;
        const z = try priv.alloc.dupeZ(u8, resolved);
        defer priv.alloc.free(z);
        priv.entry.as(gtk.Editable).setText(z.ptr);
        priv.title.setText(z.ptr);
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 0);
        const toolbar = gtk.Box.new(.horizontal, 6);
        ui.margin4(toolbar.as(gtk.Widget), 7, 8, 7, 8);

        const back = ui.iconButton("go-previous-symbolic", "Back");
        back.as(gtk.Widget).setSensitive(0);
        toolbar.append(back.as(gtk.Widget));
        const forward = ui.iconButton("go-next-symbolic", "Forward");
        forward.as(gtk.Widget).setSensitive(0);
        toolbar.append(forward.as(gtk.Widget));

        self.private().entry = gtk.Entry.new();
        self.private().entry.setPlaceholderText("Search or enter URL");
        self.private().entry.as(gtk.Widget).setHexpand(1);
        _ = gtk.Entry.signals.activate.connect(self.private().entry, *Self, entryActivated, self, .{});
        toolbar.append(self.private().entry.as(gtk.Widget));

        const go = ui.iconButton("go-jump-symbolic", "Go");
        _ = gtk.Button.signals.clicked.connect(go, *Self, goClicked, self, .{});
        toolbar.append(go.as(gtk.Widget));

        const external = ui.iconButton("document-open-symbolic", "Open externally");
        _ = gtk.Button.signals.clicked.connect(external, *Self, externalClicked, self, .{});
        toolbar.append(external.as(gtk.Widget));
        root.append(toolbar.as(gtk.Widget));

        const box = gtk.Box.new(.vertical, 12);
        ui.margin(box.as(gtk.Widget), 28);
        box.as(gtk.Widget).setValign(.center);
        box.as(gtk.Widget).setHalign(.center);
        box.append(ui.heading("Browser").as(gtk.Widget));
        box.append(ui.dim(dependency_status).as(gtk.Widget));
        self.private().title = ui.dim("Enter a URL to open it in the system browser.");
        box.append(self.private().title.as(gtk.Widget));
        root.append(box.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn submit(self: *Self) void {
        const text = std.mem.span(self.private().entry.as(gtk.Editable).getText());
        self.navigate(text) catch {};
    }

    fn openExternal(self: *Self) void {
        const url = self.private().current_url orelse return;
        const z = self.private().alloc.dupeZ(u8, url) catch return;
        defer self.private().alloc.free(z);
        var err: ?*glib.Error = null;
        _ = gio.AppInfo.launchDefaultForUri(z.ptr, null, &err);
        if (err) |e| e.free();
    }

    fn entryActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.submit();
    }

    fn goClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.submit();
    }

    fn externalClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.openExternal();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            if (priv.current_url) |url| priv.alloc.free(url);
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

fn percentEncode(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, value.len);
    defer out.deinit();
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.writer.writeByte(ch);
        } else if (ch == ' ') {
            try out.writer.writeByte('+');
        } else {
            try out.writer.writeByte('%');
            try out.writer.writeByte(hex[ch >> 4]);
            try out.writer.writeByte(hex[ch & 0x0f]);
        }
    }
    return try out.toOwnedSlice();
}
