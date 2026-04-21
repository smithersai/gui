const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;
const UnifiedDiffView = @import("diff.zig").UnifiedDiffView;

pub const VCSDashboardView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersVCSDashboardView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        body: *gtk.Box = undefined,
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
        self.refreshImpl() catch |err| vh.setStatus(self.allocator(), self.private().body, "dialog-error-symbolic", "VCS dashboard unavailable", @errorName(err));
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
        const header = vh.makeHeader("VCS Dashboard", null);
        const changes_button = ui.textButton("Changes", true);
        _ = gtk.Button.signals.clicked.connect(changes_button, *Self, changesClicked, self, .{});
        header.append(changes_button.as(gtk.Widget));
        const landings_button = ui.textButton("Landings", false);
        _ = gtk.Button.signals.clicked.connect(landings_button, *Self, landingsClicked, self, .{});
        header.append(landings_button.as(gtk.Widget));
        const issues_button = ui.textButton("Issues", false);
        _ = gtk.Button.signals.clicked.connect(issues_button, *Self, issuesClicked, self, .{});
        header.append(issues_button.as(gtk.Widget));
        const tickets_button = ui.textButton("Tickets", false);
        _ = gtk.Button.signals.clicked.connect(tickets_button, *Self, ticketsClicked, self, .{});
        header.append(tickets_button.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh VCS dashboard");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));
        self.private().body = gtk.Box.new(.vertical, 16);
        ui.margin(self.private().body.as(gtk.Widget), 20);
        const scroll = ui.scrolled(self.private().body.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));
    }

    fn refreshImpl(self: *Self) !void {
        const alloc = self.allocator();
        const changes = try self.loadItems("listChanges", &.{.{ .key = "limit", .value = .{ .integer = 20 } }}, &.{ "changes", "items", "data" }, .{
            .id = &.{ "change_id", "changeID", "id" },
            .title = &.{ "description", "change_id", "changeID" },
            .subtitle = &.{ "commit_id", "commitID", "timestamp" },
            .status = &.{ "is_working_copy", "isWorkingCopy" },
        });
        defer {
            var mutable = changes;
            vh.clearItems(alloc, &mutable);
            mutable.deinit(alloc);
        }
        const landings = try self.loadItems("listLandings", &.{.{ .key = "state", .value = .null }}, &.{ "landings", "items", "data" }, .{
            .id = &.{ "id", "number", "title" },
            .title = &.{"title"},
            .status = &.{"state"},
            .number = &.{"number"},
        });
        defer {
            var mutable = landings;
            vh.clearItems(alloc, &mutable);
            mutable.deinit(alloc);
        }
        const issues = try self.loadItems("listIssues", &.{.{ .key = "state", .value = .{ .string = "open" } }}, &.{ "issues", "items", "results", "data" }, .{
            .id = &.{ "id", "number", "title" },
            .title = &.{"title"},
            .status = &.{"state"},
            .number = &.{"number"},
        });
        defer {
            var mutable = issues;
            vh.clearItems(alloc, &mutable);
            mutable.deinit(alloc);
        }
        const tickets = try self.loadItems("listTickets", &.{}, &.{ "tickets", "items", "data" }, .{
            .id = &.{ "id", "ticketId", "ticket_id" },
            .title = &.{ "id", "ticketId", "ticket_id" },
            .subtitle = &.{"status"},
        });
        defer {
            var mutable = tickets;
            vh.clearItems(alloc, &mutable);
            mutable.deinit(alloc);
        }
        const workflows = try self.loadItems("listJJHubWorkflows", &.{.{ .key = "limit", .value = .{ .integer = 20 } }}, &.{ "workflows", "items", "data" }, .{
            .id = &.{"id"},
            .title = &.{"name"},
            .subtitle = &.{"path"},
            .enabled = &.{ "is_active", "isActive" },
        });
        defer {
            var mutable = workflows;
            vh.clearItems(alloc, &mutable);
            mutable.deinit(alloc);
        }
        var recent_commits = self.loadItems("recentCommits", &.{.{ .key = "limit", .value = .{ .integer = 10 } }}, &.{ "commits", "changes", "items", "data" }, .{
            .id = &.{ "commit_id", "commitID", "id", "change_id", "changeID" },
            .title = &.{ "description", "message", "summary", "commit_id", "commitID" },
            .subtitle = &.{ "author", "timestamp", "created_at", "createdAt" },
            .status = &.{ "bookmark", "bookmarks" },
        }) catch std.ArrayList(vh.Item).empty;
        defer {
            vh.clearItems(alloc, &recent_commits);
            recent_commits.deinit(alloc);
        }

        const body = self.private().body;
        ui.clearBox(body);
        const repo = smithers.callJson(alloc, self.client(), "getCurrentRepo", "{}") catch null;
        defer if (repo) |text| alloc.free(text);
        const status = smithers.callJson(alloc, self.client(), "status", "{}") catch null;
        defer if (status) |text| alloc.free(text);
        const sync_status = smithers.callJson(alloc, self.client(), "syncStatus", "{}") catch null;
        defer if (sync_status) |text| alloc.free(text);
        const diff = smithers.callJson(alloc, self.client(), "workingCopyDiff", "{}") catch null;
        defer if (diff) |text| alloc.free(text);

        try self.appendSyncSummary(repo, status, sync_status, changes.items);
        try self.appendChangesIndicator(changes.items, diff);
        if (status) |text| {
            try vh.appendJsonViewer(alloc, body, "JJ Status", text, 150);
        }
        if (diff) |text| {
            const diff_view = UnifiedDiffView.new(alloc, text, "working-copy.diff") catch null;
            if (diff_view) |view| {
                view.as(gtk.Widget).setSizeRequest(-1, 320);
                body.append(view.as(gtk.Widget));
            }
        }
        if (sync_status) |text| {
            try vh.appendJsonViewer(alloc, body, "Sync Status", text, 130);
        }
        const metrics = gtk.Box.new(.horizontal, 12);
        try vh.appendMetric(alloc, metrics, "Changes", changes.items.len, "recent JJHub changes");
        try vh.appendMetric(alloc, metrics, "Landings", countOpen(landings.items), "open or ready");
        try vh.appendMetric(alloc, metrics, "Issues", issues.items.len, "open issues");
        try vh.appendMetric(alloc, metrics, "Tickets", tickets.items.len, "local Smithers tickets");
        body.append(metrics.as(gtk.Widget));

        try self.appendSection("Recent Changes", changes.items, "view-list-symbolic");
        try self.appendRecentCommits(recent_commits.items, changes.items);
        try self.appendSection("Open Landings", landings.items, "emblem-documents-symbolic");
        try self.appendSection("Open Issues", issues.items, "emblem-documents-symbolic");
        try self.appendSection("JJHub Workflows", workflows.items, "media-playlist-shuffle-symbolic");
    }

    fn loadItems(self: *Self, method: []const u8, fields: []const vh.JsonField, roots: []const []const u8, spec: vh.ItemSpec) !std.ArrayList(vh.Item) {
        const json = try vh.callJson(self.allocator(), self.client(), method, fields);
        defer self.allocator().free(json);
        return vh.parseItems(self.allocator(), json, roots, spec) catch std.ArrayList(vh.Item).empty;
    }

    fn appendSection(self: *Self, title: [:0]const u8, items: []const vh.Item, icon: [:0]const u8) !void {
        const alloc = self.allocator();
        self.private().body.append(ui.heading(title).as(gtk.Widget));
        const list = vh.listBox();
        if (items.len == 0) {
            list.append((try ui.row(alloc, icon, "No items", "Nothing to show for this source.")).as(gtk.Widget));
        } else {
            for (items[0..@min(items.len, 6)]) |item| {
                list.append((try vh.itemRow(alloc, item, icon)).as(gtk.Widget));
            }
        }
        self.private().body.append(list.as(gtk.Widget));
    }

    fn appendSyncSummary(self: *Self, repo_json: ?[]const u8, status_json: ?[]const u8, sync_json: ?[]const u8, changes: []const vh.Item) !void {
        const alloc = self.allocator();
        const row = gtk.Box.new(.horizontal, 12);
        const repo_label = if (vh.rawJsonFieldString(alloc, repo_json, &.{ "full_name", "fullName", "name" }) catch null) |repo| repo else try alloc.dupe(u8, "Repository");
        defer alloc.free(repo_label);
        const sync_label = if (sync_json) |sync| try vh.parseStringResult(alloc, sync) else try alloc.dupe(u8, "Sync status unavailable");
        defer alloc.free(sync_label);
        const status_label = if (status_json) |status| try vh.parseStringResult(alloc, status) else try alloc.dupe(u8, "jj status unavailable");
        defer alloc.free(status_label);
        try self.appendTextCard(row, "Repository", repo_label);
        try self.appendTextCard(row, "Sync", sync_label);
        const change_detail = try std.fmt.allocPrint(alloc, "{d} working copy / {d} total", .{ workingCopyCount(changes), changes.len });
        defer alloc.free(change_detail);
        try self.appendTextCard(row, "Changes", change_detail);
        try self.appendTextCard(row, "JJ Status", status_label);
        self.private().body.append(row.as(gtk.Widget));
    }

    fn appendChangesIndicator(self: *Self, changes: []const vh.Item, diff: ?[]const u8) !void {
        const alloc = self.allocator();
        const row = gtk.Box.new(.horizontal, 12);
        try vh.appendMetric(alloc, row, "Working Copy", workingCopyCount(changes), "changes marked WC");
        try vh.appendMetric(alloc, row, "Committed", committedCount(changes), "recent committed changes");
        try vh.appendMetric(alloc, row, "Uncommitted Diff", if (hasContent(diff)) 1 else 0, "working tree indicator");
        self.private().body.append(row.as(gtk.Widget));
    }

    fn appendTextCard(self: *Self, parent: *gtk.Box, title: []const u8, detail: []const u8) !void {
        const alloc = self.allocator();
        const card = gtk.Box.new(.vertical, 4);
        card.as(gtk.Widget).setHexpand(1);
        card.as(gtk.Widget).addCssClass("card");
        ui.margin(card.as(gtk.Widget), 12);
        const title_z = try alloc.dupeZ(u8, title);
        defer alloc.free(title_z);
        const detail_z = try alloc.dupeZ(u8, detail);
        defer alloc.free(detail_z);
        card.append(ui.heading(title_z).as(gtk.Widget));
        const label = ui.dim(detail_z);
        label.setLines(3);
        label.setEllipsize(.end);
        card.append(label.as(gtk.Widget));
        parent.append(card.as(gtk.Widget));
    }

    fn appendRecentCommits(self: *Self, recent_commits: []const vh.Item, changes: []const vh.Item) !void {
        if (recent_commits.len > 0) {
            try self.appendSection("Recent Commits", recent_commits, "emblem-documents-symbolic");
            return;
        }
        const alloc = self.allocator();
        self.private().body.append(ui.heading("Recent Commits").as(gtk.Widget));
        const list = vh.listBox();
        var visible: usize = 0;
        for (changes) |change| {
            if (isWorkingCopy(change)) continue;
            list.append((try vh.itemRow(alloc, change, "emblem-documents-symbolic")).as(gtk.Widget));
            visible += 1;
            if (visible >= 6) break;
        }
        if (visible == 0) {
            list.append((try ui.row(alloc, "emblem-documents-symbolic", "No recent commits", "Committed change summaries appear here.")).as(gtk.Widget));
        }
        self.private().body.append(list.as(gtk.Widget));
    }

    fn countOpen(items: []const vh.Item) usize {
        var count: usize = 0;
        for (items) |item| {
            if (item.status) |status| {
                if (std.ascii.eqlIgnoreCase(status, "open") or std.ascii.eqlIgnoreCase(status, "ready")) count += 1;
            }
        }
        return count;
    }

    fn workingCopyCount(items: []const vh.Item) usize {
        var count: usize = 0;
        for (items) |item| {
            if (isWorkingCopy(item)) count += 1;
        }
        return count;
    }

    fn committedCount(items: []const vh.Item) usize {
        return items.len - workingCopyCount(items);
    }

    fn isWorkingCopy(item: vh.Item) bool {
        if (item.status) |status| {
            return std.ascii.eqlIgnoreCase(status, "true") or
                std.ascii.eqlIgnoreCase(status, "1") or
                std.ascii.eqlIgnoreCase(status, "wc") or
                std.ascii.eqlIgnoreCase(status, "working-copy");
        }
        return false;
    }

    fn hasContent(value: ?[]const u8) bool {
        const text = value orelse return false;
        return std.mem.trim(u8, text, &std.ascii.whitespace).len > 0;
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn changesClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.changes);
    }

    fn landingsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.landings);
    }

    fn issuesClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.issues);
    }

    fn ticketsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.tickets);
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn dispose(self: *Self) callconv(.c) void {
        if (!self.private().did_dispose) {
            self.private().did_dispose = true;
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
