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

// Keep P3-owned surface modules in the Linux compile graph until the shared
// class registry can expose them.
comptime {
    std.testing.refAllDeclsRecursive(@import("chat.zig"));
    std.testing.refAllDeclsRecursive(@import("markdown.zig"));
    std.testing.refAllDeclsRecursive(@import("markdown_editor.zig"));
    std.testing.refAllDeclsRecursive(@import("diff.zig"));
    std.testing.refAllDeclsRecursive(@import("terminal.zig"));
    std.testing.refAllDeclsRecursive(@import("browser_surface.zig"));
    std.testing.refAllDeclsRecursive(@import("search.zig"));
    std.testing.refAllDeclsRecursive(@import("quick_launch.zig"));
    std.testing.refAllDeclsRecursive(@import("shortcut_recorder.zig"));
    std.testing.refAllDeclsRecursive(@import("workspace_content.zig"));
    std.testing.refAllDeclsRecursive(@import("developer_debug.zig"));
}

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
        recent_ids: std.ArrayList([]u8) = .empty,
        mode: smithers.c.smithers_palette_mode_e = smithers.c.SMITHERS_PALETTE_MODE_ALL,
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

        const modes = gtk.Box.new(.horizontal, 6);
        ui.margin4(modes.as(gtk.Widget), 0, 0, 0, 0);
        const mode_defs = [_]struct { label: [:0]const u8, mode: smithers.c.smithers_palette_mode_e }{
            .{ .label = "All", .mode = smithers.c.SMITHERS_PALETTE_MODE_ALL },
            .{ .label = "Commands", .mode = smithers.c.SMITHERS_PALETTE_MODE_COMMANDS },
            .{ .label = "Files", .mode = smithers.c.SMITHERS_PALETTE_MODE_FILES },
            .{ .label = "Workflows", .mode = smithers.c.SMITHERS_PALETTE_MODE_WORKFLOWS },
            .{ .label = "Runs", .mode = smithers.c.SMITHERS_PALETTE_MODE_RUNS },
        };
        inline for (mode_defs, 0..) |def, index| {
            const button = ui.textButton(def.label, def.mode == priv.mode);
            button.as(gtk.Widget).addCssClass("flat");
            ui.setIndex(button.as(gobject.Object), index);
            _ = gtk.Button.signals.clicked.connect(button, *Self, modeClicked, self, .{});
            modes.append(button.as(gtk.Widget));
        }
        box.append(modes.as(gtk.Widget));

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
            smithers.c.smithers_palette_set_mode(palette, priv.mode);
            smithers.c.smithers_palette_set_query(palette, query_z.ptr);
            const json = try smithers.paletteItemsJson(alloc, palette);
            defer alloc.free(json);
            priv.items = models.parsePaletteItems(alloc, json) catch |err| parsed: {
                log.warn("palette JSON parse failed: {}", .{err});
                break :parsed .empty;
            };
        }

        try addFileSearchItems(self, query);
        filterAndRank(self, query);
        if (priv.items.items.len == 0) try self.addFallbackItems(query);

        for (priv.items.items, 0..) |item, index| {
            const icon = paletteIcon(item.kind, item.id);
            const row = try ui.row(alloc, icon, item.title, item.subtitle);
            ui.setIndex(row.as(gobject.Object), index);
            priv.list.append(row.as(gtk.Widget));
        }
    }

    fn addFallbackItems(self: *Self, query: []const u8) !void {
        if (self.private().mode != smithers.c.SMITHERS_PALETTE_MODE_ALL and
            self.private().mode != smithers.c.SMITHERS_PALETTE_MODE_COMMANDS)
        {
            return;
        }
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
        rememberRecent(self, item.id) catch {};

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
        if (std.mem.startsWith(u8, item.id, "file:")) return priv.window.showToastFmt("File selected: {s}", .{item.title});
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

    fn modeClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        self.private().mode = switch (index) {
            1 => smithers.c.SMITHERS_PALETTE_MODE_COMMANDS,
            2 => smithers.c.SMITHERS_PALETTE_MODE_FILES,
            3 => smithers.c.SMITHERS_PALETTE_MODE_WORKFLOWS,
            4 => smithers.c.SMITHERS_PALETTE_MODE_RUNS,
            else => smithers.c.SMITHERS_PALETTE_MODE_ALL,
        };
        self.refresh() catch |err| log.warn("palette mode refresh failed: {}", .{err});
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
            for (priv.recent_ids.items) |id| alloc.free(id);
            priv.recent_ids.deinit(alloc);
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

fn addFileSearchItems(self: *CommandPalette, query: []const u8) !void {
    const priv = self.private();
    if (priv.mode != smithers.c.SMITHERS_PALETTE_MODE_ALL and priv.mode != smithers.c.SMITHERS_PALETTE_MODE_FILES) return;
    const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);
    if (trimmed.len < 2) return;

    const alloc = priv.window.allocator();
    const args = try searchArgs(alloc, trimmed);
    defer alloc.free(args);
    const json = smithers.callJson(alloc, priv.window.app().client(), "searchFiles", args) catch return;
    defer alloc.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return;
    defer parsed.deinit();
    const items = arrayFromRoot(&parsed.value) orelse return;
    var added: usize = 0;
    for (items) |*item| {
        if (added >= 12) break;
        const obj = object(item) orelse continue;
        const path = try stringField(alloc, obj, &.{ "path", "filePath", "file_path" }) orelse continue;
        defer alloc.free(path);
        const title = std.fs.path.basename(path);
        const id = try std.fmt.allocPrint(alloc, "file:{s}", .{path});
        defer alloc.free(id);
        if (hasPaletteItem(priv.items.items, id)) continue;
        try appendPaletteItem(alloc, &priv.items, id, title, path, "file", 40);
        added += 1;
    }
}

