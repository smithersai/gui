const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const models = @import("../models.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const RunsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersRunsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        search_entry: *gtk.Entry = undefined,
        status_filter: ?[]const u8 = null,
        runs: std.ArrayList(models.RunSummary) = .empty,
        inspection: ?models.RunInspection = null,
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
        self.loadRuns() catch |err| {
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Runs unavailable", @errorName(err));
        };
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
        root.setSpacing(0);

        const header = vh.makeHeader("Runs", null);
        self.private().search_entry = gtk.Entry.new();
        self.private().search_entry.setPlaceholderText("Search runs");
        self.private().search_entry.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().search_entry, *Self, searchActivated, self, .{});
        header.append(self.private().search_entry.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh runs");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const filters = gtk.Box.new(.horizontal, 8);
        ui.margin4(filters.as(gtk.Widget), 8, 16, 8, 16);
        inline for (.{ "All", "running", "waiting-approval", "finished", "failed" }) |label| {
            const button = ui.textButton(label, false);
            button.as(gtk.Widget).setTooltipText(label);
            _ = gtk.Button.signals.clicked.connect(button, *Self, statusFilterClicked, self, .{});
            button.as(gobject.Object).setData("smithers-status-filter", @constCast(label.ptr));
            filters.append(button.as(gtk.Widget));
        }
        root.append(filters.as(gtk.Widget));

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

        vh.setStatus(self.allocator(), self.private().detail, "view-list-symbolic", "Select a run", "Run tasks and actions appear here.");
    }

    fn loadRuns(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.client(), "listRuns", "{}");
        defer alloc.free(json);
        const parsed = try models.parseRuns(alloc, json);
        models.clearList(models.RunSummary, alloc, &self.private().runs);
        self.private().runs = parsed;
        self.private().selected_index = null;
        self.clearInspection();
        try self.renderList();
        vh.setStatus(alloc, self.private().detail, "view-list-symbolic", "Select a run", "Run tasks and actions appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        const list = self.private().list;
        ui.clearList(list);
        var visible: usize = 0;
        for (self.private().runs.items, 0..) |run, index| {
            if (!self.matchesFilters(run)) continue;
            const title = run.workflow_name orelse run.run_id;
            const detail = try std.fmt.allocPrint(alloc, "{s} - {s} - {d}/{d} nodes", .{
                run.run_id,
                run.status,
                run.finished + run.failed,
                run.total,
            });
            defer alloc.free(detail);
            const row = try ui.row(alloc, runIcon(run.status), title, detail);
            vh.setIndex(row.as(gobject.Object), index);
            list.append(row.as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No runs found", "Adjust filters or launch a workflow.")).as(gtk.Widget));
        }
    }

    fn matchesFilters(self: *Self, run: models.RunSummary) bool {
        if (self.private().status_filter) |status| {
            if (!std.ascii.eqlIgnoreCase(run.status, status)) return false;
        }
        const search = std.mem.trim(u8, std.mem.span(self.private().search_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (search.len == 0) return true;
        return containsIgnoreCase(run.run_id, search) or
            (run.workflow_name != null and containsIgnoreCase(run.workflow_name.?, search)) or
            (run.workflow_path != null and containsIgnoreCase(run.workflow_path.?, search));
    }

    fn selectRun(self: *Self, index: usize) void {
        if (index >= self.private().runs.items.len) return;
        self.private().selected_index = index;
        self.loadInspection(index) catch |err| {
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Run inspection failed", @errorName(err));
        };
    }

    fn loadInspection(self: *Self, index: usize) !void {
        const run = self.private().runs.items[index];
        const alloc = self.allocator();
        const args = try vh.jsonObject(alloc, &.{.{ .key = "runId", .value = .{ .string = run.run_id } }});
        defer alloc.free(args);
        const json = try smithers.callJson(alloc, self.client(), "inspectRun", args);
        defer alloc.free(json);

        self.clearInspection();
        self.private().inspection = try models.parseRunInspection(alloc, json);
        try self.renderDetail();
    }

    fn renderDetail(self: *Self) !void {
        const alloc = self.allocator();
        const detail = self.private().detail;
        ui.clearBox(detail);
        if (self.private().inspection == null) return;
        const inspection = &self.private().inspection.?;
        const title = inspection.run.workflow_name orelse inspection.run.run_id;
        const title_z = try alloc.dupeZ(u8, title);
        defer alloc.free(title_z);
        detail.append(ui.heading(title_z).as(gtk.Widget));
        const summary = try std.fmt.allocPrint(alloc, "{s} - {s} - {d}/{d} nodes", .{
            inspection.run.run_id,
            inspection.run.status,
            inspection.run.finished + inspection.run.failed,
            inspection.run.total,
        });
        defer alloc.free(summary);
        const summary_z = try alloc.dupeZ(u8, summary);
        defer alloc.free(summary_z);
        detail.append(ui.dim(summary_z).as(gtk.Widget));

        const actions = gtk.Box.new(.horizontal, 8);
        const inspect = ui.textButton("Open Inspector", true);
        _ = gtk.Button.signals.clicked.connect(inspect, *Self, openInspectorClicked, self, .{});
        actions.append(inspect.as(gtk.Widget));
        const cancel = ui.textButton("Cancel", false);
        cancel.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(cancel, *Self, cancelClicked, self, .{});
        actions.append(cancel.as(gtk.Widget));
        if (blockedTask(inspection.*)) |_| {
            const approve = ui.textButton("Approve", true);
            _ = gtk.Button.signals.clicked.connect(approve, *Self, approveClicked, self, .{});
            actions.append(approve.as(gtk.Widget));
            const deny = ui.textButton("Deny", false);
            deny.as(gtk.Widget).addCssClass("destructive-action");
            _ = gtk.Button.signals.clicked.connect(deny, *Self, denyClicked, self, .{});
            actions.append(deny.as(gtk.Widget));
        }
        detail.append(actions.as(gtk.Widget));

        const list = vh.listBox();
        if (inspection.tasks.items.len == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No task details", "The run inspector returned no task records.")).as(gtk.Widget));
        } else {
            for (inspection.tasks.items) |task| {
                const label = task.label orelse task.node_id;
                const subtitle = if (task.iteration) |iteration|
                    try std.fmt.allocPrint(alloc, "{s} - iteration {d}", .{ task.state, iteration })
                else
                    try alloc.dupe(u8, task.state);
                defer alloc.free(subtitle);
                list.append((try ui.row(alloc, taskIcon(task.state), label, subtitle)).as(gtk.Widget));
            }
        }
        detail.append(list.as(gtk.Widget));
    }

    fn completeApproval(self: *Self, method: []const u8, toast_prefix: []const u8) void {
        const inspection = self.private().inspection orelse return;
        const task = blockedTask(inspection) orelse return;
        const alloc = self.allocator();
        const args = vh.jsonObject(alloc, &.{
            .{ .key = "runId", .value = .{ .string = inspection.run.run_id } },
            .{ .key = "nodeId", .value = .{ .string = task.node_id } },
            .{ .key = "iteration", .value = if (task.iteration) |iteration| .{ .integer = iteration } else .null },
        }) catch return;
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), method, args) catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ toast_prefix, err });
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("{s} {s}", .{ toast_prefix, task.node_id });
        if (self.private().selected_index) |index| self.loadInspection(index) catch {};
    }

    fn cancelSelectedRun(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().runs.items.len) return;
        const run = self.private().runs.items[index];
        const alloc = self.allocator();
        const args = vh.jsonObject(alloc, &.{.{ .key = "runId", .value = .{ .string = run.run_id } }}) catch return;
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), "cancelRun", args) catch |err| {
            self.private().window.showToastFmt("Cancel failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Cancelled {s}", .{run.run_id});
        self.refresh();
    }

    fn clearInspection(self: *Self) void {
        if (self.private().inspection) |*inspection| {
            inspection.deinit(self.allocator());
            self.private().inspection = null;
        }
    }

    fn blockedTask(inspection: models.RunInspection) ?models.RunTask {
        for (inspection.tasks.items) |task| {
            if (std.ascii.eqlIgnoreCase(task.state, "blocked") or
                std.ascii.eqlIgnoreCase(task.state, "waiting") or
                std.ascii.eqlIgnoreCase(task.state, "waiting-approval"))
            {
                return task;
            }
        }
        return null;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn runIcon(status: []const u8) [:0]const u8 {
        if (std.ascii.eqlIgnoreCase(status, "running")) return "media-playback-start-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "waiting-approval") or std.ascii.eqlIgnoreCase(status, "blocked")) return "security-high-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "finished")) return "emblem-ok-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "failed")) return "dialog-error-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "cancelled")) return "process-stop-symbolic";
        return "view-list-symbolic";
    }

    fn taskIcon(status: []const u8) [:0]const u8 {
        if (std.ascii.eqlIgnoreCase(status, "running")) return "media-playback-start-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "finished")) return "emblem-ok-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "failed")) return "dialog-error-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "blocked") or std.ascii.eqlIgnoreCase(status, "waiting-approval")) return "security-high-symbolic";
        return "view-list-symbolic";
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.renderList() catch {};
    }

    fn statusFilterClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-status-filter") orelse return;
        const label: [*:0]const u8 = @ptrCast(raw);
        const text = std.mem.span(label);
        self.private().status_filter = if (std.mem.eql(u8, text, "All")) null else text;
        self.renderList() catch {};
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.selectRun(index);
    }

    fn openInspectorClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const inspection = self.private().inspection orelse return;
        self.private().window.inspectRun(inspection.run.run_id);
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.cancelSelectedRun();
    }

    fn approveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.completeApproval("approveNode", "Approved");
    }

    fn denyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.completeApproval("denyNode", "Denied");
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.clearInspection();
            models.clearList(models.RunSummary, self.allocator(), &priv.runs);
            priv.runs.deinit(self.allocator());
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
