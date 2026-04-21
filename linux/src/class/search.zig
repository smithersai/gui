const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const SearchResult = struct {
    id: []u8,
    title: []u8,
    file_path: ?[]u8 = null,
    line_number: ?i64 = null,
    snippet: ?[]u8 = null,
    description: ?[]u8 = null,

    pub fn deinit(self: *SearchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        if (self.file_path) |v| alloc.free(v);
        if (self.snippet) |v| alloc.free(v);
        if (self.description) |v| alloc.free(v);
    }
};

pub const SearchView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersSearchView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        client: smithers.c.smithers_client_t = null,
        entry: *gtk.SearchEntry = undefined,
        list: *gtk.ListBox = undefined,
        status: *gtk.Label = undefined,
        results: std.ArrayList(SearchResult) = .empty,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, client: smithers.c.smithers_client_t) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc, .client = client };
        try self.build();
        return self;
    }

    pub fn search(self: *Self, query: []const u8) !void {
        const priv = self.private();
        clearResults(priv);
        ui.clearList(priv.list);

        const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            priv.status.setText("Enter a search query");
            return;
        }

        const args = try searchArgs(priv.alloc, trimmed);
        defer priv.alloc.free(args);
        const json = smithers.callJson(priv.alloc, priv.client, "searchFiles", args) catch |err| {
            const msg = try std.fmt.allocPrintSentinel(priv.alloc, "Search failed: {}", .{err}, 0);
            defer priv.alloc.free(msg);
            priv.status.setText(msg.ptr);
            return;
        };
        defer priv.alloc.free(json);

        priv.results = parseResults(priv.alloc, json) catch .empty;
        try self.renderResults();
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 10);
        ui.margin(root.as(gtk.Widget), 18);
        root.append(ui.heading("Search").as(gtk.Widget));

        self.private().entry = gtk.SearchEntry.new();
        self.private().entry.setPlaceholderText("Search workspace files");
        self.private().entry.setSearchDelay(120);
        _ = gtk.SearchEntry.signals.activate.connect(self.private().entry, *Self, searchActivated, self, .{});
        _ = gtk.SearchEntry.signals.search_changed.connect(self.private().entry, *Self, searchChanged, self, .{});
        root.append(self.private().entry.as(gtk.Widget));

        self.private().status = ui.dim("Enter a search query");
        root.append(self.private().status.as(gtk.Widget));

        self.private().list = gtk.ListBox.new();
        self.private().list.as(gtk.Widget).addCssClass("boxed-list");
        self.private().list.setSelectionMode(.none);
        self.private().list.setShowSeparators(1);
        const scroll = ui.scrolled(self.private().list.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));
        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn renderResults(self: *Self) !void {
        const priv = self.private();
        ui.clearList(priv.list);
        const status = try std.fmt.allocPrintSentinel(priv.alloc, "{d} result{s}", .{
            priv.results.items.len,
            if (priv.results.items.len == 1) "" else "s",
        }, 0);
        defer priv.alloc.free(status);
        priv.status.setText(status.ptr);

        if (priv.results.items.len == 0) {
            priv.list.append((try ui.row(priv.alloc, "system-search-symbolic", "No results found", "Try a different query.")).as(gtk.Widget));
            return;
        }
        for (priv.results.items) |result| {
            const subtitle = result.file_path orelse result.description orelse result.snippet orelse "";
            const row = try ui.row(priv.alloc, "text-x-generic-symbolic", result.title, subtitle);
            priv.list.append(row.as(gtk.Widget));
        }
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const query = std.mem.span(self.private().entry.as(gtk.Editable).getText());
        self.search(query) catch {};
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const query = std.mem.span(self.private().entry.as(gtk.Editable).getText());
        if (std.mem.trim(u8, query, &std.ascii.whitespace).len == 0) self.search(query) catch {};
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            clearResults(priv);
            priv.results.deinit(priv.alloc);
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

fn clearResults(priv: anytype) void {
    for (priv.results.items) |*result| result.deinit(priv.alloc);
    priv.results.clearRetainingCapacity();
}

fn searchArgs(alloc: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, query.len + 32);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("query");
    try jw.write(query);
    try jw.objectField("scope");
    try jw.write("code");
    try jw.endObject();
    return try out.toOwnedSlice();
}

fn parseResults(alloc: std.mem.Allocator, json: []const u8) !std.ArrayList(SearchResult) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    var results = std.ArrayList(SearchResult).empty;
    errdefer {
        for (results.items) |*result| result.deinit(alloc);
        results.deinit(alloc);
    }

    if (arrayFromRoot(&parsed.value)) |items| {
        for (items) |*item| {
            const obj = object(item) orelse continue;
            const id = try stringField(alloc, obj, &.{ "id", "path", "filePath", "file_path" }) orelse continue;
            errdefer alloc.free(id);
            const title = try stringField(alloc, obj, &.{ "title", "name", "path", "filePath", "file_path" }) orelse try alloc.dupe(u8, id);
            errdefer alloc.free(title);
            try results.append(alloc, .{
                .id = id,
                .title = title,
                .file_path = try stringField(alloc, obj, &.{ "filePath", "file_path", "path" }),
                .line_number = intField(obj, &.{ "lineNumber", "line_number", "line" }),
                .snippet = try stringField(alloc, obj, &.{ "snippet", "displaySnippet", "display_snippet" }),
                .description = try stringField(alloc, obj, &.{ "description", "body" }),
            });
        }
    }
    return results;
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

fn intField(obj: *std.json.ObjectMap, keys: []const []const u8) ?i64 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .integer => |i| return i,
            .float => |f| return @intFromFloat(f),
            .number_string, .string => |s| return std.fmt.parseInt(i64, s, 10) catch null,
            else => {},
        }
    }
    return null;
}
