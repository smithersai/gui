const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;
const UnifiedDiffView = @import("diff.zig").UnifiedDiffView;

pub const ChangesView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersChangesView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        search_entry: *gtk.Entry = undefined,
        bookmark_entry: *gtk.Entry = undefined,
        remote_check: *gtk.CheckButton = undefined,
        changes: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        status_mode: bool = false,
        working_copy_only: bool = false,
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
        if (self.private().status_mode) self.loadStatus() else self.loadChanges();
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
        vh.installShortcut(Self, root.as(gtk.Widget), "F5", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>f", self, shortcutSearch);
        const header = vh.makeHeader("Changes", null);
        self.private().search_entry = gtk.Entry.new();
        self.private().search_entry.setPlaceholderText("Search changes");
        self.private().search_entry.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().search_entry.as(gtk.Editable), *Self, searchChanged, self, .{});
        header.append(self.private().search_entry.as(gtk.Widget));
        const mode = ui.textButton("Status", false);
        _ = gtk.Button.signals.clicked.connect(mode, *Self, modeClicked, self, .{});
        header.append(mode.as(gtk.Widget));
        const wc = ui.textButton("Working Copy", false);
        _ = gtk.Button.signals.clicked.connect(wc, *Self, workingCopyClicked, self, .{});
        header.append(wc.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh changes");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const split = vh.splitPane(340);
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
        vh.setStatus(self.allocator(), self.private().detail, "view-list-symbolic", "Select a change", "Change metadata, diff, and bookmarks appear here.");
    }

    fn loadChanges(self: *Self) void {
        const alloc = self.allocator();
        self.private().status_mode = false;
        const json = vh.callJson(alloc, self.client(), "listChanges", &.{.{ .key = "limit", .value = .{ .integer = 100 } }}) catch |err| {
            vh.setStatus(alloc, self.private().detail, "dialog-error-symbolic", "Changes unavailable", @errorName(err));
            return;
        };
        defer alloc.free(json);
        const parsed = vh.parseItems(alloc, json, &.{ "changes", "items", "data" }, .{
            .id = &.{ "change_id", "changeID", "id" },
            .title = &.{ "description", "change_id", "changeID" },
            .subtitle = &.{ "commit_id", "commitID", "timestamp" },
            .body = &.{"description"},
            .path = &.{"bookmarks"},
            .status = &.{ "is_working_copy", "isWorkingCopy" },
        }) catch std.ArrayList(vh.Item).empty;
        vh.clearItems(alloc, &self.private().changes);
        self.private().changes = parsed;
        self.private().selected_index = null;
        self.renderList() catch {};
        vh.setStatus(alloc, self.private().detail, "view-list-symbolic", "Select a change", "Change metadata, diff, and bookmarks appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        if (self.private().changes.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "view-list-symbolic", "No changes found", "JJHub changes appear here.")).as(gtk.Widget));
            return;
        }
        const query = std.mem.trim(u8, std.mem.span(self.private().search_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        var visible: usize = 0;
        for (self.private().changes.items, 0..) |change, index| {
            if (self.private().working_copy_only and !(change.status != null and (std.ascii.eqlIgnoreCase(change.status.?, "true") or std.mem.eql(u8, change.status.?, "1")))) continue;
            if (query.len > 0 and !vh.containsIgnoreCase(change.title, query) and !vh.containsIgnoreCase(change.id, query) and !(change.subtitle != null and vh.containsIgnoreCase(change.subtitle.?, query))) continue;
            const row = try vh.itemRow(alloc, change, "view-list-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            self.private().list.append((try ui.row(alloc, "system-search-symbolic", "No changes match filters", "Adjust search or working-copy filter.")).as(gtk.Widget));
        }
    }

    fn renderDetail(self: *Self, index: usize) !void {
        if (index >= self.private().changes.items.len) return;
        const alloc = self.allocator();
        const change = self.private().changes.items[index];
        const detail = self.private().detail;
        ui.clearBox(detail);
        const title_z = try alloc.dupeZ(u8, change.title);
        defer alloc.free(title_z);
        detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, detail, "Change", change.id);
        try vh.detailRow(alloc, detail, "Commit", change.subtitle);
        try vh.detailRow(alloc, detail, "Bookmarks", change.path);
        const actions = gtk.Box.new(.horizontal, 8);
        const diff = ui.textButton("Load Diff", true);
        _ = gtk.Button.signals.clicked.connect(diff, *Self, diffClicked, self, .{});
        actions.append(diff.as(gtk.Widget));
        const create = ui.textButton("Create Bookmark", false);
        _ = gtk.Button.signals.clicked.connect(create, *Self, createBookmarkClicked, self, .{});
        actions.append(create.as(gtk.Widget));
        const delete = ui.textButton("Delete Bookmark", false);
        delete.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(delete, *Self, deleteBookmarkClicked, self, .{});
        actions.append(delete.as(gtk.Widget));
        const push = ui.textButton("Push", false);
        _ = gtk.Button.signals.clicked.connect(push, *Self, pushClicked, self, .{});
        actions.append(push.as(gtk.Widget));
        detail.append(actions.as(gtk.Widget));
        self.private().bookmark_entry = gtk.Entry.new();
        self.private().bookmark_entry.setPlaceholderText("bookmark name");
        detail.append(self.private().bookmark_entry.as(gtk.Widget));
        self.private().remote_check = gtk.CheckButton.newWithLabel("Remote");
        self.private().remote_check.setActive(1);
        detail.append(self.private().remote_check.as(gtk.Widget));
    }

    fn loadStatus(self: *Self) void {
        const alloc = self.allocator();
        self.private().status_mode = true;
        ui.clearList(self.private().list);
        self.private().list.append((ui.row(alloc, "view-list-symbolic", "Working Copy Status", "Current jjhub status") catch return).as(gtk.Widget));
        ui.clearBox(self.private().detail);
        const status = smithers.callJson(alloc, self.client(), "status", "{}") catch |err| {
            vh.setStatus(alloc, self.private().detail, "dialog-error-symbolic", "Status unavailable", @errorName(err));
            return;
        };
        defer alloc.free(status);
        const diff = smithers.callJson(alloc, self.client(), "workingCopyDiff", "{}") catch fallback: {
            break :fallback vh.callJson(alloc, self.client(), "changeDiff", &.{.{ .key = "changeID", .value = .{ .string = "@" } }}) catch alloc.dupe(u8, "") catch return;
        };
        defer alloc.free(diff);
        self.private().detail.append(ui.heading("Working Copy").as(gtk.Widget));
        const text = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ status, diff }) catch return;
        defer alloc.free(text);
        vh.appendJsonViewer(alloc, self.private().detail, "Status", status, 180) catch return;
        const diff_view = UnifiedDiffView.new(alloc, diff, "working-copy.diff") catch {
            vh.appendJsonViewer(alloc, self.private().detail, "Diff", text, 360) catch return;
            return;
        };
        diff_view.as(gtk.Widget).setSizeRequest(-1, 360);
        self.private().detail.append(diff_view.as(gtk.Widget));
    }

    fn showDiff(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().changes.items.len) return;
        const change = self.private().changes.items[index];
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "changeDiff", &.{.{ .key = "changeID", .value = .{ .string = change.id } }}) catch |err| {
            self.private().window.showToastFmt("Diff failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        const text = vh.parseStringResult(alloc, json) catch alloc.dupe(u8, json) catch return;
        defer alloc.free(text);
        const diff = UnifiedDiffView.new(alloc, text, change.id) catch return;
        diff.as(gtk.Widget).setSizeRequest(-1, 360);
        self.private().detail.append(diff.as(gtk.Widget));
    }

    fn refreshChangeDetail(self: *Self, index: usize) void {
        if (index >= self.private().changes.items.len) return;
        const change = self.private().changes.items[index];
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "viewChange", &.{.{ .key = "changeID", .value = .{ .string = change.id } }}) catch return;
        defer alloc.free(json);
        var parsed = vh.parseItems(alloc, json, &.{ "change", "changes", "items", "data" }, .{
            .id = &.{ "change_id", "changeID", "id" },
            .title = &.{ "description", "change_id", "changeID" },
            .subtitle = &.{ "commit_id", "commitID", "timestamp" },
            .body = &.{"description"},
            .path = &.{"bookmarks"},
            .status = &.{ "is_working_copy", "isWorkingCopy" },
        }) catch return;
        defer {
            vh.clearItems(alloc, &parsed);
            parsed.deinit(alloc);
        }
        if (parsed.items.len == 0) return;
        self.private().changes.items[index].deinit(alloc);
        self.private().changes.items[index] = parsed.items[0];
        _ = parsed.orderedRemove(0);
    }

    fn remoteEnabled(self: *Self) bool {
        return self.private().remote_check.getActive() != 0;
    }

    fn bookmarkAction(self: *Self, method: []const u8, label: []const u8) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().changes.items.len) return;
        const change = self.private().changes.items[index];
        const name = std.mem.trim(u8, std.mem.span(self.private().bookmark_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (name.len == 0) {
            self.private().window.showToast("Bookmark name is required");
            return;
        }
        const alloc = self.allocator();
        const json = if (std.mem.eql(u8, method, "createBookmark"))
            vh.callJson(alloc, self.client(), method, &.{
                .{ .key = "name", .value = .{ .string = name } },
                .{ .key = "changeID", .value = .{ .string = change.id } },
                .{ .key = "remote", .value = .{ .boolean = self.remoteEnabled() } },
            })
        else
            vh.callJson(alloc, self.client(), method, &.{
                .{ .key = "name", .value = .{ .string = name } },
                .{ .key = "remote", .value = .{ .boolean = self.remoteEnabled() } },
            });
        const result = json catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(result);
        self.private().window.showToastFmt("{s} {s}", .{ label, name });
        self.refresh();
    }

    fn pushSelected(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().changes.items.len) return;
        const change = self.private().changes.items[index];
        const bookmark = std.mem.trim(u8, std.mem.span(self.private().bookmark_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "push", &.{
            .{ .key = "changeID", .value = .{ .string = change.id } },
            .{ .key = "bookmark", .value = .{ .optional_string = if (bookmark.len == 0) null else bookmark } },
            .{ .key = "remote", .value = .{ .boolean = self.remoteEnabled() } },
        }) catch |err| {
            self.private().window.showToastFmt("Push failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToast(if (bookmark.len == 0) "Pushed change" else "Pushed bookmark");
        self.refresh();
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.renderList() catch {};
    }

    fn modeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().status_mode = !self.private().status_mode;
        self.refresh();
    }

    fn workingCopyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().working_copy_only = !self.private().working_copy_only;
        self.renderList() catch {};
        self.private().window.showToast(if (self.private().working_copy_only) "Showing working-copy changes" else "Showing all changes");
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.refreshChangeDetail(index);
        self.renderDetail(index) catch {};
    }

    fn diffClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showDiff();
    }

    fn createBookmarkClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.bookmarkAction("createBookmark", "Created bookmark");
    }

    fn deleteBookmarkClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.bookmarkAction("deleteBookmark", "Deleted bookmark");
    }

    fn pushClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.pushSelected();
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
            vh.clearItems(self.allocator(), &priv.changes);
            priv.changes.deinit(self.allocator());
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
