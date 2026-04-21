const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const models = @import("../models.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const MainWindow = @import("main_window.zig").MainWindow;

const log = std.log.scoped(.smithers_gtk_palette);

pub const CommandPalette = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersCommandPalette",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        dialog: *adw.Dialog = undefined,
        search: *gtk.SearchEntry = undefined,
        list: *gtk.ListBox = undefined,
        items: std.ArrayList(models.PaletteItem) = .empty,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().window = window;
        try self.build();
        return self;
    }

    pub fn present(self: *Self) void {
        self.refresh() catch |err| {
            log.warn("palette refresh failed: {}", .{err});
        };
        self.private().dialog.present(self.private().window.as(gtk.Widget));
        _ = self.private().search.as(gtk.Widget).grabFocus();
    }

    pub fn dismiss(self: *Self) void {
        _ = self.private().dialog.close();
    }

    fn build(self: *Self) !void {
        const priv = self.private();
        priv.dialog = adw.Dialog.new();
        priv.dialog.setTitle("Command Palette");
        priv.dialog.setContentWidth(640);
        priv.dialog.setContentHeight(520);

        const box = gtk.Box.new(.vertical, 12);
        ui.margin(box.as(gtk.Widget), 18);
        priv.search = gtk.SearchEntry.new();
        priv.search.setPlaceholderText("Commands, files, workflows");
        priv.search.setSearchDelay(80);
        _ = gtk.SearchEntry.signals.search_changed.connect(priv.search, *Self, searchChanged, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(priv.search, *Self, searchActivated, self, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(priv.search, *Self, stopSearch, self, .{});
        box.append(priv.search.as(gtk.Widget));

        priv.list = gtk.ListBox.new();
        priv.list.as(gtk.Widget).addCssClass("boxed-list");
        priv.list.setSelectionMode(.single);
        priv.list.setShowSeparators(1);
        _ = gtk.ListBox.signals.row_activated.connect(priv.list, *Self, rowActivated, self, .{});
        box.append(priv.list.as(gtk.Widget));

        priv.dialog.setChild(box.as(gtk.Widget));
    }

    fn refresh(self: *Self) !void {
        const priv = self.private();
        const alloc = priv.window.allocator();
        models.clearList(models.PaletteItem, alloc, &priv.items);
        ui.clearList(priv.list);

        const query = std.mem.span(priv.search.as(gtk.Editable).getText());
        const query_z = try alloc.dupeZ(u8, query);
        defer alloc.free(query_z);

        if (priv.window.app().palette()) |palette| {
            smithers.c.smithers_palette_set_mode(palette, smithers.c.SMITHERS_PALETTE_MODE_ALL);
            smithers.c.smithers_palette_set_query(palette, query_z.ptr);
            const json = try smithers.paletteItemsJson(alloc, palette);
            defer alloc.free(json);
            priv.items = models.parsePaletteItems(alloc, json) catch |err| parsed: {
                log.warn("palette JSON parse failed: {}", .{err});
                break :parsed .empty;
            };
        }

        if (priv.items.items.len == 0) try self.addFallbackItems(query);

        for (priv.items.items, 0..) |item, index| {
            const icon = paletteIcon(item.kind, item.id);
            const row = try ui.row(alloc, icon, item.title, item.subtitle);
            ui.setIndex(row.as(gobject.Object), index);
            priv.list.append(row.as(gtk.Widget));
        }
    }

    fn addFallbackItems(self: *Self, query: []const u8) !void {
        try self.addFallback("nav:dashboard", "Dashboard", "Open dashboard", "command", query);
        try self.addFallback("nav:workflows", "Workflows", "List and launch workflows", "command", query);
        try self.addFallback("nav:runs", "Runs", "Inspect recent runs", "command", query);
        try self.addFallback("nav:approvals", "Approvals", "Review approval gates", "command", query);
        try self.addFallback("nav:agents", "Agents", "Review available agents", "command", query);
        try self.addFallback("nav:workspaces", "Workspaces", "Open recent workspaces", "command", query);
        try self.addFallback("nav:settings", "Settings", "Review Linux shell settings", "command", query);
        try self.addFallback("new:terminal", "New Terminal", "Open a terminal session", "session", query);
        try self.addFallback("new:chat", "New Chat", "Open a chat session", "session", query);
    }

    fn addFallback(
        self: *Self,
        id: []const u8,
        title: []const u8,
        subtitle: []const u8,
        kind: []const u8,
        query: []const u8,
    ) !void {
        if (query.len > 0 and
            std.ascii.indexOfIgnoreCase(title, query) == null and
            std.ascii.indexOfIgnoreCase(subtitle, query) == null)
        {
            return;
        }
        const alloc = self.private().window.allocator();
        try self.private().items.append(alloc, .{
            .id = try alloc.dupe(u8, id),
            .title = try alloc.dupe(u8, title),
            .subtitle = try alloc.dupe(u8, subtitle),
            .kind = try alloc.dupe(u8, kind),
        });
    }

    fn activateIndex(self: *Self, index: usize) void {
        const priv = self.private();
        if (index >= priv.items.items.len) return;
        const item = priv.items.items[index];

        if (priv.window.app().palette()) |palette| {
            const id_z = priv.window.allocator().dupeZ(u8, item.id) catch return;
            defer priv.window.allocator().free(id_z);
            const err = smithers.c.smithers_palette_activate(palette, id_z.ptr);
            defer smithers.c.smithers_error_free(err);
            if (err.code != 0) log.warn("palette activation returned error code {d}", .{err.code});
        }

        _ = priv.dialog.close();
        if (std.mem.eql(u8, item.id, "nav:dashboard")) return priv.window.showNav(.dashboard);
        if (std.mem.eql(u8, item.id, "nav:workflows")) return priv.window.showNav(.workflows);
        if (std.mem.eql(u8, item.id, "nav:runs")) return priv.window.showNav(.runs);
        if (std.mem.eql(u8, item.id, "nav:approvals")) return priv.window.showNav(.approvals);
        if (std.mem.eql(u8, item.id, "nav:agents")) return priv.window.showNav(.agents);
        if (std.mem.eql(u8, item.id, "nav:workspaces")) return priv.window.showNav(.workspaces);
        if (std.mem.eql(u8, item.id, "nav:settings")) return priv.window.showNav(.settings);
        if (std.mem.eql(u8, item.id, "new:terminal")) return priv.window.openSession(smithers.c.SMITHERS_SESSION_KIND_TERMINAL, null) catch {};
        if (std.mem.eql(u8, item.id, "new:chat")) return priv.window.openSession(smithers.c.SMITHERS_SESSION_KIND_CHAT, null) catch {};
        if (std.mem.startsWith(u8, item.id, "workflow:")) return priv.window.showNav(.workflows);
    }

    fn paletteIcon(kind: []const u8, id: []const u8) [:0]const u8 {
        if (std.mem.startsWith(u8, id, "new:")) return "tab-new-symbolic";
        if (std.mem.startsWith(u8, id, "workflow:") or std.ascii.eqlIgnoreCase(kind, "workflow")) return "media-playlist-shuffle-symbolic";
        if (std.mem.startsWith(u8, id, "file:") or std.ascii.eqlIgnoreCase(kind, "file")) return "text-x-generic-symbolic";
        if (std.ascii.eqlIgnoreCase(kind, "workspace")) return "folder-symbolic";
        return "system-search-symbolic";
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.refresh() catch |err| log.warn("palette search failed: {}", .{err});
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.activateIndex(0);
    }

    fn stopSearch(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        _ = self.private().dialog.close();
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        self.activateIndex(ui.getIndex(row.as(gobject.Object)) orelse return);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            const alloc = priv.window.allocator();
            models.clearList(models.PaletteItem, alloc, &priv.items);
            priv.items.deinit(alloc);
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
