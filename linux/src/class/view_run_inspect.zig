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

pub const RunInspectView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersRunInspectView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        body: *gtk.Box = undefined,
        deny_note: *gtk.TextView = undefined,
        run_id: ?[]u8 = null,
        inspection: ?models.RunInspection = null,
        mode: InspectMode = .list,
        selected_task_index: usize = 0,
        pending_deny: ?PendingDeny = null,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    const InspectMode = enum {
        list,
        dag,
    };

    const PendingDeny = struct {
        run_id: []u8,
        node_id: []u8,
        iteration: ?i64 = null,

        fn deinit(self: *PendingDeny, alloc: std.mem.Allocator) void {
            alloc.free(self.run_id);
            alloc.free(self.node_id);
        }
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .window = window };
        try self.build();
        return self;
    }

    pub fn setRun(self: *Self, run_id: []const u8) void {
        const alloc = self.allocator();
        if (self.private().run_id) |old| alloc.free(old);
        self.private().run_id = alloc.dupe(u8, run_id) catch null;
        self.refresh();
    }

    pub fn refresh(self: *Self) void {
        self.refreshImpl() catch |err| {
            vh.setStatus(self.allocator(), self.private().body, "dialog-error-symbolic", "Run inspection failed", @errorName(err));
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
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>r", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Alt>1", self, shortcutListMode);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Alt>2", self, shortcutDagMode);

        const header = vh.makeHeader("Run Inspector", null);
        const back = ui.iconButton("go-previous-symbolic", "Back to runs");
        _ = gtk.Button.signals.clicked.connect(back, *Self, backClicked, self, .{});
        header.append(back.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh inspection");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const body = gtk.Box.new(.vertical, 12);
        ui.margin(body.as(gtk.Widget), 20);
        self.private().body = body;
        const scroll = ui.scrolled(body.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));
        vh.setStatus(self.allocator(), body, "view-list-symbolic", "No run selected", "Open a run from the Runs view.");
    }

    fn refreshImpl(self: *Self) !void {
        const run_id = self.private().run_id orelse {
            vh.setStatus(self.allocator(), self.private().body, "view-list-symbolic", "No run selected", "Open a run from the Runs view.");
            return;
        };
        const alloc = self.allocator();
        vh.setStatus(alloc, self.private().body, "content-loading-symbolic", "Loading run", run_id);

        const args = try vh.jsonObject(alloc, &.{.{ .key = "runId", .value = .{ .string = run_id } }});
        defer alloc.free(args);
        const json = try smithers.callJson(alloc, self.client(), "inspectRun", args);
        defer alloc.free(json);
        self.clearInspection();
        self.private().inspection = try models.parseRunInspection(alloc, json);
        self.clampSelection();
        try self.render();
    }

    fn render(self: *Self) !void {
        const alloc = self.allocator();
        const body = self.private().body;
        ui.clearBox(body);
        if (self.private().inspection == null) return;
        const inspection = &self.private().inspection.?;

        const title = inspection.run.workflow_name orelse inspection.run.run_id;
        const title_z = try alloc.dupeZ(u8, title);
        defer alloc.free(title_z);
        body.append(ui.heading(title_z).as(gtk.Widget));
        const meta = try std.fmt.allocPrint(alloc, "{s} - {s} - {d}/{d} nodes", .{
            inspection.run.run_id,
            inspection.run.status,
            inspection.run.finished + inspection.run.failed,
            inspection.run.total,
        });
        defer alloc.free(meta);
        const meta_z = try alloc.dupeZ(u8, meta);
        defer alloc.free(meta_z);
        body.append(ui.dim(meta_z).as(gtk.Widget));

        const actions = gtk.Box.new(.horizontal, 8);
        const live = ui.textButton("Live Chat", false);
        live.as(gtk.Widget).setTooltipText("Open live run output");
        _ = gtk.Button.signals.clicked.connect(live, *Self, liveChatClicked, self, .{});
        actions.append(live.as(gtk.Widget));
        const snapshots = ui.textButton("Snapshots", false);
        _ = gtk.Button.signals.clicked.connect(snapshots, *Self, snapshotsClicked, self, .{});
        actions.append(snapshots.as(gtk.Widget));
        const watch = ui.textButton("Watch", false);
        _ = gtk.Button.signals.clicked.connect(watch, *Self, watchClicked, self, .{});
        actions.append(watch.as(gtk.Widget));
        const cancel = ui.textButton("Cancel", false);
        cancel.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(cancel, *Self, cancelClicked, self, .{});
        actions.append(cancel.as(gtk.Widget));
        const rerun = ui.textButton("Rerun", false);
        _ = gtk.Button.signals.clicked.connect(rerun, *Self, rerunClicked, self, .{});
        actions.append(rerun.as(gtk.Widget));
        const fork = ui.textButton("Fork Latest", false);
        _ = gtk.Button.signals.clicked.connect(fork, *Self, forkClicked, self, .{});
        actions.append(fork.as(gtk.Widget));
        const replay = ui.textButton("Replay Latest", false);
        _ = gtk.Button.signals.clicked.connect(replay, *Self, replayClicked, self, .{});
        actions.append(replay.as(gtk.Widget));
        const hijack = ui.textButton("Hijack", false);
        _ = gtk.Button.signals.clicked.connect(hijack, *Self, hijackClicked, self, .{});
        actions.append(hijack.as(gtk.Widget));
        if (blockedTask(inspection.*)) |blocked| {
            const approve = ui.textButton("Approve", true);
            _ = gtk.Button.signals.clicked.connect(approve, *Self, approveClicked, self, .{});
            actions.append(approve.as(gtk.Widget));
            const deny = ui.textButton("Deny", false);
            deny.as(gtk.Widget).addCssClass("destructive-action");
            _ = gtk.Button.signals.clicked.connect(deny, *Self, denyClicked, self, .{});
            actions.append(deny.as(gtk.Widget));
            const banner = gtk.Box.new(.vertical, 4);
            banner.as(gtk.Widget).addCssClass("card");
            ui.margin(banner.as(gtk.Widget), 12);
            banner.append(ui.heading("Approval Required").as(gtk.Widget));
            try vh.detailRow(alloc, banner, "Node", blocked.label orelse blocked.node_id);
            try vh.detailRow(alloc, banner, "State", blocked.state);
            body.append(banner.as(gtk.Widget));
        }
        const list_mode = ui.textButton("List", self.private().mode == .list);
        _ = gtk.Button.signals.clicked.connect(list_mode, *Self, listModeClicked, self, .{});
        actions.append(list_mode.as(gtk.Widget));
        const dag_mode = ui.textButton("DAG", self.private().mode == .dag);
        _ = gtk.Button.signals.clicked.connect(dag_mode, *Self, dagModeClicked, self, .{});
        actions.append(dag_mode.as(gtk.Widget));
        body.append(actions.as(gtk.Widget));

        const group = gtk.Box.new(.vertical, 4);
        group.as(gtk.Widget).addCssClass("card");
        ui.margin(group.as(gtk.Widget), 12);
        try vh.detailRow(alloc, group, "Run ID", inspection.run.run_id);
        try vh.detailRow(alloc, group, "Workflow", inspection.run.workflow_path orelse inspection.run.workflow_name);
        try vh.detailRow(alloc, group, "Status", inspection.run.status);
        if (inspection.run.error_json) |err| try vh.detailRow(alloc, group, "Error", err);
        body.append(group.as(gtk.Widget));

        if (currentTask(inspection.*)) |task| {
            const current = gtk.Box.new(.vertical, 4);
            current.as(gtk.Widget).addCssClass("card");
            ui.margin(current.as(gtk.Widget), 12);
            current.append(ui.heading("Current Node").as(gtk.Widget));
            try vh.detailRow(alloc, current, "Node", task.label orelse task.node_id);
            try vh.detailRow(alloc, current, "State", task.state);
            body.append(current.as(gtk.Widget));
        }

        if (inspection.tasks.items.len == 0) {
            const page = try vh.statusPage(alloc, "view-list-symbolic", "No nodes found", "The run inspector returned no nodes.");
            body.append(page.as(gtk.Widget));
            return;
        }

        if (self.private().mode == .list) {
            try self.appendListMode(inspection);
        } else {
            try self.appendDagMode(inspection);
        }
    }

    fn appendListMode(self: *Self, inspection: *models.RunInspection) !void {
        const alloc = self.allocator();
        const body = self.private().body;
        body.append(ui.heading("Nodes").as(gtk.Widget));
        const list = vh.listBox();
        _ = gtk.ListBox.signals.row_activated.connect(list, *Self, taskRowActivated, self, .{});
        for (inspection.tasks.items, 0..) |task, index| {
            const title_task = task.label orelse task.node_id;
            const subtitle = if (task.iteration) |iteration|
                try std.fmt.allocPrint(alloc, "{s} - iteration {d}", .{ task.state, iteration })
            else
                try alloc.dupe(u8, task.state);
            defer alloc.free(subtitle);
            const row = try ui.row(alloc, taskIcon(task.state), title_task, subtitle);
            vh.setIndex(row.as(gobject.Object), index);
            list.append(row.as(gtk.Widget));
        }
        body.append(list.as(gtk.Widget));
    }

    fn appendDagMode(self: *Self, inspection: *models.RunInspection) !void {
        const alloc = self.allocator();
        const body = self.private().body;
        body.append(ui.heading("DAG").as(gtk.Widget));
        const root_title = inspection.run.workflow_name orelse inspection.run.run_id;
        const root_row = try ui.row(alloc, "pointing-hand-symbolic", root_title, "Run root");
        root_row.setActivatable(0);
        body.append(root_row.as(gtk.Widget));
        const list = vh.listBox();
        _ = gtk.ListBox.signals.row_activated.connect(list, *Self, taskRowActivated, self, .{});
        for (inspection.tasks.items, 0..) |task, index| {
            const title_task = task.label orelse task.node_id;
            const prefix: []const u8 = if (index + 1 == inspection.tasks.items.len) "`-" else "|-";
            const subtitle = if (task.iteration) |iteration|
                try std.fmt.allocPrint(alloc, "{s} {s} - iteration {d}", .{ prefix, task.state, iteration })
            else
                try std.fmt.allocPrint(alloc, "{s} {s}", .{ prefix, task.state });
            defer alloc.free(subtitle);
            const row = try ui.row(alloc, taskIcon(task.state), title_task, subtitle);
            vh.setIndex(row.as(gobject.Object), index);
            list.append(row.as(gtk.Widget));
        }
        body.append(list.as(gtk.Widget));
        if (self.selectedTask(inspection.*)) |task| {
            const card = gtk.Box.new(.vertical, 4);
            card.as(gtk.Widget).addCssClass("card");
            ui.margin(card.as(gtk.Widget), 12);
            card.append(ui.heading("Selected Node").as(gtk.Widget));
            try vh.detailRow(alloc, card, "Label", task.label orelse task.node_id);
            try vh.detailRow(alloc, card, "ID", task.node_id);
            try vh.detailRow(alloc, card, "State", task.state);
            if (task.iteration) |iteration| {
                const text = try std.fmt.allocPrint(alloc, "{d}", .{iteration});
                defer alloc.free(text);
                try vh.detailRow(alloc, card, "Iteration", text);
            }
            body.append(card.as(gtk.Widget));
        }
    }

    fn completeApproval(self: *Self, method: []const u8, label: []const u8) void {
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
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("{s} {s}", .{ label, task.node_id });
        self.refresh();
    }

    fn confirmDenySelectedNode(self: *Self) void {
        const inspection = self.private().inspection orelse return;
        const task = blockedTask(inspection) orelse return;
        const alloc = self.allocator();
        if (self.private().pending_deny) |*pending| pending.deinit(alloc);
        self.private().pending_deny = .{
            .run_id = alloc.dupe(u8, inspection.run.run_id) catch return,
            .node_id = alloc.dupe(u8, task.node_id) catch return,
            .iteration = task.iteration,
        };
        const body = std.fmt.allocPrintSentinel(alloc, "Deny approval for {s} on run {s}? This will fail the waiting gate.", .{ task.node_id, inspection.run.run_id }, 0) catch return;
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Deny Approval", body.ptr);
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("deny", "Deny Approval");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");
        dialog.setResponseAppearance("deny", .destructive);
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, denyDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn simpleRunAction(self: *Self, method: []const u8, label: []const u8) void {
        const run_id = self.private().run_id orelse return;
        const alloc = self.allocator();
        const args = vh.jsonObject(alloc, &.{.{ .key = "runId", .value = .{ .string = run_id } }}) catch return;
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), method, args) catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("{s} {s}", .{ label, run_id });
        self.refresh();
    }

    fn snapshotRunAction(self: *Self, method: []const u8, label: []const u8) void {
        const run_id = self.private().run_id orelse return;
        const alloc = self.allocator();
        const snapshots_json = vh.callJson(alloc, self.client(), "listSnapshots", &.{.{ .key = "runId", .value = .{ .string = run_id } }}) catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(snapshots_json);
        var snapshots = vh.parseItems(alloc, snapshots_json, &.{ "snapshots", "items", "data" }, .{
            .id = &.{"id"},
            .title = &.{ "label", "id" },
            .subtitle = &.{ "nodeId", "node_id", "createdAtMs", "created_at_ms" },
        }) catch std.ArrayList(vh.Item).empty;
        defer {
            vh.clearItems(alloc, &snapshots);
            snapshots.deinit(alloc);
        }
        if (snapshots.items.len == 0) {
            self.private().window.showToast("No snapshots available for this run");
            return;
        }
        const args = vh.jsonObject(alloc, &.{.{ .key = "snapshotId", .value = .{ .string = snapshots.items[0].id } }}) catch return;
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), method, args) catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("{s} from {s}", .{ label, snapshots.items[0].id });
    }

    fn showSnapshots(self: *Self) void {
        const run_id = self.private().run_id orelse return;
        const alloc = self.allocator();
        const snapshots_json = vh.callJson(alloc, self.client(), "listSnapshots", &.{.{ .key = "runId", .value = .{ .string = run_id } }}) catch |err| {
            self.private().window.showToastFmt("Snapshots failed: {}", .{err});
            return;
        };
        defer alloc.free(snapshots_json);
        var snapshots = vh.parseItems(alloc, snapshots_json, &.{ "snapshots", "items", "data" }, .{
            .id = &.{"id"},
            .title = &.{ "label", "id" },
            .subtitle = &.{ "nodeId", "node_id", "createdAtMs", "created_at_ms" },
        }) catch std.ArrayList(vh.Item).empty;
        defer {
            vh.clearItems(alloc, &snapshots);
            snapshots.deinit(alloc);
        }
        const body = std.fmt.allocPrintSentinel(alloc, "{d} snapshot(s) are available for run {s}. Fork Latest and Replay Latest use the newest snapshot.", .{ snapshots.items.len, run_id }, 0) catch return;
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Run Snapshots", body.ptr);
        dialog.addResponse("close", "Close");
        dialog.setCloseResponse("close");
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
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

    fn currentTask(inspection: models.RunInspection) ?models.RunTask {
        for (inspection.tasks.items) |task| {
            if (std.ascii.eqlIgnoreCase(task.state, "running") or
                std.ascii.eqlIgnoreCase(task.state, "blocked") or
                std.ascii.eqlIgnoreCase(task.state, "waiting") or
                std.ascii.eqlIgnoreCase(task.state, "waiting-approval"))
            {
                return task;
            }
        }
        if (inspection.tasks.items.len == 0) return null;
        return inspection.tasks.items[inspection.tasks.items.len - 1];
    }

    fn selectedTask(self: *Self, inspection: models.RunInspection) ?models.RunTask {
        if (inspection.tasks.items.len == 0) return null;
        const index = @min(self.private().selected_task_index, inspection.tasks.items.len - 1);
        return inspection.tasks.items[index];
    }

    fn clampSelection(self: *Self) void {
        const inspection = self.private().inspection orelse {
            self.private().selected_task_index = 0;
            return;
        };
        if (inspection.tasks.items.len == 0) {
            self.private().selected_task_index = 0;
            return;
        }
        if (self.private().selected_task_index >= inspection.tasks.items.len) {
            self.private().selected_task_index = inspection.tasks.items.len - 1;
        }
    }

    fn showTaskDialog(self: *Self, task: models.RunTask) void {
        const alloc = self.allocator();
        const body = if (task.iteration) |iteration|
            std.fmt.allocPrintSentinel(alloc, "Node: {s}\nState: {s}\nIteration: {d}", .{ task.node_id, task.state, iteration }, 0) catch return
        else
            std.fmt.allocPrintSentinel(alloc, "Node: {s}\nState: {s}", .{ task.node_id, task.state }, 0) catch return;
        defer alloc.free(body);
        const title = task.label orelse task.node_id;
        const title_z = alloc.dupeZ(u8, title) catch return;
        defer alloc.free(title_z);
        const dialog = adw.AlertDialog.new(title_z.ptr, body.ptr);
        dialog.addResponse("close", "Close");
        dialog.setCloseResponse("close");
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn taskIcon(status: []const u8) [:0]const u8 {
        if (std.ascii.eqlIgnoreCase(status, "running")) return "media-playback-start-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "finished")) return "emblem-ok-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "failed")) return "dialog-error-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "blocked") or std.ascii.eqlIgnoreCase(status, "waiting-approval")) return "security-high-symbolic";
        return "view-list-symbolic";
    }

    fn backClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().window.showNav(.runs);
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn liveChatClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const run_id = self.private().run_id orelse return;
        self.private().window.inspectRun(run_id);
    }

    fn snapshotsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showSnapshots();
    }

    fn watchClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const run_id = self.private().run_id orelse return;
        self.private().window.showToastFmt("Watch command: jjhub run watch {s}", .{run_id});
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.simpleRunAction("cancelRun", "Cancelled");
    }

    fn rerunClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.simpleRunAction("rerunRun", "Reran");
    }

    fn forkClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.snapshotRunAction("forkRun", "Forked");
    }

    fn replayClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.snapshotRunAction("replayRun", "Replayed");
    }

    fn hijackClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.simpleRunAction("hijackRun", "Hijacked");
    }

    fn approveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.completeApproval("approveNode", "Approved");
    }

    fn denyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.confirmDenySelectedNode();
    }

    fn denyDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        if (std.mem.orderZ(u8, response, "deny") != .eq) {
            if (self.private().pending_deny) |*pending| {
                pending.deinit(self.allocator());
                self.private().pending_deny = null;
            }
            return;
        }
        self.completeApproval("denyNode", "Denied");
        if (self.private().pending_deny) |*pending| {
            pending.deinit(self.allocator());
            self.private().pending_deny = null;
        }
    }

    fn listModeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().mode = .list;
        self.render() catch {};
    }

    fn dagModeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().mode = .dag;
        self.render() catch {};
    }

    fn taskRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        const inspection = self.private().inspection orelse return;
        if (index >= inspection.tasks.items.len) return;
        self.private().selected_task_index = index;
        self.showTaskDialog(inspection.tasks.items[index]);
        self.render() catch {};
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn shortcutListMode(self: *Self) void {
        self.private().mode = .list;
        self.render() catch {};
    }

    fn shortcutDagMode(self: *Self) void {
        self.private().mode = .dag;
        self.render() catch {};
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.clearInspection();
            if (priv.run_id) |run_id| {
                self.allocator().free(run_id);
                priv.run_id = null;
            }
            if (priv.pending_deny) |*pending| {
                pending.deinit(self.allocator());
                priv.pending_deny = null;
            }
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
