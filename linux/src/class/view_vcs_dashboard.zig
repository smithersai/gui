const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

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
        const header = vh.makeHeader("VCS Dashboard", null);
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

        const body = self.private().body;
        ui.clearBox(body);
        const metrics = gtk.Box.new(.horizontal, 12);
        try vh.appendMetric(alloc, metrics, "Changes", changes.items.len, "recent JJHub changes");
        try vh.appendMetric(alloc, metrics, "Landings", countOpen(landings.items), "open or ready");
        try vh.appendMetric(alloc, metrics, "Issues", issues.items.len, "open issues");
        try vh.appendMetric(alloc, metrics, "Tickets", tickets.items.len, "local Smithers tickets");
        body.append(metrics.as(gtk.Widget));

        try self.appendSection("Recent Changes", changes.items, "view-list-symbolic");
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

    fn countOpen(items: []const vh.Item) usize {
        var count: usize = 0;
        for (items) |item| {
            if (item.status) |status| {
                if (std.ascii.eqlIgnoreCase(status, "open") or std.ascii.eqlIgnoreCase(status, "ready")) count += 1;
            }
        }
        return count;
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
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
