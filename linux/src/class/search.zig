const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const logx = @import("../log.zig");
const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.smithers_gtk_search);

const SearchScope = enum {
    everywhere,
    files,
    workflows,
    runs,
    tickets,

    fn label(self: SearchScope) [:0]const u8 {
        return switch (self) {
            .everywhere => "Everywhere",
            .files => "Files",
            .workflows => "Workflows",
            .runs => "Runs",
            .tickets => "Tickets",
        };
    }

    fn method(self: SearchScope) []const u8 {
        return switch (self) {
            .everywhere => "search",
            .files => "searchFiles",
            .workflows => "listWorkflows",
            .runs => "listRuns",
            .tickets => "searchTickets",
        };
    }
};

pub const SearchResult = struct {
    id: []u8,
    title: []u8,
    kind: []u8,
    file_path: ?[]u8 = null,
    line_number: ?i64 = null,
    snippet: ?[]u8 = null,
    description: ?[]u8 = null,

    pub fn deinit(self: *SearchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.kind);
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
        scopes: *gtk.Box = undefined,
        list: *gtk.ListBox = undefined,
        status: *gtk.Label = undefined,
        preview: *gtk.Box = undefined,
        results: std.ArrayList(SearchResult) = .empty,
        scope: SearchScope = .everywhere,
        selected_index: usize = 0,
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
        ui.clearBox(priv.preview);

        const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            priv.status.setText("Enter a search query");
            priv.preview.append(ui.dim("Result preview appears here").as(gtk.Widget));
            return;
        }

        const args = try searchArgs(priv.alloc, trimmed, priv.scope);
        defer priv.alloc.free(args);
        const t = logx.startTimer();
        const json = smithers.callJson(priv.alloc, priv.client, priv.scope.method(), args) catch |err| {
            logx.catchWarn(log, "search callJson", err);
            const msg = try std.fmt.allocPrintSentinel(priv.alloc, "Search failed: {}", .{err}, 0);
            defer priv.alloc.free(msg);
            priv.status.setText(msg.ptr);
            return;
        };
        defer priv.alloc.free(json);

        priv.results = parseResults(priv.alloc, json, priv.scope, trimmed) catch |err| blk: {
            logx.catchWarn(log, "search parseResults", err);
            break :blk .empty;
        };
        priv.selected_index = 0;
        logx.endTimerDebug(log, "search", t);
        logx.event(log, "search_run", "scope={s} query_len={d} matches={d}", .{
            priv.scope.label(),
            trimmed.len,
            priv.results.items.len,
        });
        try self.renderResults();
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 10);
        ui.margin(root.as(gtk.Widget), 18);
        root.append(ui.heading("Search").as(gtk.Widget));

        self.private().entry = gtk.SearchEntry.new();
        self.private().entry.setPlaceholderText("Search...");
        self.private().entry.setSearchDelay(120);
        _ = gtk.SearchEntry.signals.activate.connect(self.private().entry, *Self, searchActivated, self, .{});
        _ = gtk.SearchEntry.signals.search_changed.connect(self.private().entry, *Self, searchChanged, self, .{});
        root.append(self.private().entry.as(gtk.Widget));

        self.private().scopes = gtk.Box.new(.horizontal, 6);
        try self.rebuildScopes();
        root.append(self.private().scopes.as(gtk.Widget));

        self.private().status = ui.dim("Enter a search query");
        root.append(self.private().status.as(gtk.Widget));

        const panes = gtk.Paned.new(.horizontal);
        panes.as(gtk.Widget).setVexpand(1);
        panes.setPosition(430);

        self.private().list = gtk.ListBox.new();
        self.private().list.as(gtk.Widget).addCssClass("boxed-list");
        self.private().list.setSelectionMode(.single);
        self.private().list.setShowSeparators(1);
        _ = gtk.ListBox.signals.row_activated.connect(self.private().list, *Self, rowActivated, self, .{});
        const scroll = ui.scrolled(self.private().list.as(gtk.Widget));
        scroll.setPolicy(.automatic, .automatic);
        panes.setStartChild(scroll.as(gtk.Widget));

        self.private().preview = gtk.Box.new(.vertical, 8);
        ui.margin(self.private().preview.as(gtk.Widget), 12);
        self.private().preview.append(ui.dim("Result preview appears here").as(gtk.Widget));
        panes.setEndChild(self.private().preview.as(gtk.Widget));
        root.append(panes.as(gtk.Widget));

        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Self, keyPressed, self, .{});
        root.as(gtk.Widget).addController(controller.as(gtk.EventController));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn rebuildScopes(self: *Self) !void {
        const priv = self.private();
        ui.clearBox(priv.scopes);
        const scopes = [_]SearchScope{ .everywhere, .files, .workflows, .runs, .tickets };
        for (scopes, 0..) |scope, index| {
            const button = ui.textButton(scope.label(), scope == priv.scope);
            button.as(gtk.Widget).addCssClass("flat");
            ui.setIndex(button.as(gobject.Object), index);
            _ = gtk.Button.signals.clicked.connect(button, *Self, scopeClicked, self, .{});
            priv.scopes.append(button.as(gtk.Widget));
        }
    }

    fn renderResults(self: *Self) !void {
        const priv = self.private();
        ui.clearList(priv.list);
        const status = try std.fmt.allocPrintSentinel(priv.alloc, "{d} result{s} in {s}", .{
            priv.results.items.len,
            if (priv.results.items.len == 1) "" else "s",
            priv.scope.label(),
        }, 0);
        defer priv.alloc.free(status);
        priv.status.setText(status.ptr);

        if (priv.results.items.len == 0) {
            priv.list.append((try ui.row(priv.alloc, "system-search-symbolic", "No results found", "Try a different query or scope.")).as(gtk.Widget));
            self.renderPreview(null) catch |err| logx.catchWarn(log, "renderPreview empty", err);
            return;
        }
        for (priv.results.items, 0..) |result, index| {
            const subtitle = try resultSubtitle(priv.alloc, result);
            defer priv.alloc.free(subtitle);
            const row = try ui.row(priv.alloc, resultIcon(result.kind), result.title, subtitle);
            ui.setIndex(row.as(gobject.Object), index);
            priv.list.append(row.as(gtk.Widget));
        }
        self.selectIndex(0);
    }

    fn renderPreview(self: *Self, maybe_result: ?SearchResult) !void {
        const priv = self.private();
        ui.clearBox(priv.preview);
        const result = maybe_result orelse {
            priv.preview.append(ui.dim("No result selected").as(gtk.Widget));
            return;
        };

        const title_z = try priv.alloc.dupeZ(u8, result.title);
        defer priv.alloc.free(title_z);
        priv.preview.append(ui.heading(title_z).as(gtk.Widget));

        const meta = try resultSubtitle(priv.alloc, result);
        defer priv.alloc.free(meta);
        const meta_z = try priv.alloc.dupeZ(u8, meta);
        defer priv.alloc.free(meta_z);
        priv.preview.append(ui.dim(meta_z).as(gtk.Widget));

        if (result.snippet) |snippet| {
            const snippet_z = try priv.alloc.dupeZ(u8, snippet);
            defer priv.alloc.free(snippet_z);
            const label = ui.label(snippet_z, "monospace");
            label.as(gtk.Widget).addCssClass("card");
            label.setSelectable(1);
            ui.margin(label.as(gtk.Widget), 10);
            priv.preview.append(label.as(gtk.Widget));
        }

        if (result.description) |description| {
            const desc_z = try priv.alloc.dupeZ(u8, description);
            defer priv.alloc.free(desc_z);
            priv.preview.append(ui.label(desc_z, null).as(gtk.Widget));
        }
    }

    fn selectIndex(self: *Self, index: usize) void {
        const priv = self.private();
        if (index >= priv.results.items.len) return;
        priv.selected_index = index;
        if (priv.list.getRowAtIndex(@intCast(index))) |row| priv.list.selectRow(row);
        self.renderPreview(priv.results.items[index]) catch |err| logx.catchWarn(log, "renderPreview", err);
    }

    fn activateSelected(self: *Self) void {
        const priv = self.private();
        if (priv.selected_index >= priv.results.items.len) return;
        const result = priv.results.items[priv.selected_index];
        const args = activateArgs(priv.alloc, result) catch |err| {
            logx.catchWarn(log, "activateSelected activateArgs", err);
            return;
        };
        defer priv.alloc.free(args);
        const json = smithers.callJson(priv.alloc, priv.client, "openSearchResult", args) catch |err| {
            logx.catchWarn(log, "openSearchResult", err);
            priv.status.setText("Result selected");
            return;
        };
        defer priv.alloc.free(json);
        logx.event(log, "search_result_opened", "kind={s} id={s}", .{ result.kind, result.id });
        priv.status.setText("Result opened");
    }

    fn moveSelection(self: *Self, delta: isize) void {
        const priv = self.private();
        if (priv.results.items.len == 0) return;
        if (delta < 0) {
            self.selectIndex(if (priv.selected_index == 0) 0 else priv.selected_index - 1);
        } else {
            self.selectIndex(@min(priv.results.items.len - 1, priv.selected_index + 1));
        }
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const query = std.mem.span(self.private().entry.as(gtk.Editable).getText());
        self.search(query) catch |err| logx.catchWarn(log, "searchActivated", err);
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const query = std.mem.span(self.private().entry.as(gtk.Editable).getText());
        if (std.mem.trim(u8, query, &std.ascii.whitespace).len == 0) {
            self.search(query) catch |err| logx.catchWarn(log, "searchChanged clear", err);
        }
    }

    fn scopeClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const scopes = [_]SearchScope{ .everywhere, .files, .workflows, .runs, .tickets };
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        if (index >= scopes.len) return;
        self.private().scope = scopes[index];
        logx.event(log, "search_scope_changed", "scope={s}", .{self.private().scope.label()});
        self.rebuildScopes() catch |err| logx.catchWarn(log, "scopeClicked rebuildScopes", err);
        const query = std.mem.span(self.private().entry.as(gtk.Editable).getText());
        if (std.mem.trim(u8, query, &std.ascii.whitespace).len > 0) {
            self.search(query) catch |err| logx.catchWarn(log, "scopeClicked search", err);
        }
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        self.selectIndex(ui.getIndex(row.as(gobject.Object)) orelse return);
        self.activateSelected();
    }

    fn keyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        switch (keyval) {
            gdk.KEY_Down, gdk.KEY_j, gdk.KEY_J => {
                self.moveSelection(1);
                return 1;
            },
            gdk.KEY_Up, gdk.KEY_k, gdk.KEY_K => {
                self.moveSelection(-1);
                return 1;
            },
            gdk.KEY_Return, gdk.KEY_KP_Enter => {
                self.activateSelected();
                return 1;
            },
            else => return 0,
        }
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

