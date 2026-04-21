const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const PromptsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersPromptsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        search_entry: *gtk.Entry = undefined,
        source_view: *gtk.TextView = undefined,
        input_view: *gtk.TextView = undefined,
        prompts: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .window = window };
        try self.build();
        return self;
    }

    pub fn refresh(self: *Self) void {
        self.load() catch |err| vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Prompts unavailable", @errorName(err));
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.private().window.allocator();
    }

    fn client(self: *Self) smithers.c.smithers_client_t {
        return self.private().window.app().client();
    }

    fn build(self: *Self) !void {
        const root = self.as(gtk.Box);
        root.as(gtk.Orientable).setOrientation(.vertical);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>r", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>f", self, shortcutSearch);
        const header = vh.makeHeader("Prompts", null);
        self.private().search_entry = gtk.Entry.new();
        self.private().search_entry.setPlaceholderText("Search prompts");
        self.private().search_entry.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().search_entry.as(gtk.Editable), *Self, searchChanged, self, .{});
        header.append(self.private().search_entry.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh prompts");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));
        const split = vh.splitPane(280);
        self.private().list = vh.listBox();
        _ = gtk.ListBox.signals.row_activated.connect(self.private().list, *Self, rowActivated, self, .{});
        const list_scroll = ui.scrolled(self.private().list.as(gtk.Widget));
        list_scroll.as(gtk.Widget).setVexpand(1);
        split.left.append(list_scroll.as(gtk.Widget));
        self.private().detail = gtk.Box.new(.vertical, 12);
        ui.margin(self.private().detail.as(gtk.Widget), 18);
        const detail_scroll = ui.scrolled(self.private().detail.as(gtk.Widget));
        detail_scroll.as(gtk.Widget).setVexpand(1);
        split.right.append(detail_scroll.as(gtk.Widget));
        root.append(split.root.as(gtk.Widget));
    }

    fn load(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.client(), "listPrompts", "{}");
        defer alloc.free(json);
        const parsed = try vh.parseItems(alloc, json, &.{ "prompts", "items", "data" }, .{
            .id = &.{ "id", "name", "entryFile", "entry_file" },
            .title = &.{ "id", "name", "entryFile", "entry_file" },
            .subtitle = &.{ "entryFile", "entry_file" },
            .body = &.{"source"},
            .path = &.{ "entryFile", "entry_file" },
        });
        vh.clearItems(alloc, &self.private().prompts);
        self.private().prompts = parsed;
        self.private().selected_index = null;
        try self.renderList();
        vh.setStatus(alloc, self.private().detail, "text-x-generic-symbolic", "Select a prompt", "Edit source and preview rendered output.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        if (self.private().prompts.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "text-x-generic-symbolic", "No prompts found", "Smithers prompts appear here.")).as(gtk.Widget));
            return;
        }
        const query = std.mem.trim(u8, std.mem.span(self.private().search_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        var visible: usize = 0;
        for (self.private().prompts.items, 0..) |prompt, index| {
            if (query.len > 0 and !vh.containsIgnoreCase(prompt.title, query) and !vh.containsIgnoreCase(prompt.id, query) and !(prompt.path != null and vh.containsIgnoreCase(prompt.path.?, query))) continue;
            const row = try vh.itemRow(alloc, prompt, "text-x-generic-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            self.private().list.append((try ui.row(alloc, "system-search-symbolic", "No prompts match search", "Adjust the prompt query.")).as(gtk.Widget));
        }
    }

    fn renderDetail(self: *Self, index: usize) !void {
        if (index >= self.private().prompts.items.len) return;
        const alloc = self.allocator();
        const prompt = self.private().prompts.items[index];
        var source_text = try alloc.dupe(u8, prompt.body orelse "");
        defer alloc.free(source_text);
        const full_json = vh.callJson(alloc, self.client(), "getPrompt", &.{.{ .key = "promptId", .value = .{ .string = prompt.id } }}) catch null;
        if (full_json) |json| {
            defer alloc.free(json);
            var full = try vh.parseItems(alloc, json, &.{ "prompt", "items", "data" }, .{
                .id = &.{ "id", "name", "entryFile", "entry_file" },
                .title = &.{ "id", "name", "entryFile", "entry_file" },
                .subtitle = &.{ "entryFile", "entry_file" },
                .body = &.{"source"},
                .path = &.{ "entryFile", "entry_file" },
            });
            defer {
                vh.clearItems(alloc, &full);
                full.deinit(alloc);
            }
            if (full.items.len > 0) {
                alloc.free(source_text);
                source_text = try alloc.dupe(u8, full.items[0].body orelse "");
            }
        }
        ui.clearBox(self.private().detail);
        const title_z = try alloc.dupeZ(u8, prompt.title);
        defer alloc.free(title_z);
        self.private().detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, self.private().detail, "Entry", prompt.path);
        const actions = gtk.Box.new(.horizontal, 8);
        const save = ui.textButton("Save", true);
        _ = gtk.Button.signals.clicked.connect(save, *Self, saveClicked, self, .{});
        actions.append(save.as(gtk.Widget));
        const preview = ui.textButton("Preview", false);
        _ = gtk.Button.signals.clicked.connect(preview, *Self, previewClicked, self, .{});
        actions.append(preview.as(gtk.Widget));
        self.private().detail.append(actions.as(gtk.Widget));
        self.private().source_view = vh.textView(true);
        try vh.setTextViewText(alloc, self.private().source_view, source_text);
        const source_scroll = ui.scrolled(self.private().source_view.as(gtk.Widget));
        source_scroll.as(gtk.Widget).setSizeRequest(-1, 300);
        self.private().detail.append(source_scroll.as(gtk.Widget));
        self.private().input_view = vh.textView(true);
        try vh.setTextViewText(alloc, self.private().input_view, "{}");
        const input_scroll = ui.scrolled(self.private().input_view.as(gtk.Widget));
        input_scroll.as(gtk.Widget).setSizeRequest(-1, 100);
        self.private().detail.append(input_scroll.as(gtk.Widget));
        try self.appendDiscoveredProps(prompt.id);
    }

    fn selectedPrompt(self: *Self) ?vh.Item {
        const index = self.private().selected_index orelse return null;
        if (index >= self.private().prompts.items.len) return null;
        return self.private().prompts.items[index];
    }

    fn savePrompt(self: *Self) void {
        const prompt = self.selectedPrompt() orelse return;
        const alloc = self.allocator();
        const source = vh.getTextViewText(alloc, self.private().source_view) catch return;
        defer alloc.free(source);
        const json = vh.callJson(alloc, self.client(), "updatePrompt", &.{
            .{ .key = "promptId", .value = .{ .string = prompt.id } },
            .{ .key = "source", .value = .{ .string = source } },
        }) catch |err| {
            self.private().window.showToastFmt("Save prompt failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Saved {s}", .{prompt.id});
    }

    fn previewPrompt(self: *Self) void {
        const prompt = self.selectedPrompt() orelse return;
        const alloc = self.allocator();
        const source = vh.getTextViewText(alloc, self.private().source_view) catch return;
        defer alloc.free(source);
        const input = vh.getTextViewText(alloc, self.private().input_view) catch return;
        defer alloc.free(input);
        const json = vh.callJson(alloc, self.client(), "previewPrompt", &.{
            .{ .key = "promptId", .value = .{ .string = prompt.id } },
            .{ .key = "source", .value = .{ .string = source } },
            .{ .key = "input", .value = .{ .raw = input } },
        }) catch |err| {
            self.private().window.showToastFmt("Preview failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        const text = vh.parseStringResult(alloc, json) catch alloc.dupe(u8, json) catch return;
        defer alloc.free(text);
        const view = vh.textView(false);
        vh.setTextViewText(alloc, view, text) catch return;
        const scroll = ui.scrolled(view.as(gtk.Widget));
        scroll.as(gtk.Widget).setSizeRequest(-1, 180);
        self.private().detail.append(scroll.as(gtk.Widget));
    }

    fn appendDiscoveredProps(self: *Self, prompt_id: []const u8) !void {
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "discoverPromptProps", &.{.{ .key = "promptId", .value = .{ .string = prompt_id } }}) catch return;
        defer alloc.free(json);
        var props = vh.parseItems(alloc, json, &.{ "props", "inputs", "items", "data" }, .{
            .id = &.{ "key", "name", "id" },
            .title = &.{ "key", "name", "id" },
            .subtitle = &.{ "type", "kind", "default", "defaultValue" },
            .body = &.{ "description", "help" },
        }) catch std.ArrayList(vh.Item).empty;
        defer {
            vh.clearItems(alloc, &props);
            props.deinit(alloc);
        }
        vh.addSectionTitle(self.private().detail, "Discovered Props");
        const list = vh.listBox();
        if (props.items.len == 0) {
            list.append((try ui.row(alloc, "insert-text-symbolic", "No props discovered", "Use JSON test input for ad-hoc values.")).as(gtk.Widget));
        } else {
            for (props.items) |prop| {
                list.append((try vh.itemRow(alloc, prop, "insert-text-symbolic")).as(gtk.Widget));
            }
        }
        self.private().detail.append(list.as(gtk.Widget));
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.renderList() catch {};
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.renderDetail(index) catch {};
    }

    fn saveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.savePrompt();
    }

    fn previewClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.previewPrompt();
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn shortcutSearch(self: *Self) void {
        _ = self.private().search_entry.as(gtk.Widget).grabFocus();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            vh.clearItems(self.allocator(), &priv.prompts);
            priv.prompts.deinit(self.allocator());
            ui.clearBox(self.as(gtk.Box));
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
