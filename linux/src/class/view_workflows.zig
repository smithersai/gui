const std = @import("std");
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
        source_view: *gtk.TextView = undefined,
        workflows: std.ArrayList(models.Workflow) = .empty,
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

        const header = vh.makeHeader("Workflows", null);
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
        for (self.private().workflows.items, 0..) |workflow, index| {
            const path = workflow.relative_path orelse workflow.id;
            const subtitle = try std.fmt.allocPrint(alloc, "{s} - {s}", .{ path, workflow.status });
            defer alloc.free(subtitle);
            const row = try ui.row(alloc, "media-playlist-shuffle-symbolic", workflow.name, subtitle);
            vh.setIndex(row.as(gobject.Object), index);
            list.append(row.as(gtk.Widget));
        }
    }

    fn selectWorkflow(self: *Self, index: usize) void {
        if (index >= self.private().workflows.items.len) return;
        self.private().selected_index = index;
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

        const actions = gtk.Box.new(.horizontal, 8);
        const run = ui.textButton("Run", true);
        _ = gtk.Button.signals.clicked.connect(run, *Self, runClicked, self, .{});
        actions.append(run.as(gtk.Widget));
        const save = ui.textButton("Save Source", false);
        _ = gtk.Button.signals.clicked.connect(save, *Self, saveClicked, self, .{});
        actions.append(save.as(gtk.Widget));
        const doctor = ui.textButton("Doctor", false);
        _ = gtk.Button.signals.clicked.connect(doctor, *Self, doctorClicked, self, .{});
        actions.append(doctor.as(gtk.Widget));
        const graph = ui.textButton("Graph", false);
        _ = gtk.Button.signals.clicked.connect(graph, *Self, graphClicked, self, .{});
        actions.append(graph.as(gtk.Widget));
        detail.append(actions.as(gtk.Widget));

        const source_title = ui.heading("Source");
        detail.append(source_title.as(gtk.Widget));
        self.private().source_view = vh.textView(true);
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
        try vh.setTextViewText(alloc, self.private().source_view, source);
        const source_scroll = ui.scrolled(self.private().source_view.as(gtk.Widget));
        source_scroll.as(gtk.Widget).setSizeRequest(-1, 320);
        detail.append(source_scroll.as(gtk.Widget));
    }

    fn selectedWorkflow(self: *Self) ?models.Workflow {
        const index = self.private().selected_index orelse return null;
        if (index >= self.private().workflows.items.len) return null;
        return self.private().workflows.items[index];
    }

    fn runSelected(self: *Self) void {
        const workflow = self.selectedWorkflow() orelse return;
        const alloc = self.allocator();
        const path = workflow.relative_path orelse workflow.id;
        const args = vh.jsonObject(alloc, &.{.{ .key = "workflowPath", .value = .{ .string = path } }}) catch return;
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), "runWorkflow", args) catch |err| {
            self.private().window.showToastFmt("Workflow launch failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Launched {s}", .{workflow.name});
        self.private().window.showNav(.runs);
    }

    fn saveSelected(self: *Self) void {
        const workflow = self.selectedWorkflow() orelse return;
        const alloc = self.allocator();
        const path = workflow.relative_path orelse workflow.id;
        const source = vh.getTextViewText(alloc, self.private().source_view) catch return;
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
    }

    fn showWorkflowCall(self: *Self, method: []const u8, title: []const u8) void {
        const workflow = self.selectedWorkflow() orelse return;
        const alloc = self.allocator();
        const path = workflow.relative_path orelse workflow.id;
        const args = vh.jsonObject(alloc, &.{.{ .key = "workflowPath", .value = .{ .string = path } }}) catch return;
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), method, args) catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ title, err });
            return;
        };
        defer alloc.free(json);
        const text = vh.parseStringResult(alloc, json) catch alloc.dupe(u8, json) catch return;
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

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.selectWorkflow(index);
    }

    fn runClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.runSelected();
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

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            models.clearList(models.Workflow, self.allocator(), &priv.workflows);
            priv.workflows.deinit(self.allocator());
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
