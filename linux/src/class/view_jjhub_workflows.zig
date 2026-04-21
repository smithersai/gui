const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const JJHubWorkflowsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersJJHubWorkflowsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        ref_entry: *gtk.Entry = undefined,
        workflows: std.ArrayList(vh.Item) = .empty,
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
        self.load() catch |err| vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "JJHub workflows unavailable", @errorName(err));
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
        const header = vh.makeHeader("JJHub Workflows", null);
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh JJHub workflows");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));
        const split = vh.splitPane(350);
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
    }

    fn load(self: *Self) !void {
        const alloc = self.allocator();
        const json = try vh.callJson(alloc, self.client(), "listJJHubWorkflows", &.{.{ .key = "limit", .value = .{ .integer = 100 } }});
        defer alloc.free(json);
        const parsed = try vh.parseItems(alloc, json, &.{ "workflows", "items", "data" }, .{
            .id = &.{"id"},
            .title = &.{"name"},
            .subtitle = &.{"path"},
            .status = &.{ "is_active", "isActive" },
            .path = &.{"path"},
            .number = &.{"id"},
            .enabled = &.{ "is_active", "isActive" },
        });
        vh.clearItems(alloc, &self.private().workflows);
        self.private().workflows = parsed;
        self.private().selected_index = null;
        try self.renderList();
        vh.setStatus(alloc, self.private().detail, "media-playlist-shuffle-symbolic", "Select a workflow", "Trigger a JJHub workflow by ref.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        if (self.private().workflows.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "media-playlist-shuffle-symbolic", "No JJHub workflows", "Repository workflows appear here.")).as(gtk.Widget));
            return;
        }
        for (self.private().workflows.items, 0..) |workflow, index| {
            const row = try vh.itemRow(alloc, workflow, if (workflow.enabled orelse false) "emblem-ok-symbolic" else "process-stop-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
        }
    }

    fn renderDetail(self: *Self, index: usize) !void {
        if (index >= self.private().workflows.items.len) return;
        const alloc = self.allocator();
        const workflow = self.private().workflows.items[index];
        ui.clearBox(self.private().detail);
        const title_z = try alloc.dupeZ(u8, workflow.title);
        defer alloc.free(title_z);
        self.private().detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, self.private().detail, "ID", workflow.id);
        try vh.detailRow(alloc, self.private().detail, "Path", workflow.path);
        try vh.detailRow(alloc, self.private().detail, "Active", if (workflow.enabled orelse false) "true" else "false");
        self.private().ref_entry = gtk.Entry.new();
        self.private().ref_entry.setPlaceholderText("main");
        self.private().ref_entry.as(gtk.Editable).setText("main");
        self.private().detail.append(self.private().ref_entry.as(gtk.Widget));
        const run = ui.textButton("Run Workflow", true);
        _ = gtk.Button.signals.clicked.connect(run, *Self, triggerClicked, self, .{});
        self.private().detail.append(run.as(gtk.Widget));
    }

    fn trigger(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().workflows.items.len) return;
        const workflow = self.private().workflows.items[index];
        const id = workflow.number orelse std.fmt.parseInt(i64, workflow.id, 10) catch {
            self.private().window.showToast("Workflow ID is required");
            return;
        };
        const run_ref = std.mem.trim(u8, std.mem.span(self.private().ref_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "triggerJJHubWorkflow", &.{
            .{ .key = "workflowID", .value = .{ .integer = id } },
            .{ .key = "ref", .value = .{ .string = if (run_ref.len == 0) "main" else run_ref } },
        }) catch |err| {
            self.private().window.showToastFmt("Trigger failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Triggered {s}", .{workflow.title});
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.renderDetail(index) catch {};
    }

    fn triggerClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.trigger();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            vh.clearItems(self.allocator(), &priv.workflows);
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
