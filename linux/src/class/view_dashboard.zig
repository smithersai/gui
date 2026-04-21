const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const models = @import("../models.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const DashboardView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersDashboardView",
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
        self.refreshImpl() catch |err| {
            vh.setStatus(self.allocator(), self.private().body, "dialog-error-symbolic", "Dashboard unavailable", @errorName(err));
        };
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.private().window.allocator();
    }

    fn client(self: *Self) smithers.c.smithers_client_t {
        return self.private().window.app().client();
    }

    fn build(self: *Self) !void {
        const box = self.as(gtk.Box);
        box.as(gtk.Orientable).setOrientation(.vertical);
        box.setSpacing(0);
        vh.installShortcut(Self, box.as(gtk.Widget), "<Control>r", self, shortcutRefresh);

        const header = vh.makeHeader("Dashboard", null);
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh dashboard");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        box.append(header.as(gtk.Widget));

        const body = gtk.Box.new(.vertical, 16);
        ui.margin(body.as(gtk.Widget), 20);
        self.private().body = body;
        const scroll = ui.scrolled(body.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        box.append(scroll.as(gtk.Widget));

        vh.setStatus(self.allocator(), body, "view-grid-symbolic", "Open a workspace", "Dashboard data appears after Smithers has a workspace.");
    }

    fn refreshImpl(self: *Self) !void {
        const alloc = self.allocator();
        const body = self.private().body;
        vh.setStatus(alloc, body, "content-loading-symbolic", "Loading dashboard", "Fetching Smithers and JJHub activity.");

        var source_errors: usize = 0;

        const runs_json = callOrError(self, "listRuns", &.{}, &source_errors);
        defer if (runs_json) |json| alloc.free(json);
        var runs = if (runs_json) |json| models.parseRuns(alloc, json) catch std.ArrayList(models.RunSummary).empty else std.ArrayList(models.RunSummary).empty;
        defer {
            models.clearList(models.RunSummary, alloc, &runs);
            runs.deinit(alloc);
        }

        const workflows_json = callOrError(self, "listWorkflows", &.{}, &source_errors);
        defer if (workflows_json) |json| alloc.free(json);
        var workflows = if (workflows_json) |json| models.parseWorkflows(alloc, json) catch std.ArrayList(models.Workflow).empty else std.ArrayList(models.Workflow).empty;
        defer {
            models.clearList(models.Workflow, alloc, &workflows);
            workflows.deinit(alloc);
        }

        const approvals_json = callOrError(self, "listPendingApprovals", &.{}, &source_errors);
        defer if (approvals_json) |json| alloc.free(json);
        var approvals = if (approvals_json) |json| models.parseApprovals(alloc, json) catch std.ArrayList(models.Approval).empty else std.ArrayList(models.Approval).empty;
        defer {
            models.clearList(models.Approval, alloc, &approvals);
            approvals.deinit(alloc);
        }

        const landings = try self.loadGenericCount("listLandings", &.{ "landings", "items", "data" }, .{
            .id = &.{ "id", "number", "title" },
            .title = &.{"title"},
            .status = &.{ "state", "status" },
            .number = &.{"number"},
        }, &source_errors);
        defer {
            var mutable = landings;
            vh.clearItems(alloc, &mutable);
            mutable.deinit(alloc);
        }

        const issues = try self.loadGenericCount("listIssues", &.{ "issues", "items", "results", "data" }, .{
            .id = &.{ "id", "number", "title" },
            .title = &.{"title"},
            .status = &.{ "state", "status" },
            .number = &.{"number"},
        }, &source_errors);
        defer {
            var mutable = issues;
            vh.clearItems(alloc, &mutable);
            mutable.deinit(alloc);
        }

        const workspaces_json = callOrError(self, "listWorkspaces", &.{}, &source_errors);
        defer if (workspaces_json) |json| alloc.free(json);
        var workspaces = if (workspaces_json) |json| models.parseWorkspaces(alloc, json) catch std.ArrayList(models.Workspace).empty else std.ArrayList(models.Workspace).empty;
        defer {
            models.clearList(models.Workspace, alloc, &workspaces);
            workspaces.deinit(alloc);
        }

        ui.clearBox(body);
        if (self.private().window.activeWorkspace()) |path| {
            const path_z = try alloc.dupeZ(u8, path);
            defer alloc.free(path_z);
            body.append(ui.dim(path_z).as(gtk.Widget));
        }

        if (source_errors > 0) {
            const warning = try std.fmt.allocPrintSentinel(alloc, "{d} data source(s) could not be loaded.", .{source_errors}, 0);
            defer alloc.free(warning);
            body.append(ui.dim(warning).as(gtk.Widget));
        }

        const quick = gtk.Box.new(.horizontal, 8);
        const workflows_button = ui.textButton("Workflows", true);
        _ = gtk.Button.signals.clicked.connect(workflows_button, *Self, workflowsClicked, self, .{});
        quick.append(workflows_button.as(gtk.Widget));
        const runs_button = ui.textButton("Runs", false);
        _ = gtk.Button.signals.clicked.connect(runs_button, *Self, runsClicked, self, .{});
        quick.append(runs_button.as(gtk.Widget));
        const approvals_button = ui.textButton("Approvals", false);
        _ = gtk.Button.signals.clicked.connect(approvals_button, *Self, approvalsClicked, self, .{});
        quick.append(approvals_button.as(gtk.Widget));
        const triggers_button = ui.textButton("Triggers", false);
        _ = gtk.Button.signals.clicked.connect(triggers_button, *Self, triggersClicked, self, .{});
        quick.append(triggers_button.as(gtk.Widget));
        body.append(quick.as(gtk.Widget));

        const metrics = gtk.Box.new(.horizontal, 12);
        metrics.as(gtk.Widget).setHexpand(1);
        try vh.appendMetric(alloc, metrics, "Active Runs", countActiveRuns(runs.items), "running or waiting");
        try vh.appendMetric(alloc, metrics, "Workflows", workflows.items.len, "local definitions");
        try vh.appendMetric(alloc, metrics, "Approvals", approvals.items.len, "pending gates");
        try vh.appendMetric(alloc, metrics, "Landings", countStatus(landings.items, "open"), "open JJHub requests");
        body.append(metrics.as(gtk.Widget));

        const second = gtk.Box.new(.horizontal, 12);
        second.as(gtk.Widget).setHexpand(1);
        try vh.appendMetric(alloc, second, "Issues", countStatus(issues.items, "open"), "open JJHub issues");
        try vh.appendMetric(alloc, second, "Workspaces", workspaces.items.len, "known workspaces");
        try vh.appendMetric(alloc, second, "Recent Runs", runs.items.len, "execution history");
        body.append(second.as(gtk.Widget));

        const run_status = gtk.Box.new(.horizontal, 12);
        run_status.as(gtk.Widget).setHexpand(1);
        try vh.appendMetric(alloc, run_status, "Running", countRunStatus(runs.items, "running"), "active agents");
        try vh.appendMetric(alloc, run_status, "Waiting", countRunStatus(runs.items, "waiting-approval"), "approval blocked");
        try vh.appendMetric(alloc, run_status, "Finished", countRunStatus(runs.items, "finished"), "completed");
        try vh.appendMetric(alloc, run_status, "Failed", countRunStatus(runs.items, "failed"), "needs attention");
        body.append(run_status.as(gtk.Widget));

        body.append(ui.heading("Recent Runs").as(gtk.Widget));
        const run_list = vh.listBox();
        if (runs.items.len == 0) {
            run_list.append((try ui.row(alloc, "view-list-symbolic", "No recent runs", "Launch a workflow to see execution state here.")).as(gtk.Widget));
        } else {
            for (runs.items[0..@min(runs.items.len, 6)], 0..) |run, index| {
                const title = run.workflow_name orelse run.run_id;
                const subtitle = try std.fmt.allocPrint(alloc, "{s} - {s}", .{ run.run_id, run.status });
                defer alloc.free(subtitle);
                const row = try ui.row(alloc, runIcon(run.status), title, subtitle);
                vh.setIndex(row.as(gobject.Object), index);
                run_list.append(row.as(gtk.Widget));
            }
        }
        _ = gtk.ListBox.signals.row_activated.connect(run_list, *Self, runActivated, self, .{});
        body.append(run_list.as(gtk.Widget));

        body.append(ui.heading("Workflows").as(gtk.Widget));
        const workflow_list = vh.listBox();
        if (workflows.items.len == 0) {
            workflow_list.append((try ui.row(alloc, "emblem-documents-symbolic", "No workflows found", ".smithers/workflows entries appear here.")).as(gtk.Widget));
        } else {
            for (workflows.items[0..@min(workflows.items.len, 6)]) |workflow| {
                const path = workflow.relative_path orelse workflow.id;
                workflow_list.append((try ui.row(alloc, "media-playlist-shuffle-symbolic", workflow.name, path)).as(gtk.Widget));
            }
        }
        body.append(workflow_list.as(gtk.Widget));
    }

    fn callOrError(self: *Self, method: []const u8, fields: []const vh.JsonField, errors: *usize) ?[]u8 {
        return vh.callJson(self.allocator(), self.client(), method, fields) catch {
            errors.* += 1;
            return null;
        };
    }

    fn loadGenericCount(
        self: *Self,
        method: []const u8,
        root_keys: []const []const u8,
        spec: vh.ItemSpec,
        errors: *usize,
    ) !std.ArrayList(vh.Item) {
        const json = callOrError(self, method, &.{}, errors) orelse return .empty;
        defer self.allocator().free(json);
        return vh.parseItems(self.allocator(), json, root_keys, spec) catch std.ArrayList(vh.Item).empty;
    }

    fn countActiveRuns(runs: []const models.RunSummary) usize {
        var count: usize = 0;
        for (runs) |run| {
            if (std.ascii.eqlIgnoreCase(run.status, "running") or
                std.ascii.eqlIgnoreCase(run.status, "waiting-approval") or
                std.ascii.eqlIgnoreCase(run.status, "blocked")) count += 1;
        }
        return count;
    }

    fn countStatus(items: []const vh.Item, status: []const u8) usize {
        var count: usize = 0;
        for (items) |item| {
            if (item.status) |value| {
                if (std.ascii.eqlIgnoreCase(value, status) or
                    (std.ascii.eqlIgnoreCase(status, "open") and std.ascii.eqlIgnoreCase(value, "ready"))) count += 1;
            }
        }
        return count;
    }

    fn countRunStatus(runs: []const models.RunSummary, status: []const u8) usize {
        var count: usize = 0;
        for (runs) |run| {
            if (std.ascii.eqlIgnoreCase(run.status, status) or
                (std.ascii.eqlIgnoreCase(status, "waiting-approval") and std.ascii.eqlIgnoreCase(run.status, "blocked"))) count += 1;
        }
        return count;
    }

    fn runIcon(status: []const u8) [:0]const u8 {
        if (std.ascii.eqlIgnoreCase(status, "running")) return "media-playback-start-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "waiting-approval") or std.ascii.eqlIgnoreCase(status, "blocked")) return "security-high-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "finished")) return "emblem-ok-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "failed")) return "dialog-error-symbolic";
        return "view-list-symbolic";
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn workflowsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.workflows);
    }

    fn runsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.runs);
    }

    fn approvalsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.approvals);
    }

    fn triggersClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.triggers);
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn runActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        _ = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().window.showNav(.runs);
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
