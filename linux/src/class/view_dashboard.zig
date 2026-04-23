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
const logx = @import("../log.zig");
const log = std.log.scoped(.smithers_gtk_view_dashboard);

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
        tab: DashboardTab = .overview,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    const DashboardTab = enum {
        overview,
        runs,
        workflows,
        approvals,
        landings,
        issues,
        workspaces,
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .window = window };
        try self.build();
        return self;
    }

    pub fn refresh(self: *Self) void {
        logx.event(log, "refresh_start", "view=dashboard tab={s}", .{@tagName(self.private().tab)});
        const t = logx.startTimer();
        self.refreshImpl() catch |err| {
            logx.catchWarn(log, "refresh refreshImpl", err);
            vh.setStatus(self.allocator(), self.private().body, "dialog-error-symbolic", "Dashboard unavailable", @errorName(err));
        };
        logx.endTimer(log, "refresh", t);
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

        const tabs = gtk.Box.new(.horizontal, 0);
        tabs.as(gtk.Widget).addCssClass("dash-tabs");
        inline for (.{ .overview, .runs, .workflows, .approvals, .landings, .issues, .workspaces }) |tab| {
            const button = ui.textButton(tabTitle(tab), false);
            button.as(gtk.Widget).addCssClass("dash-tab");
            if (tab == .overview) button.as(gtk.Widget).addCssClass("active");
            button.as(gobject.Object).setData("smithers-dashboard-tab", @ptrFromInt(tabIndex(tab) + 1));
            _ = gtk.Button.signals.clicked.connect(button, *Self, tabClicked, self, .{});
            tabs.append(button.as(gtk.Widget));
        }
        box.append(tabs.as(gtk.Widget));

        const body = gtk.Box.new(.vertical, 20);
        ui.margin4(body.as(gtk.Widget), 24, 32, 24, 32);
        body.as(gtk.Widget).setHexpand(1);
        self.private().body = body;

        const clamp = adw.Clamp.new();
        clamp.setMaximumSize(1100);
        clamp.setTighteningThreshold(900);
        clamp.setChild(body.as(gtk.Widget));

        const scroll = ui.scrolled(clamp.as(gtk.Widget));
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
        var runs = if (runs_json) |json| models.parseRuns(alloc, json) catch |err| blk: {
            logx.catchWarn(log, "refreshImpl parseRuns", err);
            break :blk std.ArrayList(models.RunSummary).empty;
        } else std.ArrayList(models.RunSummary).empty;
        defer {
            models.clearList(models.RunSummary, alloc, &runs);
            runs.deinit(alloc);
        }

        const workflows_json = callOrError(self, "listWorkflows", &.{}, &source_errors);
        defer if (workflows_json) |json| alloc.free(json);
        var workflows = if (workflows_json) |json| models.parseWorkflows(alloc, json) catch |err| blk: {
            logx.catchWarn(log, "refreshImpl parseWorkflows", err);
            break :blk std.ArrayList(models.Workflow).empty;
        } else std.ArrayList(models.Workflow).empty;
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
            const path_label = ui.dim(path_z);
            path_label.setEllipsize(.middle);
            body.append(path_label.as(gtk.Widget));
        }

        if (source_errors > 0) {
            const warning = try std.fmt.allocPrintSentinel(alloc, "{d} data source(s) could not be loaded.", .{source_errors}, 0);
            defer alloc.free(warning);
            body.append(ui.dim(warning).as(gtk.Widget));
        }

        if (self.private().tab != .overview) {
            try self.appendSelectedTab(body, runs.items, workflows.items, approvals.items, landings.items, issues.items, workspaces.items);
            return;
        }

        const primary = gtk.Box.new(.horizontal, 12);
        primary.as(gtk.Widget).setHexpand(1);
        try vh.appendMetricPrimary(alloc, primary, "Active Runs", countActiveRuns(runs.items), "running or waiting");
        try vh.appendMetricPrimary(alloc, primary, "Pending Approvals", approvals.items.len, "gates to review");
        try vh.appendMetricPrimary(alloc, primary, "Failed Runs", countRunStatus(runs.items, "failed"), "needs attention");
        try vh.appendMetricPrimary(alloc, primary, "Open Landings", countStatus(landings.items, "open"), "JJHub requests");
        body.append(primary.as(gtk.Widget));

        const caption = ui.label("AT A GLANCE", "caption");
        ui.margin4(caption.as(gtk.Widget), 8, 0, 2, 0);
        body.append(caption.as(gtk.Widget));

        const secondary = gtk.Box.new(.horizontal, 10);
        secondary.as(gtk.Widget).setHexpand(1);
        try vh.appendMetricSecondary(alloc, secondary, "Workflows", workflows.items.len);
        try vh.appendMetricSecondary(alloc, secondary, "Running", countRunStatus(runs.items, "running"));
        try vh.appendMetricSecondary(alloc, secondary, "Waiting", countRunStatus(runs.items, "waiting-approval"));
        try vh.appendMetricSecondary(alloc, secondary, "Finished", countRunStatus(runs.items, "finished"));
        try vh.appendMetricSecondary(alloc, secondary, "Issues", countStatus(issues.items, "open"));
        try vh.appendMetricSecondary(alloc, secondary, "Workspaces", workspaces.items.len);
        body.append(secondary.as(gtk.Widget));

        const recent_header = ui.label("RECENT RUNS", "caption");
        ui.margin4(recent_header.as(gtk.Widget), 16, 0, 2, 0);
        body.append(recent_header.as(gtk.Widget));
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

        const workflows_header = ui.label("WORKFLOWS", "caption");
        ui.margin4(workflows_header.as(gtk.Widget), 16, 0, 2, 0);
        body.append(workflows_header.as(gtk.Widget));
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

    fn appendSelectedTab(
        self: *Self,
        body: *gtk.Box,
        runs: []const models.RunSummary,
        workflows: []const models.Workflow,
        approvals: []const models.Approval,
        landings: []const vh.Item,
        issues: []const vh.Item,
        workspaces: []const models.Workspace,
    ) !void {
        switch (self.private().tab) {
            .overview => {},
            .runs => try self.appendRunsTab(body, runs),
            .workflows => try self.appendWorkflowsTab(body, workflows),
            .approvals => try self.appendApprovalsTab(body, approvals),
            .landings => try self.appendItemsTab(body, "Landings", landings, "arrow-up-symbolic", "No landings found"),
            .issues => try self.appendItemsTab(body, "Issues", issues, "dialog-question-symbolic", "No issues found"),
            .workspaces => try self.appendWorkspacesTab(body, workspaces),
        }
    }

    fn appendRunsTab(self: *Self, body: *gtk.Box, runs: []const models.RunSummary) !void {
        const alloc = self.allocator();
        body.append(ui.heading("Runs").as(gtk.Widget));
        const list = vh.listBox();
        if (runs.len == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No runs found", "Launch a workflow to see execution state here.")).as(gtk.Widget));
        } else {
            for (runs[0..@min(runs.len, 50)], 0..) |run, index| {
                const title = run.workflow_name orelse run.run_id;
                const subtitle = try std.fmt.allocPrint(alloc, "{s} - {s} - {d}/{d} nodes", .{ run.run_id, run.status, run.finished + run.failed, run.total });
                defer alloc.free(subtitle);
                const row = try ui.row(alloc, runIcon(run.status), title, subtitle);
                vh.setIndex(row.as(gobject.Object), index);
                list.append(row.as(gtk.Widget));
            }
            _ = gtk.ListBox.signals.row_activated.connect(list, *Self, runActivated, self, .{});
        }
        body.append(list.as(gtk.Widget));
    }

    fn appendWorkflowsTab(self: *Self, body: *gtk.Box, workflows: []const models.Workflow) !void {
        const alloc = self.allocator();
        body.append(ui.heading("Workflows").as(gtk.Widget));
        const list = vh.listBox();
        if (workflows.len == 0) {
            list.append((try ui.row(alloc, "emblem-documents-symbolic", "No workflows found", ".smithers/workflows entries appear here.")).as(gtk.Widget));
        } else {
            for (workflows[0..@min(workflows.len, 50)]) |workflow| {
                const path = workflow.relative_path orelse workflow.id;
                const subtitle = try std.fmt.allocPrint(alloc, "{s} - {s}", .{ path, workflow.status });
                defer alloc.free(subtitle);
                list.append((try ui.row(alloc, "media-playlist-shuffle-symbolic", workflow.name, subtitle)).as(gtk.Widget));
            }
        }
        body.append(list.as(gtk.Widget));
    }

    fn appendApprovalsTab(self: *Self, body: *gtk.Box, approvals: []const models.Approval) !void {
        const alloc = self.allocator();
        body.append(ui.heading("Approvals").as(gtk.Widget));
        const list = vh.listBox();
        var visible: usize = 0;
        for (approvals[0..@min(approvals.len, 50)]) |approval| {
            const title = approval.gate orelse approval.node_id;
            const subtitle = try std.fmt.allocPrint(alloc, "Run {s} - {s}", .{ approval.run_id, approval.status });
            defer alloc.free(subtitle);
            list.append((try ui.row(alloc, "security-high-symbolic", title, subtitle)).as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            list.append((try ui.row(alloc, "emblem-ok-symbolic", "No pending approvals", "Waiting gates appear here.")).as(gtk.Widget));
        }
        body.append(list.as(gtk.Widget));
    }

    fn appendItemsTab(self: *Self, body: *gtk.Box, title: [:0]const u8, items: []const vh.Item, icon: [:0]const u8, empty: []const u8) !void {
        const alloc = self.allocator();
        body.append(ui.heading(title).as(gtk.Widget));
        const list = vh.listBox();
        if (items.len == 0) {
            list.append((try ui.row(alloc, icon, empty, "No items returned.")).as(gtk.Widget));
        } else {
            for (items[0..@min(items.len, 50)]) |item| {
                list.append((try vh.itemRow(alloc, item, icon)).as(gtk.Widget));
            }
        }
        body.append(list.as(gtk.Widget));
    }

    fn appendWorkspacesTab(self: *Self, body: *gtk.Box, workspaces: []const models.Workspace) !void {
        const alloc = self.allocator();
        body.append(ui.heading("Workspaces").as(gtk.Widget));
        const list = vh.listBox();
        if (workspaces.len == 0) {
            list.append((try ui.row(alloc, "computer-symbolic", "No workspaces found", "Cloud workspaces appear here.")).as(gtk.Widget));
        } else {
            for (workspaces[0..@min(workspaces.len, 50)]) |workspace| {
                list.append((try ui.row(alloc, "computer-symbolic", workspace.name, workspace.status orelse workspace.id)).as(gtk.Widget));
            }
        }
        body.append(list.as(gtk.Widget));
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

    fn tabClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-dashboard-tab") orelse return;
        self.private().tab = tabFromIndex(@intFromPtr(raw) - 1);
        if (button.as(gtk.Widget).getParent()) |parent_widget| {
            var child = parent_widget.getFirstChild();
            while (child) |w| : (child = w.getNextSibling()) {
                w.removeCssClass("active");
            }
        }
        button.as(gtk.Widget).addCssClass("active");
        self.refresh();
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn runActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        _ = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().window.showNav(.runs);
    }

    fn tabTitle(tab: DashboardTab) [:0]const u8 {
        return switch (tab) {
            .overview => "Overview",
            .runs => "Runs",
            .workflows => "Workflows",
            .approvals => "Approvals",
            .landings => "Landings",
            .issues => "Issues",
            .workspaces => "Workspaces",
        };
    }

    fn tabIndex(tab: DashboardTab) usize {
        return switch (tab) {
            .overview => 0,
            .runs => 1,
            .workflows => 2,
            .approvals => 3,
            .landings => 4,
            .issues => 5,
            .workspaces => 6,
        };
    }

    fn tabFromIndex(index: usize) DashboardTab {
        return switch (index) {
            1 => .runs,
            2 => .workflows,
            3 => .approvals,
            4 => .landings,
            5 => .issues,
            6 => .workspaces,
            else => .overview,
        };
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
