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

pub const WorkflowsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersWorkflowsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        search_entry: *gtk.Entry = undefined,
        source_view: *gtk.TextView = undefined,
        input_view: *gtk.TextView = undefined,
        workflows: std.ArrayList(models.Workflow) = .empty,
        selected_index: ?usize = null,
        pending_index: ?usize = null,
        tab: DetailTab = .source,
        source_dirty: bool = false,
        source_text: ?[]u8 = null,
        suppress_source_changed: bool = false,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    const DetailTab = enum {
        source,
        imports,
        runs,
        launch,
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .window = window };
        try self.build();
        return self;
    }

    pub fn refresh(self: *Self) void {
        self.loadWorkflows() catch |err| {
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Workflows unavailable", @errorName(err));
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
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>f", self, shortcutSearch);

        const header = vh.makeHeader("Workflows", null);
        self.private().search_entry = gtk.Entry.new();
        self.private().search_entry.setPlaceholderText("Search workflows");
        self.private().search_entry.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().search_entry.as(gtk.Editable), *Self, searchChanged, self, .{});
        header.append(self.private().search_entry.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh workflows");
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
        const scroll = ui.scrolled(self.private().detail.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        split.right.append(scroll.as(gtk.Widget));
        root.append(split.root.as(gtk.Widget));

        vh.setStatus(self.allocator(), self.private().detail, "media-playlist-shuffle-symbolic", "Select a workflow", "Source, launch, and diagnostics appear here.");
    }

    fn loadWorkflows(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.client(), "listWorkflows", "{}");
        defer alloc.free(json);
        const parsed = try models.parseWorkflows(alloc, json);
        models.clearList(models.Workflow, alloc, &self.private().workflows);
        self.private().workflows = parsed;
        self.private().selected_index = null;
        try self.renderList();
        vh.setStatus(alloc, self.private().detail, "media-playlist-shuffle-symbolic", "Select a workflow", "Source, launch, and diagnostics appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        const list = self.private().list;
        ui.clearList(list);
        if (self.private().workflows.items.len == 0) {
            list.append((try ui.row(alloc, "emblem-documents-symbolic", "No workflows found", "Create .smithers/workflows entries to launch them here.")).as(gtk.Widget));
            return;
        }
        const query = std.mem.trim(u8, std.mem.span(self.private().search_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        var visible: usize = 0;
        for (self.private().workflows.items, 0..) |workflow, index| {
            if (query.len > 0 and
                !vh.containsIgnoreCase(workflow.name, query) and
                !vh.containsIgnoreCase(workflow.id, query) and
                !(workflow.relative_path != null and vh.containsIgnoreCase(workflow.relative_path.?, query))) continue;
            const path = workflow.relative_path orelse workflow.id;
            const subtitle = try std.fmt.allocPrint(alloc, "{s} - {s}", .{ path, workflow.status });
            defer alloc.free(subtitle);
            const row = try ui.row(alloc, "media-playlist-shuffle-symbolic", workflow.name, subtitle);
            vh.setIndex(row.as(gobject.Object), index);
            list.append(row.as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            list.append((try ui.row(alloc, "system-search-symbolic", "No matching workflows", "Adjust the workflow search.")).as(gtk.Widget));
        }
    }

    fn selectWorkflow(self: *Self, index: usize) void {
        if (index >= self.private().workflows.items.len) return;
        if (self.private().source_dirty and self.private().selected_index != null and self.private().selected_index.? != index) {
            self.private().pending_index = index;
            self.confirmDiscardChanges();
            return;
        }
        self.private().selected_index = index;
        self.private().tab = .source;
        self.private().source_dirty = false;
        if (self.private().source_text) |text| {
            self.allocator().free(text);
            self.private().source_text = null;
        }
        self.renderDetail(index) catch |err| {
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Workflow detail failed", @errorName(err));
        };
    }

    fn renderDetail(self: *Self, index: usize) !void {
        const alloc = self.allocator();
        const workflow = self.private().workflows.items[index];
        const detail = self.private().detail;
        ui.clearBox(detail);

        const title_z = try alloc.dupeZ(u8, workflow.name);
        defer alloc.free(title_z);
        detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, detail, "ID", workflow.id);
        try vh.detailRow(alloc, detail, "Path", workflow.relative_path orelse workflow.id);
        try vh.detailRow(alloc, detail, "Status", workflow.status);
        try vh.detailRow(alloc, detail, "Updated", workflow.updated_at);

        try self.appendTabBar();

        switch (self.private().tab) {
            .source => try self.appendSourceTab(workflow),
            .imports => try self.appendImportsTab(workflow),
            .runs => try self.appendRecentRuns(workflow),
            .launch => try self.appendLaunchTab(workflow),
        }
    }

    fn appendTabBar(self: *Self) !void {
        const detail = self.private().detail;
        const tabs = gtk.Box.new(.horizontal, 6);
        inline for (.{ .source, .imports, .runs, .launch }) |tab_value| {
            const button = ui.textButton(tabTitle(tab_value), self.private().tab == tab_value);
            button.as(gobject.Object).setData("smithers-tab", @ptrFromInt(tabIndex(tab_value) + 1));
            _ = gtk.Button.signals.clicked.connect(button, *Self, tabClicked, self, .{});
            tabs.append(button.as(gtk.Widget));
        }
        const run = ui.textButton("Run", true);
        _ = gtk.Button.signals.clicked.connect(run, *Self, runClicked, self, .{});
        tabs.append(run.as(gtk.Widget));
        if (self.private().source_dirty) {
            if (self.private().tab == .source) {
                const save = ui.textButton("Save All", false);
                _ = gtk.Button.signals.clicked.connect(save, *Self, saveClicked, self, .{});
                tabs.append(save.as(gtk.Widget));
            }
            tabs.append(ui.dim("1 unsaved").as(gtk.Widget));
        }
        detail.append(tabs.as(gtk.Widget));
    }

    fn appendLaunchTab(self: *Self, workflow: models.Workflow) !void {
        const alloc = self.allocator();
        const detail = self.private().detail;
        const actions = gtk.Box.new(.horizontal, 8);
        const doctor = ui.textButton("Run Doctor", false);
        _ = gtk.Button.signals.clicked.connect(doctor, *Self, doctorClicked, self, .{});
        actions.append(doctor.as(gtk.Widget));
        const graph = ui.textButton("Graph", false);
        _ = gtk.Button.signals.clicked.connect(graph, *Self, graphClicked, self, .{});
        actions.append(graph.as(gtk.Widget));
        detail.append(actions.as(gtk.Widget));
        vh.addSectionTitle(detail, "Launch Inputs");
        const dag_text = self.workflowCallText("getWorkflowDAG", workflow) catch null;
        if (dag_text) |text| {
            defer alloc.free(text);
            try self.appendLaunchFields(text);
        } else {
            detail.append(ui.dim("Launch-field analysis is unavailable. Provide raw JSON inputs or run without inputs.").as(gtk.Widget));
        }
        self.private().input_view = vh.textView(true);
        try vh.setTextViewText(alloc, self.private().input_view, "{}");
        const input_scroll = ui.scrolled(self.private().input_view.as(gtk.Widget));
        input_scroll.as(gtk.Widget).setSizeRequest(-1, 120);
        detail.append(input_scroll.as(gtk.Widget));
    }

    fn appendSourceTab(self: *Self, workflow: models.Workflow) !void {
        const alloc = self.allocator();
        const detail = self.private().detail;
        const source_title = ui.heading("Source");
        detail.append(source_title.as(gtk.Widget));
        self.private().source_view = vh.textView(true);
        const path = workflow.relative_path orelse workflow.id;
        const args = try vh.jsonObject(alloc, &.{.{ .key = "relativePath", .value = .{ .string = path } }});
        defer alloc.free(args);
        const source = if (self.private().source_dirty and self.private().source_text != null)
            try alloc.dupe(u8, self.private().source_text.?)
        else source: {
            const raw = smithers.callJson(alloc, self.client(), "readWorkflowSource", args) catch {
                break :source try alloc.dupe(u8, "");
            };
            defer alloc.free(raw);
            break :source vh.parseStringResult(alloc, raw) catch try alloc.dupe(u8, "");
        };
        defer alloc.free(source);
        self.private().suppress_source_changed = true;
        try vh.setTextViewText(alloc, self.private().source_view, source);
        self.private().suppress_source_changed = false;
        _ = gtk.TextBuffer.signals.changed.connect(self.private().source_view.getBuffer(), *Self, sourceChanged, self, .{});
        const source_scroll = ui.scrolled(self.private().source_view.as(gtk.Widget));
        source_scroll.as(gtk.Widget).setVexpand(1);
        source_scroll.as(gtk.Widget).setSizeRequest(-1, 420);
        detail.append(source_scroll.as(gtk.Widget));
    }

    fn appendImportsTab(self: *Self, workflow: models.Workflow) !void {
        const alloc = self.allocator();
        const detail = self.private().detail;
        const path = workflow.relative_path orelse workflow.id;
        const args = try vh.jsonObject(alloc, &.{.{ .key = "relativePath", .value = .{ .string = path } }});
        defer alloc.free(args);
        const source = source: {
            const raw = smithers.callJson(alloc, self.client(), "readWorkflowSource", args) catch {
                break :source try alloc.dupe(u8, "");
            };
            defer alloc.free(raw);
            break :source vh.parseStringResult(alloc, raw) catch try alloc.dupe(u8, "");
        };
        defer alloc.free(source);
        vh.addSectionTitle(detail, "Imports");
        const list = vh.listBox();
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (!std.mem.startsWith(u8, trimmed, "import ")) continue;
            const row = try ui.row(alloc, "text-x-generic-symbolic", trimmed, "Imported workflow dependency");
            list.append(row.as(gtk.Widget));
            count += 1;
        }
        if (count == 0) {
            list.append((try ui.row(alloc, "tray-symbolic", "No imports found", "This workflow source did not contain static import lines.")).as(gtk.Widget));
        }
        detail.append(list.as(gtk.Widget));
    }

    fn selectedWorkflow(self: *Self) ?models.Workflow {
        const index = self.private().selected_index orelse return null;
        if (index >= self.private().workflows.items.len) return null;
        return self.private().workflows.items[index];
    }

    fn workflowCallText(self: *Self, method: []const u8, workflow: models.Workflow) ![]u8 {
        const alloc = self.allocator();
        const path = workflow.relative_path orelse workflow.id;
        const args = try vh.jsonObject(alloc, &.{.{ .key = "workflowPath", .value = .{ .string = path } }});
        defer alloc.free(args);
        const json = try smithers.callJson(alloc, self.client(), method, args);
        defer alloc.free(json);
        return vh.parseStringResult(alloc, json) catch try alloc.dupe(u8, json);
    }

    fn appendLaunchFields(self: *Self, dag_json: []const u8) !void {
        const alloc = self.allocator();
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, dag_json, .{}) catch {
            try vh.detailRow(alloc, self.private().detail, "Fields", "No structured launch fields returned.");
            return;
        };
        defer parsed.deinit();
        const root = vh.object(&parsed.value) orelse return;
        const fields_value = root.get("fields") orelse root.get("launchFields") orelse root.get("inputs") orelse return;
        var fields_copy = fields_value;
        const fields = vh.arrayFromRoot(&fields_copy, &.{ "fields", "items", "data" }) orelse return;
        if (fields.len == 0) {
            try vh.detailRow(alloc, self.private().detail, "Fields", "No dynamic input fields detected.");
            return;
        }
        const list = vh.listBox();
        for (fields) |field_value| {
            var copy = field_value;
            const obj = vh.object(&copy) orelse continue;
            const key = try vh.stringField(alloc, obj, &.{ "key", "name", "id" }) orelse continue;
            defer alloc.free(key);
            const kind = try vh.stringField(alloc, obj, &.{ "type", "kind" }) orelse try alloc.dupe(u8, "string");
            defer alloc.free(kind);
            const required = vh.boolField(obj, &.{"required"}) orelse false;
            const subtitle = try std.fmt.allocPrint(alloc, "{s}{s}", .{ kind, if (required) " - required" else "" });
            defer alloc.free(subtitle);
            list.append((try ui.row(alloc, "insert-text-symbolic", key, subtitle)).as(gtk.Widget));
        }
        self.private().detail.append(list.as(gtk.Widget));
    }

    fn appendRecentRuns(self: *Self, workflow: models.Workflow) !void {
        const alloc = self.allocator();
        const json = smithers.callJson(alloc, self.client(), "listRuns", "{}") catch return;
        defer alloc.free(json);
        var runs = models.parseRuns(alloc, json) catch std.ArrayList(models.RunSummary).empty;
        defer {
            models.clearList(models.RunSummary, alloc, &runs);
            runs.deinit(alloc);
        }
        vh.addSectionTitle(self.private().detail, "Runs");
        const list = vh.listBox();
        var visible: usize = 0;
        const workflow_path = workflow.relative_path orelse workflow.id;
        for (runs.items) |run| {
            const matches_path = run.workflow_path != null and std.mem.eql(u8, run.workflow_path.?, workflow_path);
            const matches_name = run.workflow_name != null and (std.mem.eql(u8, run.workflow_name.?, workflow.name) or std.mem.eql(u8, run.workflow_name.?, workflow.id));
            if (!matches_path and !matches_name) continue;
            const subtitle = try std.fmt.allocPrint(alloc, "{s} - {s}", .{ run.run_id, run.status });
            defer alloc.free(subtitle);
            list.append((try ui.row(alloc, "media-playback-start-symbolic", run.workflow_name orelse run.run_id, subtitle)).as(gtk.Widget));
            visible += 1;
            if (visible >= 5) break;
        }
        if (visible == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No runs for this workflow", "Launch it to populate this list.")).as(gtk.Widget));
        }
        self.private().detail.append(list.as(gtk.Widget));
    }

    fn runSelected(self: *Self) void {
        const workflow = self.selectedWorkflow() orelse return;
        const alloc = self.allocator();
        const path = workflow.relative_path orelse workflow.id;
        const inputs = if (self.private().tab == .launch)
            vh.getTextViewText(alloc, self.private().input_view) catch alloc.dupe(u8, "{}") catch return
        else
            alloc.dupe(u8, "{}") catch return;
        defer alloc.free(inputs);
        const args = vh.jsonObject(alloc, &.{
            .{ .key = "workflowPath", .value = .{ .string = path } },
            .{ .key = "inputs", .value = .{ .raw = if (std.mem.trim(u8, inputs, &std.ascii.whitespace).len == 0) "{}" else inputs } },
        }) catch {
            self.private().window.showToast("Launch inputs must be valid JSON");
            return;
        };
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), "runWorkflow", args) catch |err| {
            self.private().window.showToastFmt("Workflow launch failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Launched {s}", .{workflow.name});
        self.private().window.showNav(.runs);
    }

    fn confirmRunSelected(self: *Self) void {
        const workflow = self.selectedWorkflow() orelse return;
        const alloc = self.allocator();
        const body = std.fmt.allocPrintSentinel(alloc, "Run \"{s}\" with no input form?", .{workflow.name}, 0) catch return;
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Run Workflow", body.ptr);
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("run", "Run");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("run");
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, runDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn saveSelected(self: *Self) void {
        const workflow = self.selectedWorkflow() orelse return;
        const alloc = self.allocator();
        const path = workflow.relative_path orelse workflow.id;
        const source = if (self.private().source_text) |cached|
            alloc.dupe(u8, cached) catch return
        else
            vh.getTextViewText(alloc, self.private().source_view) catch return;
        defer alloc.free(source);
        const args = vh.jsonObject(alloc, &.{
            .{ .key = "relativePath", .value = .{ .string = path } },
            .{ .key = "source", .value = .{ .string = source } },
        }) catch return;
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), "saveWorkflowSource", args) catch |err| {
            self.private().window.showToastFmt("Save failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Saved {s}", .{workflow.name});
        self.private().source_dirty = false;
        if (self.private().source_text) |text| {
            alloc.free(text);
            self.private().source_text = null;
        }
        if (self.private().selected_index) |selected| self.renderDetail(selected) catch {};
    }

    fn confirmDiscardChanges(self: *Self) void {
        const dialog = adw.AlertDialog.new("Unsaved Changes", "You have unsaved workflow source changes. Discard them?");
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("discard", "Discard");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");
        dialog.setResponseAppearance("discard", .destructive);
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, discardDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn showWorkflowCall(self: *Self, method: []const u8, title: []const u8) void {
        const workflow = self.selectedWorkflow() orelse return;
        const alloc = self.allocator();
        const text = self.workflowCallText(method, workflow) catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ title, err });
            return;
        };
        defer alloc.free(text);
        const detail = self.private().detail;
        const heading_z = std.fmt.allocPrintSentinel(alloc, "{s} Result", .{title}, 0) catch return;
        defer alloc.free(heading_z);
        detail.append(ui.heading(heading_z).as(gtk.Widget));
        const view = vh.textView(false);
        vh.setTextViewText(alloc, view, text) catch return;
        const scroll = ui.scrolled(view.as(gtk.Widget));
        scroll.as(gtk.Widget).setSizeRequest(-1, 180);
        detail.append(scroll.as(gtk.Widget));
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.renderList() catch {};
    }

    fn sourceChanged(_: *gtk.TextBuffer, self: *Self) callconv(.c) void {
        if (self.private().suppress_source_changed) return;
        const alloc = self.allocator();
        const text = vh.getTextViewText(alloc, self.private().source_view) catch return;
        if (self.private().source_text) |old| alloc.free(old);
        self.private().source_text = text;
        self.private().source_dirty = true;
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.selectWorkflow(index);
    }

    fn runClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        if (self.private().tab == .launch) {
            self.runSelected();
        } else {
            self.confirmRunSelected();
        }
    }

    fn saveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.saveSelected();
    }

    fn doctorClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showWorkflowCall("runWorkflowDoctor", "Doctor");
    }

    fn graphClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showWorkflowCall("getWorkflowDAG", "Graph");
    }

    fn tabClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-tab") orelse return;
        self.private().tab = tabFromIndex(@intFromPtr(raw) - 1);
        if (self.private().selected_index) |selected| self.renderDetail(selected) catch {};
    }

    fn runDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        if (std.mem.orderZ(u8, response, "run") == .eq) self.runSelected();
    }

    fn discardDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        if (std.mem.orderZ(u8, response, "discard") != .eq) {
            self.private().pending_index = null;
            return;
        }
        const pending = self.private().pending_index orelse return;
        self.private().pending_index = null;
        self.private().source_dirty = false;
        if (self.private().source_text) |text| {
            self.allocator().free(text);
            self.private().source_text = null;
        }
        self.private().selected_index = pending;
        self.private().tab = .source;
        self.renderDetail(pending) catch |err| {
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Workflow detail failed", @errorName(err));
        };
    }

    fn tabTitle(tab: DetailTab) [:0]const u8 {
        return switch (tab) {
            .source => "Workflow",
            .imports => "Imports",
            .runs => "Runs",
            .launch => "Launch",
        };
    }

    fn tabIndex(tab: DetailTab) usize {
        return switch (tab) {
            .source => 0,
            .imports => 1,
            .runs => 2,
            .launch => 3,
        };
    }

    fn tabFromIndex(index: usize) DetailTab {
        return switch (index) {
            1 => .imports,
            2 => .runs,
            3 => .launch,
            else => .source,
        };
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
            models.clearList(models.Workflow, self.allocator(), &priv.workflows);
            priv.workflows.deinit(self.allocator());
            if (priv.source_text) |text| {
                self.allocator().free(text);
                priv.source_text = null;
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
