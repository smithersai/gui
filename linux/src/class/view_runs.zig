const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const models = @import("../models.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;
const logx = @import("../log.zig");
const log = std.log.scoped(.smithers_gtk_view_runs);

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
        workflow_entry: *gtk.Entry = undefined,
        count_label: *gtk.Label = undefined,
        status_filter: ?[]const u8 = null,
        date_filter: DateFilter = .all,
        sort_desc: bool = true,
        pending_cancel_index: ?usize = null,
        pending_deny: ?PendingDeny = null,
        poll_source: c_uint = 0,
        runs: std.ArrayList(models.RunSummary) = .empty,
        inspection: ?models.RunInspection = null,
        selected_index: ?usize = null,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    const DateFilter = enum {
        all,
        today,
        week,
        month,
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

    pub fn refresh(self: *Self) void {
        logx.event(log, "refresh_start", "view=runs", .{});
        const t = logx.startTimer();
        self.loadRuns() catch |err| {
            logx.catchWarn(log, "refresh loadRuns", err);
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Runs unavailable", @errorName(err));
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
        const root = self.as(gtk.Box);
        root.as(gtk.Orientable).setOrientation(.vertical);
        root.setSpacing(0);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>r", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>f", self, shortcutSearch);

        const header = vh.makeHeader("Runs", null);
        self.private().count_label = ui.dim("0 runs");
        header.append(self.private().count_label.as(gtk.Widget));
        self.private().search_entry = gtk.Entry.new();
        self.private().search_entry.setPlaceholderText("Search runs");
        self.private().search_entry.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().search_entry.as(gtk.Editable), *Self, searchChanged, self, .{});
        _ = gtk.Entry.signals.activate.connect(self.private().search_entry, *Self, searchActivated, self, .{});
        header.append(self.private().search_entry.as(gtk.Widget));
        const sort_button = ui.textButton("Newest First", false);
        _ = gtk.Button.signals.clicked.connect(sort_button, *Self, sortClicked, self, .{});
        header.append(sort_button.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh runs");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const filters = gtk.Box.new(.horizontal, 8);
        ui.margin4(filters.as(gtk.Widget), 8, 16, 8, 16);
        inline for (.{ "All", "running", "waiting-approval", "finished", "failed", "cancelled" }) |label| {
            const button = ui.textButton(label, false);
            button.as(gtk.Widget).setTooltipText(label);
            _ = gtk.Button.signals.clicked.connect(button, *Self, statusFilterClicked, self, .{});
            button.as(gobject.Object).setData("smithers-status-filter", @constCast(label.ptr));
            filters.append(button.as(gtk.Widget));
        }
        self.private().workflow_entry = gtk.Entry.new();
        self.private().workflow_entry.setPlaceholderText("Workflow");
        self.private().workflow_entry.as(gtk.Widget).setSizeRequest(180, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().workflow_entry.as(gtk.Editable), *Self, workflowChanged, self, .{});
        filters.append(self.private().workflow_entry.as(gtk.Widget));
        inline for (.{ "All Time", "Today", "This Week", "This Month" }, 0..) |label, index| {
            const button = ui.textButton(label, false);
            button.as(gtk.Widget).setTooltipText(label);
            _ = gtk.Button.signals.clicked.connect(button, *Self, dateFilterClicked, self, .{});
            button.as(gobject.Object).setData("smithers-date-filter", @ptrFromInt(index + 1));
            filters.append(button.as(gtk.Widget));
        }
        const clear = ui.textButton("Clear", false);
        clear.as(gtk.Widget).setTooltipText("Clear filters");
        _ = gtk.Button.signals.clicked.connect(clear, *Self, clearFiltersClicked, self, .{});
        filters.append(clear.as(gtk.Widget));
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
        self.private().poll_source = glib.timeoutAdd(5000, pollRuns, self);
    }

    fn loadRuns(self: *Self) !void {
        const alloc = self.allocator();
        const selected_run_id = if (self.private().selected_index) |index|
            if (index < self.private().runs.items.len) try alloc.dupe(u8, self.private().runs.items[index].run_id) else null
        else
            null;
        defer if (selected_run_id) |run_id| alloc.free(run_id);
        log.debug("calling method=listRuns args={s}", .{"{}"});
        const t = logx.startTimer();
        const json = try smithers.callJson(alloc, self.client(), "listRuns", "{}");
        defer alloc.free(json);
        const parsed = try models.parseRuns(alloc, json);
        log.info("method=listRuns rows={d} duration_ms={d}", .{ parsed.items.len, t.elapsedMs() });
        models.clearList(models.RunSummary, alloc, &self.private().runs);
        self.private().runs = parsed;
        self.sortRuns();
        self.clearInspection();
        try self.renderList();
        self.private().selected_index = null;
        if (selected_run_id) |run_id| {
            for (self.private().runs.items, 0..) |run, index| {
                if (std.mem.eql(u8, run.run_id, run_id)) {
                    self.private().selected_index = index;
                    logx.event(log, "reselect_run", "run_id={s} index={d}", .{ run.run_id, index });
                    self.loadInspection(index) catch |err| logx.catchWarn(log, "loadRuns.reselect loadInspection", err);
                    return;
                }
            }
        }
        logx.event(log, "refresh_done", "view=runs rows={d}", .{self.private().runs.items.len});
        vh.setStatus(alloc, self.private().detail, "view-list-symbolic", "Select a run", "Run tasks and actions appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        const list = self.private().list;
        ui.clearList(list);
        var visible: usize = 0;
        const sections = [_]struct { title: []const u8, status: []const []const u8 }{
            .{ .title = "ACTIVE", .status = &.{ "running", "waiting-approval", "blocked" } },
            .{ .title = "COMPLETED", .status = &.{"finished"} },
            .{ .title = "FAILED", .status = &.{"failed"} },
            .{ .title = "CANCELLED", .status = &.{"cancelled"} },
            .{ .title = "OTHER", .status = &.{} },
        };
        var emitted = [_]bool{false} ** sections.len;
        for (self.private().runs.items, 0..) |run, index| {
            if (!self.matchesFilters(run)) continue;
            const section_index = sectionIndex(run.status);
            if (!emitted[section_index]) {
                emitted[section_index] = true;
                const title_z = try alloc.dupeZ(u8, sections[section_index].title);
                defer alloc.free(title_z);
                const row = gtk.ListBoxRow.new();
                row.setActivatable(0);
                const label = ui.dim(title_z);
                ui.margin4(label.as(gtk.Widget), 10, 10, 4, 10);
                row.setChild(label.as(gtk.Widget));
                list.append(row.as(gtk.Widget));
            }
            try self.appendRunRow(index);
            visible += 1;
        }
        const count_text = try std.fmt.allocPrintSentinel(alloc, "{d} run{s}", .{ visible, if (visible == 1) "" else "s" }, 0);
        defer alloc.free(count_text);
        self.private().count_label.setText(count_text.ptr);
        if (visible == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No runs found", "Adjust filters or launch a workflow.")).as(gtk.Widget));
        }
    }

    fn appendRunRow(self: *Self, index: usize) !void {
        const alloc = self.allocator();
        const run = self.private().runs.items[index];
        const title = run.workflow_name orelse "Unnamed workflow";
        const elapsed = elapsedText(alloc, run) catch try alloc.dupe(u8, "-");
        defer alloc.free(elapsed);
        const detail = try std.fmt.allocPrint(alloc, "{s} - {s} - {d}/{d} nodes - {s}", .{
            run.run_id,
            run.status,
            run.finished + run.failed,
            run.total,
            elapsed,
        });
        defer alloc.free(detail);
        const row = try ui.row(alloc, runIcon(run.status), title, detail);
        vh.setIndex(row.as(gobject.Object), index);
        const tooltip = try alloc.dupeZ(u8, run.run_id);
        defer alloc.free(tooltip);
        row.as(gtk.Widget).setTooltipText(tooltip.ptr);
        self.private().list.append(row.as(gtk.Widget));
    }

    fn sortRuns(self: *Self) void {
        if (self.private().sort_desc) {
            std.mem.sort(models.RunSummary, self.private().runs.items, {}, newerRunFirst);
        } else {
            std.mem.sort(models.RunSummary, self.private().runs.items, {}, olderRunFirst);
        }
    }

    fn runTimestamp(run: models.RunSummary) i64 {
        return run.started_at_ms orelse run.finished_at_ms orelse 0;
    }

    fn newerRunFirst(_: void, lhs: models.RunSummary, rhs: models.RunSummary) bool {
        return runTimestamp(lhs) > runTimestamp(rhs);
    }

    fn olderRunFirst(_: void, lhs: models.RunSummary, rhs: models.RunSummary) bool {
        return runTimestamp(lhs) < runTimestamp(rhs);
    }

    fn matchesFilters(self: *Self, run: models.RunSummary) bool {
        if (self.private().status_filter) |status| {
            if (!std.ascii.eqlIgnoreCase(run.status, status)) return false;
        }
        const search = std.mem.trim(u8, std.mem.span(self.private().search_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        const workflow_filter = std.mem.trim(u8, std.mem.span(self.private().workflow_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (workflow_filter.len > 0 and !(run.workflow_name != null and containsIgnoreCase(run.workflow_name.?, workflow_filter)) and
            !(run.workflow_path != null and containsIgnoreCase(run.workflow_path.?, workflow_filter))) return false;
        if (!matchesDate(self.private().date_filter, run)) return false;
        if (search.len == 0) return true;
        return containsIgnoreCase(run.run_id, search) or
            (run.workflow_name != null and containsIgnoreCase(run.workflow_name.?, search)) or
            (run.workflow_path != null and containsIgnoreCase(run.workflow_path.?, search));
    }

    fn selectRun(self: *Self, index: usize) void {
        if (index >= self.private().runs.items.len) return;
        const run = self.private().runs.items[index];
        logx.event(log, "row_selected", "view=runs index={d} run_id={s}", .{ index, run.run_id });
        self.private().selected_index = index;
        self.loadInspection(index) catch |err| {
            logx.catchErr(log, "selectRun loadInspection", err);
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Run inspection failed", @errorName(err));
        };
    }

    fn loadInspection(self: *Self, index: usize) !void {
        const run = self.private().runs.items[index];
        const alloc = self.allocator();
        const args = try vh.jsonObject(alloc, &.{.{ .key = "runId", .value = .{ .string = run.run_id } }});
        defer alloc.free(args);
        log.debug("calling method=inspectRun run_id={s} index={d} args={s}", .{ run.run_id, index, args });
        const t = logx.startTimer();
        const json = smithers.callJson(alloc, self.client(), "inspectRun", args) catch |err| {
            log.err("method=inspectRun run_id={s} failed: {s}", .{ run.run_id, @errorName(err) });
            return err;
        };
        defer alloc.free(json);
        log.info("method=inspectRun run_id={s} duration_ms={d}", .{ run.run_id, t.elapsedMs() });

        self.clearInspection();
        self.private().inspection = models.parseRunInspection(alloc, json) catch |err| {
            log.err("parseRunInspection run_id={s} failed: {s} json_len={d}", .{ run.run_id, @errorName(err), json.len });
            return err;
        };
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
        const live = ui.textButton("Live Chat", false);
        live.as(gtk.Widget).setTooltipText("Open the live run inspector for this run");
        _ = gtk.Button.signals.clicked.connect(live, *Self, liveChatClicked, self, .{});
        actions.append(live.as(gtk.Widget));
        const inspect = ui.textButton("Open Inspector", true);
        _ = gtk.Button.signals.clicked.connect(inspect, *Self, openInspectorClicked, self, .{});
        actions.append(inspect.as(gtk.Widget));
        const snapshots = ui.textButton("Snapshots", false);
        _ = gtk.Button.signals.clicked.connect(snapshots, *Self, snapshotsClicked, self, .{});
        actions.append(snapshots.as(gtk.Widget));
        const hijack = ui.textButton("Hijack", false);
        _ = gtk.Button.signals.clicked.connect(hijack, *Self, hijackClicked, self, .{});
        actions.append(hijack.as(gtk.Widget));
        const refresh_status = ui.textButton("Refresh Status", false);
        _ = gtk.Button.signals.clicked.connect(refresh_status, *Self, refreshStatusClicked, self, .{});
        actions.append(refresh_status.as(gtk.Widget));
        const rerun = ui.textButton("Rerun", false);
        _ = gtk.Button.signals.clicked.connect(rerun, *Self, rerunClicked, self, .{});
        actions.append(rerun.as(gtk.Widget));
        const fork = ui.textButton("Fork", false);
        _ = gtk.Button.signals.clicked.connect(fork, *Self, forkClicked, self, .{});
        actions.append(fork.as(gtk.Widget));
        const replay = ui.textButton("Replay", false);
        _ = gtk.Button.signals.clicked.connect(replay, *Self, replayClicked, self, .{});
        actions.append(replay.as(gtk.Widget));
        if (!isTerminalStatus(inspection.run.status)) {
            const cancel = ui.textButton("Cancel", false);
            cancel.as(gtk.Widget).addCssClass("destructive-action");
            _ = gtk.Button.signals.clicked.connect(cancel, *Self, cancelClicked, self, .{});
            actions.append(cancel.as(gtk.Widget));
        }
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
        if (inspection.run.error_json) |err| {
            try vh.appendJsonViewer(alloc, detail, "ERROR", err, 120);
        }
    }

    fn completeApproval(self: *Self, method: []const u8, toast_prefix: []const u8) void {
        const inspection = self.private().inspection orelse return;
        const task = blockedTask(inspection) orelse return;
        const alloc = self.allocator();
        const args = vh.jsonObject(alloc, &.{
            .{ .key = "runId", .value = .{ .string = inspection.run.run_id } },
            .{ .key = "nodeId", .value = .{ .string = task.node_id } },
            .{ .key = "iteration", .value = if (task.iteration) |iteration| .{ .integer = iteration } else .null },
        }) catch |err| {
            logx.catchWarn(log, "completeApproval jsonObject", err);
            return;
        };
        defer alloc.free(args);
        log.debug("calling method={s} run_id={s} node_id={s} args={s}", .{ method, inspection.run.run_id, task.node_id, args });
        const t = logx.startTimer();
        const json = smithers.callJson(alloc, self.client(), method, args) catch |err| {
            log.warn("method={s} run_id={s} node_id={s} failed: {s}", .{ method, inspection.run.run_id, task.node_id, @errorName(err) });
            self.private().window.showToastFmt("{s} failed: {}", .{ toast_prefix, err });
            return;
        };
        defer alloc.free(json);
        log.info("method={s} run_id={s} node_id={s} duration_ms={d}", .{ method, inspection.run.run_id, task.node_id, t.elapsedMs() });
        self.private().window.showToastFmt("{s} {s}", .{ toast_prefix, task.node_id });
        if (self.private().selected_index) |index| self.loadInspection(index) catch |err| logx.catchWarn(log, "completeApproval reload", err);
    }

    fn cancelSelectedRun(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().runs.items.len) return;
        const run = self.private().runs.items[index];
        const alloc = self.allocator();
        const args = vh.jsonObject(alloc, &.{.{ .key = "runId", .value = .{ .string = run.run_id } }}) catch |err| {
            logx.catchWarn(log, "cancelSelectedRun jsonObject", err);
            return;
        };
        defer alloc.free(args);
        log.debug("calling method=cancelRun run_id={s} args={s}", .{ run.run_id, args });
        const t = logx.startTimer();
        const json = smithers.callJson(alloc, self.client(), "cancelRun", args) catch |err| {
            log.warn("method=cancelRun run_id={s} failed: {s}", .{ run.run_id, @errorName(err) });
            self.private().window.showToastFmt("Cancel failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        log.info("method=cancelRun run_id={s} duration_ms={d}", .{ run.run_id, t.elapsedMs() });
        self.private().window.showToastFmt("Cancelled {s}", .{run.run_id});
        self.refresh();
    }

    fn confirmCancelSelectedRun(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().runs.items.len) return;
        self.private().pending_cancel_index = index;
        const run = self.private().runs.items[index];
        const alloc = self.allocator();
        const body = std.fmt.allocPrintSentinel(alloc, "Cancel run {s}? This run is still active and will stop immediately.", .{run.run_id}, 0) catch |err| {
            logx.catchWarn(log, "confirmCancelSelectedRun allocPrint", err);
            return;
        };
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Cancel Run", body.ptr);
        dialog.addResponse("keep", "Keep Running");
        dialog.addResponse("cancel", "Cancel Run");
        dialog.setCloseResponse("keep");
        dialog.setDefaultResponse("keep");
        dialog.setResponseAppearance("cancel", .destructive);
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, cancelDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn confirmDenySelectedNode(self: *Self) void {
        const inspection = self.private().inspection orelse return;
        const task = blockedTask(inspection) orelse return;
        const alloc = self.allocator();
        if (self.private().pending_deny) |*pending| pending.deinit(alloc);
        self.private().pending_deny = .{
            .run_id = alloc.dupe(u8, inspection.run.run_id) catch |err| {
                logx.catchWarn(log, "confirmDenySelectedNode dupe run_id", err);
                return;
            },
            .node_id = alloc.dupe(u8, task.node_id) catch |err| {
                logx.catchWarn(log, "confirmDenySelectedNode dupe node_id", err);
                return;
            },
            .iteration = task.iteration,
        };
        const body = std.fmt.allocPrintSentinel(alloc, "Deny approval for {s} on run {s}? This will fail the waiting gate.", .{ task.node_id, inspection.run.run_id }, 0) catch |err| {
            logx.catchWarn(log, "confirmDenySelectedNode allocPrint", err);
            return;
        };
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Deny Approval", body.ptr);
        dialog.addResponse("keep", "Cancel");
        dialog.addResponse("deny", "Deny Approval");
        dialog.setCloseResponse("keep");
        dialog.setDefaultResponse("keep");
        dialog.setResponseAppearance("deny", .destructive);
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, denyDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn simpleRunAction(self: *Self, method: []const u8, label: []const u8) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().runs.items.len) return;
        const run = self.private().runs.items[index];
        const alloc = self.allocator();
        const args = vh.jsonObject(alloc, &.{.{ .key = "runId", .value = .{ .string = run.run_id } }}) catch |err| {
            logx.catchWarn(log, "simpleRunAction jsonObject", err);
            return;
        };
        defer alloc.free(args);
        log.debug("calling method={s} run_id={s} args={s}", .{ method, run.run_id, args });
        const t = logx.startTimer();
        const json = smithers.callJson(alloc, self.client(), method, args) catch |err| {
            log.warn("method={s} run_id={s} failed: {s}", .{ method, run.run_id, @errorName(err) });
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(json);
        log.info("method={s} run_id={s} duration_ms={d}", .{ method, run.run_id, t.elapsedMs() });
        self.private().window.showToastFmt("{s} {s}", .{ label, run.run_id });
        if (self.private().selected_index) |selected| self.loadInspection(selected) catch |err| {
            logx.catchWarn(log, "simpleRunAction reload", err);
            self.refresh();
        };
    }

    fn snapshotRunAction(self: *Self, method: []const u8, label: []const u8) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().runs.items.len) return;
        const run = self.private().runs.items[index];
        const alloc = self.allocator();
        log.debug("calling method=listSnapshots run_id={s}", .{run.run_id});
        const list_t = logx.startTimer();
        const snapshots_json = vh.callJson(alloc, self.client(), "listSnapshots", &.{.{ .key = "runId", .value = .{ .string = run.run_id } }}) catch |err| {
            log.warn("method=listSnapshots run_id={s} failed: {s}", .{ run.run_id, @errorName(err) });
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(snapshots_json);
        var snapshots = vh.parseItems(alloc, snapshots_json, &.{ "snapshots", "items", "data" }, .{
            .id = &.{"id"},
            .title = &.{ "label", "id" },
            .subtitle = &.{ "nodeId", "node_id", "createdAtMs", "created_at_ms" },
        }) catch |err| blk: {
            logx.catchWarn(log, "snapshotRunAction parseItems", err);
            break :blk std.ArrayList(vh.Item).empty;
        };
        defer {
            vh.clearItems(alloc, &snapshots);
            snapshots.deinit(alloc);
        }
        log.info("method=listSnapshots run_id={s} rows={d} duration_ms={d}", .{ run.run_id, snapshots.items.len, list_t.elapsedMs() });
        if (snapshots.items.len == 0) {
            self.private().window.showToast("No snapshots available for this run");
            return;
        }
        const args = vh.jsonObject(alloc, &.{.{ .key = "snapshotId", .value = .{ .string = snapshots.items[0].id } }}) catch |err| {
            logx.catchWarn(log, "snapshotRunAction jsonObject", err);
            return;
        };
        defer alloc.free(args);
        log.debug("calling method={s} snapshot_id={s} args={s}", .{ method, snapshots.items[0].id, args });
        const t = logx.startTimer();
        const json = smithers.callJson(alloc, self.client(), method, args) catch |err| {
            log.warn("method={s} snapshot_id={s} failed: {s}", .{ method, snapshots.items[0].id, @errorName(err) });
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(json);
        log.info("method={s} snapshot_id={s} duration_ms={d}", .{ method, snapshots.items[0].id, t.elapsedMs() });
        self.private().window.showToastFmt("{s} from {s}", .{ label, snapshots.items[0].id });
        self.private().window.showNav(.runs);
    }

    fn showSnapshots(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().runs.items.len) return;
        const run = self.private().runs.items[index];
        const alloc = self.allocator();
        log.debug("calling method=listSnapshots run_id={s}", .{run.run_id});
        const t = logx.startTimer();
        const snapshots_json = vh.callJson(alloc, self.client(), "listSnapshots", &.{.{ .key = "runId", .value = .{ .string = run.run_id } }}) catch |err| {
            log.warn("method=listSnapshots run_id={s} failed: {s}", .{ run.run_id, @errorName(err) });
            self.private().window.showToastFmt("Snapshots failed: {}", .{err});
            return;
        };
        defer alloc.free(snapshots_json);
        var snapshots = vh.parseItems(alloc, snapshots_json, &.{ "snapshots", "items", "data" }, .{
            .id = &.{"id"},
            .title = &.{ "label", "id" },
            .subtitle = &.{ "nodeId", "node_id", "createdAtMs", "created_at_ms" },
        }) catch |err| blk: {
            logx.catchWarn(log, "showSnapshots parseItems", err);
            break :blk std.ArrayList(vh.Item).empty;
        };
        defer {
            vh.clearItems(alloc, &snapshots);
            snapshots.deinit(alloc);
        }
        log.info("method=listSnapshots run_id={s} rows={d} duration_ms={d}", .{ run.run_id, snapshots.items.len, t.elapsedMs() });
        const message = std.fmt.allocPrintSentinel(alloc, "{d} snapshot(s) are available for run {s}. Use Fork or Replay to branch from the newest snapshot.", .{ snapshots.items.len, run.run_id }, 0) catch |err| {
            logx.catchWarn(log, "showSnapshots allocPrint", err);
            return;
        };
        defer alloc.free(message);
        const dialog = adw.AlertDialog.new("Run Snapshots", message.ptr);
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

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn sectionIndex(status: []const u8) usize {
        if (std.ascii.eqlIgnoreCase(status, "running") or std.ascii.eqlIgnoreCase(status, "waiting-approval") or std.ascii.eqlIgnoreCase(status, "blocked")) return 0;
        if (std.ascii.eqlIgnoreCase(status, "finished")) return 1;
        if (std.ascii.eqlIgnoreCase(status, "failed")) return 2;
        if (std.ascii.eqlIgnoreCase(status, "cancelled")) return 3;
        return 4;
    }

    fn matchesDate(filter: DateFilter, run: models.RunSummary) bool {
        if (filter == .all) return true;
        const timestamp = run.started_at_ms orelse run.finished_at_ms orelse return false;
        const now = std.time.milliTimestamp();
        const day_ms: i64 = 86_400_000;
        const cutoff: i64 = switch (filter) {
            .all => 0,
            .today => now - day_ms,
            .week => now - 7 * day_ms,
            .month => now - 31 * day_ms,
        };
        return timestamp >= cutoff;
    }

    fn isTerminalStatus(status: []const u8) bool {
        return std.ascii.eqlIgnoreCase(status, "finished") or
            std.ascii.eqlIgnoreCase(status, "failed") or
            std.ascii.eqlIgnoreCase(status, "cancelled");
    }

    fn elapsedText(alloc: std.mem.Allocator, run: models.RunSummary) ![]u8 {
        const start = run.started_at_ms orelse return alloc.dupe(u8, "-");
        const end = run.finished_at_ms orelse std.time.milliTimestamp();
        const seconds = @max(@as(i64, 0), @divTrunc(end - start, 1000));
        if (seconds < 60) return std.fmt.allocPrint(alloc, "{d}s", .{seconds});
        if (seconds < 3600) return std.fmt.allocPrint(alloc, "{d}m", .{@divTrunc(seconds, 60)});
        return std.fmt.allocPrint(alloc, "{d}h {d}m", .{ @divTrunc(seconds, 3600), @mod(@divTrunc(seconds, 60), 60) });
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
        self.renderList() catch |err| logx.catchWarn(log, "searchActivated renderList", err);
    }

    fn searchChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.renderList() catch |err| logx.catchWarn(log, "searchChanged renderList", err);
    }

    fn workflowChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.renderList() catch |err| logx.catchWarn(log, "workflowChanged renderList", err);
    }

    fn sortClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().sort_desc = !self.private().sort_desc;
        self.sortRuns();
        self.renderList() catch |err| logx.catchWarn(log, "sortClicked renderList", err);
        self.private().window.showToast(if (self.private().sort_desc) "Sorted newest first" else "Sorted oldest first");
    }

    fn statusFilterClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-status-filter") orelse return;
        const label: [*:0]const u8 = @ptrCast(raw);
        const text = std.mem.span(label);
        self.private().status_filter = if (std.mem.eql(u8, text, "All")) null else text;
        self.renderList() catch |err| logx.catchWarn(log, "statusFilterClicked renderList", err);
    }

    fn dateFilterClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-date-filter") orelse return;
        self.private().date_filter = switch (@intFromPtr(raw)) {
            2 => .today,
            3 => .week,
            4 => .month,
            else => .all,
        };
        self.renderList() catch |err| logx.catchWarn(log, "dateFilterClicked renderList", err);
    }

    fn clearFiltersClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().status_filter = null;
        self.private().date_filter = .all;
        self.private().search_entry.as(gtk.Editable).setText("");
        self.private().workflow_entry.as(gtk.Editable).setText("");
        self.renderList() catch |err| logx.catchWarn(log, "clearFiltersClicked renderList", err);
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.selectRun(index);
    }

    fn openInspectorClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const inspection = self.private().inspection orelse return;
        self.private().window.inspectRun(inspection.run.run_id);
    }

    fn liveChatClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const inspection = self.private().inspection orelse return;
        self.private().window.inspectRun(inspection.run.run_id);
    }

    fn snapshotsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showSnapshots();
    }

    fn hijackClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.simpleRunAction("hijackRun", "Hijacked");
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.confirmCancelSelectedRun();
    }

    fn cancelDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        if (std.mem.orderZ(u8, response, "cancel") != .eq) {
            self.private().pending_cancel_index = null;
            return;
        }
        self.private().selected_index = self.private().pending_cancel_index;
        self.private().pending_cancel_index = null;
        self.cancelSelectedRun();
    }

    fn denyDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        if (std.mem.orderZ(u8, response, "deny") != .eq) {
            if (self.private().pending_deny) |*pending| {
                pending.deinit(self.allocator());
                self.private().pending_deny = null;
            }
            return;
        }
        const pending = self.private().pending_deny orelse return;
        const alloc = self.allocator();
        const args = vh.jsonObject(alloc, &.{
            .{ .key = "runId", .value = .{ .string = pending.run_id } },
            .{ .key = "nodeId", .value = .{ .string = pending.node_id } },
            .{ .key = "iteration", .value = if (pending.iteration) |iteration| .{ .integer = iteration } else .null },
        }) catch |err| {
            logx.catchWarn(log, "denyDialogResponse jsonObject", err);
            return;
        };
        defer alloc.free(args);
        log.debug("calling method=denyNode run_id={s} node_id={s} args={s}", .{ pending.run_id, pending.node_id, args });
        const t = logx.startTimer();
        const json = smithers.callJson(alloc, self.client(), "denyNode", args) catch |err| {
            log.warn("method=denyNode run_id={s} node_id={s} failed: {s}", .{ pending.run_id, pending.node_id, @errorName(err) });
            self.private().window.showToastFmt("Deny failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        log.info("method=denyNode run_id={s} node_id={s} duration_ms={d}", .{ pending.run_id, pending.node_id, t.elapsedMs() });
        self.private().window.showToastFmt("Denied {s}", .{pending.node_id});
        if (self.private().selected_index) |index| self.loadInspection(index) catch |err| {
            logx.catchWarn(log, "denyDialogResponse reload", err);
            self.refresh();
        };
        if (self.private().pending_deny) |*cleanup| {
            cleanup.deinit(alloc);
            self.private().pending_deny = null;
        }
    }

    fn refreshStatusClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        if (self.private().selected_index) |index| self.loadInspection(index) catch |err| {
            logx.catchWarn(log, "refreshStatusClicked reload", err);
            self.refresh();
        };
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

    fn approveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.completeApproval("approveNode", "Approved");
    }

    fn denyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.confirmDenySelectedNode();
    }

    fn pollRuns(data: ?*anyopaque) callconv(.c) c_int {
        const ptr = data orelse return 0;
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.loadRuns() catch |err| logx.catchDebug(log, "pollRuns loadRuns", err);
        return 1;
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
            if (priv.poll_source != 0) {
                _ = glib.Source.remove(priv.poll_source);
                priv.poll_source = 0;
            }
            if (priv.pending_deny) |*pending| {
                pending.deinit(self.allocator());
                priv.pending_deny = null;
            }
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
