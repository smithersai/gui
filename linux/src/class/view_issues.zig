const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const IssuesView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersIssuesView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        search_entry: *gtk.Entry = undefined,
        title_entry: *gtk.Entry = undefined,
        body_view: *gtk.TextView = undefined,
        close_comment: *gtk.TextView = undefined,
        items: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        state_filter: ?[]const u8 = "open",
        create_visible: bool = false,
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
        self.load() catch |err| vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Issues unavailable", @errorName(err));
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
        const header = vh.makeHeader("Issues", null);
        self.private().search_entry = gtk.Entry.new();
        self.private().search_entry.setPlaceholderText("Search issues");
        self.private().search_entry.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().search_entry.as(gtk.Editable), *Self, searchChanged, self, .{});
        header.append(self.private().search_entry.as(gtk.Widget));
        inline for (.{ "Open", "Closed", "All" }) |label| {
            const button = ui.textButton(label, false);
            _ = gtk.Button.signals.clicked.connect(button, *Self, filterClicked, self, .{});
            button.as(gobject.Object).setData("smithers-issue-filter", @constCast(label.ptr));
            header.append(button.as(gtk.Widget));
        }
        const add = ui.iconButton("list-add-symbolic", "New issue");
        _ = gtk.Button.signals.clicked.connect(add, *Self, newClicked, self, .{});
        header.append(add.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh issues");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const split = vh.splitPane(330);
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
        const json = try vh.callJson(alloc, self.client(), "listIssues", &.{.{ .key = "state", .value = .{ .optional_string = self.private().state_filter } }});
        defer alloc.free(json);
        const parsed = try vh.parseItems(alloc, json, &.{ "issues", "items", "results", "data" }, .{
            .id = &.{ "id", "number", "title" },
            .title = &.{"title"},
            .subtitle = &.{ "labels", "assignees" },
            .status = &.{ "state", "status" },
            .body = &.{ "body", "description" },
            .number = &.{"number"},
        });
        vh.clearItems(alloc, &self.private().items);
        self.private().items = parsed;
        self.private().selected_index = null;
        try self.renderList();
        if (self.private().create_visible) try self.renderCreate() else vh.setStatus(alloc, self.private().detail, "emblem-documents-symbolic", "Select an issue", "Issue details and actions appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        if (self.private().items.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "emblem-documents-symbolic", "No issues found", "Create or change the state filter.")).as(gtk.Widget));
            return;
        }
        const query = std.mem.trim(u8, std.mem.span(self.private().search_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        var visible: usize = 0;
        for (self.private().items.items, 0..) |item, index| {
            if (query.len > 0 and
                !vh.containsIgnoreCase(item.title, query) and
                !vh.containsIgnoreCase(item.id, query) and
                !(item.body != null and vh.containsIgnoreCase(item.body.?, query))) continue;
            const row = try vh.itemRow(alloc, item, if (item.status != null and std.ascii.eqlIgnoreCase(item.status.?, "open")) "radio-symbolic" else "emblem-ok-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            self.private().list.append((try ui.row(alloc, "system-search-symbolic", "No issues match filters", "Adjust search or state filter.")).as(gtk.Widget));
        }
    }

    fn renderCreate(self: *Self) !void {
        ui.clearBox(self.private().detail);
        self.private().detail.append(ui.heading("New Issue").as(gtk.Widget));
        self.private().title_entry = gtk.Entry.new();
        self.private().title_entry.setPlaceholderText("Title");
        self.private().detail.append(self.private().title_entry.as(gtk.Widget));
        self.private().body_view = vh.textView(true);
        const scroll = ui.scrolled(self.private().body_view.as(gtk.Widget));
        scroll.as(gtk.Widget).setSizeRequest(-1, 240);
        self.private().detail.append(scroll.as(gtk.Widget));
        const create = ui.textButton("Create", true);
        _ = gtk.Button.signals.clicked.connect(create, *Self, createClicked, self, .{});
        self.private().detail.append(create.as(gtk.Widget));
    }

    fn renderDetail(self: *Self, index: usize) !void {
        if (index >= self.private().items.items.len) return;
        const alloc = self.allocator();
        const item = self.private().items.items[index];
        ui.clearBox(self.private().detail);
        const title_z = try alloc.dupeZ(u8, item.title);
        defer alloc.free(title_z);
        self.private().detail.append(ui.heading(title_z).as(gtk.Widget));
        const number_text = if (item.number) |n| try std.fmt.allocPrint(alloc, "#{d}", .{n}) else null;
        defer if (number_text) |text| alloc.free(text);
        try vh.detailRow(alloc, self.private().detail, "Number", number_text);
        try vh.detailRow(alloc, self.private().detail, "State", item.status);
        try vh.detailRow(alloc, self.private().detail, "Labels", item.subtitle);
        try vh.detailRow(alloc, self.private().detail, "Body", item.body);
        vh.addSectionTitle(self.private().detail, "Close Comment");
        self.private().close_comment = vh.textView(true);
        try vh.setTextViewText(alloc, self.private().close_comment, "");
        const comment_scroll = ui.scrolled(self.private().close_comment.as(gtk.Widget));
        comment_scroll.as(gtk.Widget).setSizeRequest(-1, 110);
        self.private().detail.append(comment_scroll.as(gtk.Widget));
        const actions = vh.actionBar();
        const close = ui.textButton("Close", false);
        _ = gtk.Button.signals.clicked.connect(close, *Self, closeClicked, self, .{});
        actions.append(close.as(gtk.Widget));
        const reopen = ui.textButton("Reopen", false);
        _ = gtk.Button.signals.clicked.connect(reopen, *Self, reopenClicked, self, .{});
        actions.append(reopen.as(gtk.Widget));
        self.private().detail.append(actions.as(gtk.Widget));
    }

    fn createIssue(self: *Self) void {
        const alloc = self.allocator();
        const title = std.mem.trim(u8, std.mem.span(self.private().title_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (title.len == 0) {
            self.private().window.showToast("Issue title is required");
            return;
        }
        const body = vh.getTextViewText(alloc, self.private().body_view) catch return;
        defer alloc.free(body);
        const json = vh.callJson(alloc, self.client(), "createIssue", &.{
            .{ .key = "title", .value = .{ .string = title } },
            .{ .key = "body", .value = .{ .string = body } },
        }) catch |err| {
            self.private().window.showToastFmt("Create issue failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Created issue {s}", .{title});
        self.private().create_visible = false;
        self.private().state_filter = "open";
        self.refresh();
    }

    fn issueAction(self: *Self, method: []const u8, label: []const u8) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().items.items.len) return;
        const number = self.private().items.items[index].number orelse {
            self.private().window.showToast("Issue number is required");
            return;
        };
        const alloc = self.allocator();
        const comment = if (std.mem.eql(u8, method, "closeIssue"))
            vh.getTextViewText(alloc, self.private().close_comment) catch return
        else
            alloc.dupe(u8, "") catch return;
        defer alloc.free(comment);
        const json = if (std.mem.eql(u8, method, "closeIssue"))
            vh.callJson(alloc, self.client(), method, &.{
                .{ .key = "number", .value = .{ .integer = number } },
                .{ .key = "comment", .value = .{ .optional_string = if (std.mem.trim(u8, comment, &std.ascii.whitespace).len == 0) null else std.mem.trim(u8, comment, &std.ascii.whitespace) } },
            })
        else
            vh.callJson(alloc, self.client(), method, &.{.{ .key = "number", .value = .{ .integer = number } }});
        const result = json catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(result);
        self.private().window.showToastFmt("{s} #{d}", .{ label, number });
        self.refresh();
    }

    fn refreshIssueDetail(self: *Self, index: usize) void {
        if (index >= self.private().items.items.len) return;
        const number = self.private().items.items[index].number orelse return;
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "getIssue", &.{.{ .key = "number", .value = .{ .integer = number } }}) catch return;
        defer alloc.free(json);
        var parsed = vh.parseItems(alloc, json, &.{ "issue", "issues", "items", "data" }, .{
            .id = &.{ "id", "number", "title" },
            .title = &.{"title"},
            .subtitle = &.{ "labels", "assignees" },
            .status = &.{ "state", "status" },
            .body = &.{ "body", "description" },
            .number = &.{"number"},
        }) catch return;
        defer {
            vh.clearItems(alloc, &parsed);
            parsed.deinit(alloc);
        }
        if (parsed.items.len == 0) return;
        self.private().items.items[index].deinit(alloc);
        self.private().items.items[index] = parsed.items[0];
        _ = parsed.orderedRemove(0);
    }

    fn filterClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-issue-filter") orelse return;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        self.private().state_filter = if (std.mem.eql(u8, text, "All")) null else if (std.mem.eql(u8, text, "Open")) "open" else "closed";
        self.refresh();
    }

    fn newClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().create_visible = !self.private().create_visible;
        if (self.private().create_visible) self.renderCreate() catch {} else self.refresh();
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
        self.private().create_visible = false;
        self.refreshIssueDetail(index);
        self.renderDetail(index) catch {};
    }

    fn createClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.createIssue();
    }

    fn closeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.issueAction("closeIssue", "Closed");
    }

    fn reopenClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.issueAction("reopenIssue", "Reopened");
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
            vh.clearItems(self.allocator(), &priv.items);
            priv.items.deinit(self.allocator());
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
