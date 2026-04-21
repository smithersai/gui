const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const MemoryView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersMemoryView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        namespace_entry: *gtk.Entry = undefined,
        query_entry: *gtk.Entry = undefined,
        topk_scale: *gtk.Scale = undefined,
        facts: std.ArrayList(vh.Item) = .empty,
        recall: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        recall_mode: bool = false,
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
        if (self.private().recall_mode) self.doRecall() else self.loadFacts();
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
        const header = vh.makeHeader("Memory", null);
        const mode = ui.textButton("Recall", false);
        _ = gtk.Button.signals.clicked.connect(mode, *Self, modeClicked, self, .{});
        header.append(mode.as(gtk.Widget));
        self.private().namespace_entry = gtk.Entry.new();
        self.private().namespace_entry.setPlaceholderText("Namespace");
        self.private().namespace_entry.as(gtk.Widget).setSizeRequest(160, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().namespace_entry, *Self, namespaceActivated, self, .{});
        header.append(self.private().namespace_entry.as(gtk.Widget));
        self.private().query_entry = gtk.Entry.new();
        self.private().query_entry.setPlaceholderText("Recall query");
        self.private().query_entry.as(gtk.Widget).setSizeRequest(240, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().query_entry, *Self, queryActivated, self, .{});
        header.append(self.private().query_entry.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh memory");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const controls = gtk.Box.new(.horizontal, 8);
        ui.margin4(controls.as(gtk.Widget), 0, 16, 8, 16);
        controls.append(ui.dim("Top-K").as(gtk.Widget));
        self.private().topk_scale = gtk.Scale.newWithRange(.horizontal, 1, 50, 1);
        self.private().topk_scale.as(gtk.Range).setValue(10);
        self.private().topk_scale.as(gtk.Widget).setHexpand(1);
        controls.append(self.private().topk_scale.as(gtk.Widget));
        root.append(controls.as(gtk.Widget));

        const split = vh.splitPane(360);
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

    fn loadFacts(self: *Self) void {
        self.private().recall_mode = false;
        const alloc = self.allocator();
        const json = smithers.callJson(alloc, self.client(), "listAllMemoryFacts", "{}") catch |err| {
            vh.setStatus(alloc, self.private().detail, "dialog-error-symbolic", "Memory unavailable", @errorName(err));
            return;
        };
        defer alloc.free(json);
        const parsed = vh.parseItems(alloc, json, &.{ "facts", "items", "data" }, .{
            .id = &.{ "id", "key" },
            .title = &.{"key"},
            .subtitle = &.{"namespace"},
            .body = &.{ "valueJson", "value_json", "value" },
            .status = &.{ "schemaSig", "schema_sig" },
        }) catch std.ArrayList(vh.Item).empty;
        vh.clearItems(alloc, &self.private().facts);
        self.private().facts = parsed;
        self.renderItems(self.private().facts.items, "No memory facts", "Facts written by workflows appear here.") catch {};
    }

    fn doRecall(self: *Self) void {
        self.private().recall_mode = true;
        const query = std.mem.trim(u8, std.mem.span(self.private().query_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (query.len == 0) {
            vh.setStatus(self.allocator(), self.private().detail, "system-search-symbolic", "Enter a recall query", "Recall searches semantic memory.");
            return;
        }
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "recallMemory", &.{
            .{ .key = "query", .value = .{ .string = query } },
            .{ .key = "namespace", .value = .{ .optional_string = namespaceFilter(self) } },
            .{ .key = "topK", .value = .{ .integer = @intFromFloat(self.private().topk_scale.as(gtk.Range).getValue()) } },
        }) catch |err| {
            vh.setStatus(alloc, self.private().detail, "dialog-error-symbolic", "Recall failed", @errorName(err));
            return;
        };
        defer alloc.free(json);
        const parsed = vh.parseItems(alloc, json, &.{ "results", "items", "data" }, .{
            .id = &.{ "id", "content" },
            .title = &.{"content"},
            .subtitle = &.{"metadata"},
            .body = &.{"content"},
            .score = &.{"score"},
        }) catch std.ArrayList(vh.Item).empty;
        vh.clearItems(alloc, &self.private().recall);
        self.private().recall = parsed;
        self.renderItems(self.private().recall.items, "No recall results", "Try a broader query.") catch {};
    }

    fn renderItems(self: *Self, items: []const vh.Item, empty_title: []const u8, empty_detail: []const u8) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        ui.clearBox(self.private().detail);
        self.private().selected_index = null;
        if (items.len == 0) {
            self.private().list.append((try ui.row(alloc, "view-list-symbolic", empty_title, empty_detail)).as(gtk.Widget));
            vh.setStatus(alloc, self.private().detail, "document-open-recent-symbolic", empty_title, empty_detail);
            return;
        }
        var visible: usize = 0;
        for (items, 0..) |item, index| {
            if (!self.private().recall_mode) {
                if (namespaceFilter(self)) |namespace| {
                    if (item.subtitle == null or !std.ascii.eqlIgnoreCase(item.subtitle.?, namespace)) continue;
                }
            }
            const row = try vh.itemRow(alloc, item, "document-open-recent-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            self.private().list.append((try ui.row(alloc, "system-search-symbolic", "No memory items match filters", "Adjust namespace or recall query.")).as(gtk.Widget));
        }
        vh.setStatus(alloc, self.private().detail, "document-open-recent-symbolic", "Select a memory item", "Full value and metadata appear here.");
    }

    fn renderDetail(self: *Self, index: usize) !void {
        const source = if (self.private().recall_mode) self.private().recall.items else self.private().facts.items;
        if (index >= source.len) return;
        const item = source[index];
        const alloc = self.allocator();
        ui.clearBox(self.private().detail);
        const title_z = try alloc.dupeZ(u8, item.title);
        defer alloc.free(title_z);
        self.private().detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, self.private().detail, if (self.private().recall_mode) "Score" else "Namespace", item.subtitle);
        try vh.detailRow(alloc, self.private().detail, "Schema", item.status);
        const actions = vh.actionBar();
        const open = ui.textButton("Open Detail", true);
        _ = gtk.Button.signals.clicked.connect(open, *Self, openDetailClicked, self, .{});
        actions.append(open.as(gtk.Widget));
        if (!self.private().recall_mode) {
            const delete = ui.textButton("Delete", false);
            delete.as(gtk.Widget).addCssClass("destructive-action");
            _ = gtk.Button.signals.clicked.connect(delete, *Self, deleteClicked, self, .{});
            actions.append(delete.as(gtk.Widget));
        }
        self.private().detail.append(actions.as(gtk.Widget));
        const view = vh.textView(false);
        try vh.setTextViewText(alloc, view, item.body orelse item.title);
        const scroll = ui.scrolled(view.as(gtk.Widget));
        scroll.as(gtk.Widget).setSizeRequest(-1, 360);
        self.private().detail.append(scroll.as(gtk.Widget));
    }

    fn namespaceFilter(self: *Self) ?[]const u8 {
        const value = vh.trimEntryText(self.private().namespace_entry);
        return if (value.len == 0) null else value;
    }

    fn selectedItem(self: *Self) ?vh.Item {
        const index = self.private().selected_index orelse return null;
        const source = if (self.private().recall_mode) self.private().recall.items else self.private().facts.items;
        if (index >= source.len) return null;
        return source[index];
    }

    fn showDetailDialog(self: *Self) void {
        const item = self.selectedItem() orelse return;
        const alloc = self.allocator();
        const dialog = adw.Dialog.new();
        dialog.setTitle("Memory Detail");
        dialog.setContentWidth(680);
        dialog.setContentHeight(520);
        const box = gtk.Box.new(.vertical, 12);
        ui.margin(box.as(gtk.Widget), 18);
        const title_z = alloc.dupeZ(u8, item.title) catch return;
        defer alloc.free(title_z);
        box.append(ui.heading(title_z).as(gtk.Widget));
        vh.detailRow(alloc, box, "ID", item.id) catch {};
        vh.detailRow(alloc, box, "Namespace", item.subtitle) catch {};
        vh.detailRow(alloc, box, "Schema", item.status) catch {};
        vh.appendJsonViewer(alloc, box, "Value", item.body orelse item.title, 360) catch {};
        dialog.setChild(box.as(gtk.Widget));
        dialog.present(self.as(gtk.Widget));
    }

    fn deleteSelectedFact(self: *Self) void {
        if (self.private().recall_mode) return;
        const item = self.selectedItem() orelse return;
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "deleteMemoryFact", &.{.{ .key = "id", .value = .{ .string = item.id } }}) catch |err| {
            self.private().window.showToastFmt("Delete failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Deleted memory fact {s}", .{item.id});
        self.loadFacts();
    }

    fn modeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().recall_mode = !self.private().recall_mode;
        self.refresh();
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn namespaceActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        if (self.private().recall_mode) self.doRecall() else self.renderItems(self.private().facts.items, "No memory facts", "Facts written by workflows appear here.") catch {};
    }

    fn queryActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.private().recall_mode = true;
        self.doRecall();
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.renderDetail(index) catch {};
    }

    fn openDetailClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showDetailDialog();
    }

    fn deleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.deleteSelectedFact();
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            vh.clearItems(self.allocator(), &priv.facts);
            priv.facts.deinit(self.allocator());
            vh.clearItems(self.allocator(), &priv.recall);
            priv.recall.deinit(self.allocator());
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