fn searchArgs(alloc: std.mem.Allocator, query: []const u8, scope: SearchScope) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, query.len + 64);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("query");
    try jw.write(query);
    try jw.objectField("scope");
    try jw.write(scope.label());
    try jw.objectField("limit");
    try jw.write(@as(u32, 50));
    try jw.endObject();
    return try out.toOwnedSlice();
}

fn activateArgs(alloc: std.mem.Allocator, result: SearchResult) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, result.id.len + 64);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(result.id);
    try jw.objectField("kind");
    try jw.write(result.kind);
    if (result.file_path) |path| {
        try jw.objectField("filePath");
        try jw.write(path);
    }
    if (result.line_number) |line| {
        try jw.objectField("lineNumber");
        try jw.write(line);
    }
    try jw.endObject();
    return try out.toOwnedSlice();
}

fn parseResults(alloc: std.mem.Allocator, json: []const u8, scope: SearchScope, query: []const u8) !std.ArrayList(SearchResult) {
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
            const id = try stringField(alloc, obj, &.{ "id", "path", "filePath", "file_path", "runId", "run_id", "relativePath" }) orelse continue;
            errdefer alloc.free(id);
            const title = try stringField(alloc, obj, &.{ "title", "name", "path", "filePath", "file_path", "workflowName", "workflow_name", "runId", "run_id" }) orelse try alloc.dupe(u8, id);
            errdefer alloc.free(title);
            const description = try stringField(alloc, obj, &.{ "description", "body", "status", "state" });
            const file_path = try stringField(alloc, obj, &.{ "filePath", "file_path", "path", "relativePath", "workflowPath", "workflow_path" });
            if ((scope == .workflows or scope == .runs) and !matchesQuery(title, file_path, description, query)) {
                alloc.free(id);
                alloc.free(title);
                if (description) |v| alloc.free(v);
                if (file_path) |v| alloc.free(v);
                continue;
            }
            try results.append(alloc, .{
                .id = id,
                .title = title,
                .kind = try alloc.dupe(u8, @tagName(scope)),
                .file_path = file_path,
                .line_number = intField(obj, &.{ "lineNumber", "line_number", "line" }),
                .snippet = try stringField(alloc, obj, &.{ "snippet", "displaySnippet", "display_snippet", "preview" }),
                .description = description,
            });
        }
    }
    return results;
}