fn filterAndRank(self: *CommandPalette, query: []const u8) void {
    const priv = self.private();
    const alloc = priv.window.allocator();
    const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);

    var index: usize = 0;
    while (index < priv.items.items.len) {
        var item = &priv.items.items[index];
        const match_score = paletteScore(trimmed, item.title, item.subtitle orelse "");
        if (trimmed.len > 0 and match_score == null) {
            item.deinit(alloc);
            _ = priv.items.orderedRemove(index);
            continue;
        }
        const base = match_score orelse 0;
        const recency = recentRank(priv.recent_ids.items, item.id);
        item.score = @as(f64, @floatFromInt(base)) - @as(f64, @floatFromInt(recency)) * 200.0;
        index += 1;
    }

    std.mem.sort(models.PaletteItem, priv.items.items, {}, paletteLessThan);
}

fn rememberRecent(self: *CommandPalette, id: []const u8) !void {
    const priv = self.private();
    const alloc = priv.window.allocator();
    var index: usize = 0;
    while (index < priv.recent_ids.items.len) {
        if (std.mem.eql(u8, priv.recent_ids.items[index], id)) {
            alloc.free(priv.recent_ids.items[index]);
            _ = priv.recent_ids.orderedRemove(index);
            break;
        }
        index += 1;
    }

    const owned = try alloc.dupe(u8, id);
    try priv.recent_ids.append(alloc, owned);
    var move = priv.recent_ids.items.len - 1;
    while (move > 0) : (move -= 1) {
        priv.recent_ids.items[move] = priv.recent_ids.items[move - 1];
    }
    priv.recent_ids.items[0] = owned;

    while (priv.recent_ids.items.len > 8) {
        const removed = priv.recent_ids.orderedRemove(priv.recent_ids.items.len - 1);
        alloc.free(removed);
    }
}

fn appendPaletteItem(
    alloc: std.mem.Allocator,
    items: *std.ArrayList(models.PaletteItem),
    id: []const u8,
    title: []const u8,
    subtitle: []const u8,
    kind: []const u8,
    score: f64,
) !void {
    try items.append(alloc, .{
        .id = try alloc.dupe(u8, id),
        .title = try alloc.dupe(u8, title),
        .subtitle = try alloc.dupe(u8, subtitle),
        .kind = try alloc.dupe(u8, kind),
        .score = score,
    });
}

fn hasPaletteItem(items: []const models.PaletteItem, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn paletteLessThan(_: void, lhs: models.PaletteItem, rhs: models.PaletteItem) bool {
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    if (!std.mem.eql(u8, lhs.kind, rhs.kind)) return std.mem.lessThan(u8, lhs.kind, rhs.kind);
    return std.mem.lessThan(u8, lhs.title, rhs.title);
}

fn recentRank(recents: []const []u8, id: []const u8) usize {
    for (recents, 0..) |recent, index| {
        if (std.mem.eql(u8, recent, id)) return recents.len - index;
    }
    return 0;
}

fn paletteScore(query: []const u8, title: []const u8, subtitle: []const u8) ?i32 {
    if (query.len == 0) return 0;
    var best: ?i32 = null;
    const haystacks = [_][]const u8{ title, subtitle };
    for (haystacks) |candidate| {
        const value = std.mem.trim(u8, candidate, &std.ascii.whitespace);
        if (value.len == 0) continue;
        const score: ?i32 = if (std.ascii.eqlIgnoreCase(value, query))
            0
        else if (startsWithIgnoreCase(value, query))
            8
        else if (std.ascii.indexOfIgnoreCase(value, query) != null)
            24
        else if (fuzzySubsequenceScore(query, value)) |fuzzy|
            64 + fuzzy
        else
            null;
        if (score) |s| best = if (best) |b| @min(b, s) else s;
    }
    return best;
}

fn fuzzySubsequenceScore(query: []const u8, candidate: []const u8) ?i32 {
    var query_index: usize = 0;
    var first: ?usize = null;
    var last: usize = 0;
    for (candidate, 0..) |ch, index| {
        if (query_index >= query.len) break;
        if (std.ascii.toLower(ch) != std.ascii.toLower(query[query_index])) continue;
        if (first == null) first = index;
        last = index;
        query_index += 1;
    }
    if (query_index != query.len) return null;
    const start = first orelse 0;
    const span: i32 = @intCast(last - start + 1);
    const gaps = span - @as(i32, @intCast(query.len));
    return @as(i32, @intCast(start)) + gaps * 6;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn searchArgs(alloc: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, query.len + 32);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("query");
    try jw.write(query);
    try jw.objectField("limit");
    try jw.write(@as(u32, 12));
    try jw.endObject();
    return try out.toOwnedSlice();
}

fn arrayFromRoot(root: *std.json.Value) ?[]std.json.Value {
    switch (root.*) {
        .array => |array| return array.items,
        .object => |obj| {
            const keys = [_][]const u8{ "results", "items", "data" };
            for (keys) |key| {
                if (obj.get(key)) |value| {
                    var copy = value;
                    if (arrayFromRoot(&copy)) |array| return array;
                }
            }
        },
        else => {},
    }
    return null;
}

fn object(value: *std.json.Value) ?*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*obj| obj,
        else => null,
    };
}

fn stringField(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, keys: []const []const u8) !?[]u8 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .string => |s| return try alloc.dupe(u8, s),
            .number_string => |s| return try alloc.dupe(u8, s),
            .integer => |i| return try std.fmt.allocPrint(alloc, "{d}", .{i}),
            else => {},
        }
    }
    return null;
}