fn matchesQuery(title: []const u8, file_path: ?[]const u8, description: ?[]const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(title, query) != null) return true;
    if (file_path) |path| if (std.ascii.indexOfIgnoreCase(path, query) != null) return true;
    if (description) |desc| if (std.ascii.indexOfIgnoreCase(desc, query) != null) return true;
    return false;
}

fn resultSubtitle(alloc: std.mem.Allocator, result: SearchResult) ![:0]u8 {
    if (result.file_path) |path| {
        if (result.line_number) |line| return try std.fmt.allocPrintSentinel(alloc, "{s}:L{d}", .{ path, line }, 0);
        return try alloc.dupeZ(u8, path);
    }
    if (result.description) |description| return try alloc.dupeZ(u8, description);
    if (result.snippet) |snippet| return try alloc.dupeZ(u8, snippet);
    return try alloc.dupeZ(u8, result.kind);
}

fn resultIcon(kind: []const u8) [:0]const u8 {
    if (std.ascii.eqlIgnoreCase(kind, "files")) return "text-x-generic-symbolic";
    if (std.ascii.eqlIgnoreCase(kind, "workflows")) return "media-playlist-shuffle-symbolic";
    if (std.ascii.eqlIgnoreCase(kind, "runs")) return "media-playback-start-symbolic";
    if (std.ascii.eqlIgnoreCase(kind, "tickets")) return "emblem-documents-symbolic";
    return "system-search-symbolic";
}

fn arrayFromRoot(root: *std.json.Value) ?[]std.json.Value {
    switch (root.*) {
        .array => |array| return array.items,
        .object => |obj| {
            const keys = [_][]const u8{ "results", "items", "data", "workflows", "runs", "tickets" };
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
