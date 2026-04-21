const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const TriggersView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersTriggersView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        pattern_entry: *gtk.Entry = undefined,
        workflow_entry: *gtk.Entry = undefined,
        items: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        create_visible: bool = false,
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
        self.load() catch |err| vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Triggers unavailable", @errorName(err));
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
        const header = vh.makeHeader("Triggers", null);
        const add = ui.iconButton("list-add-symbolic", "New trigger");
        _ = gtk.Button.signals.clicked.connect(add, *Self, newClicked, self, .{});
        header.append(add.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh triggers");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));
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
    }

    fn load(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.client(), "listCrons", "{}");
        defer alloc.free(json);
        const parsed = try vh.parseItems(alloc, json, &.{ "crons", "items", "data" }, .{
            .id = &.{ "id", "cronId", "cron_id", "scheduleId", "schedule_id" },
            .title = &.{ "pattern", "cron", "expression", "schedule" },
            .subtitle = &.{ "workflowPath", "workflow_path", "entryFile", "path" },
            .status = &.{ "enabled", "is_enabled", "errorJson", "error_json" },
            .path = &.{ "workflowPath", "workflow_path", "entryFile", "path" },
            .enabled = &.{ "enabled", "is_enabled" },
        });
        vh.clearItems(alloc, &self.private().items);
        self.private().items = parsed;
        self.private().selected_index = null;
        try self.renderList();
        if (self.private().create_visible) try self.renderCreate() else vh.setStatus(alloc, self.private().detail, "appointment-new-symbolic", "Select a trigger", "Toggle, inspect, or delete cron schedules.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        if (self.private().items.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "appointment-new-symbolic", "No triggers found", "Create one with the plus button.")).as(gtk.Widget));
            return;
        }
        for (self.private().items.items, 0..) |item, index| {
            const row = try vh.itemRow(alloc, item, if (item.enabled orelse true) "emblem-ok-symbolic" else "process-stop-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
        }
    }

    fn renderCreate(self: *Self) !void {
        ui.clearBox(self.private().detail);
        self.private().detail.append(ui.heading("New Trigger").as(gtk.Widget));
        self.private().pattern_entry = gtk.Entry.new();
        self.private().pattern_entry.setPlaceholderText("0 9 * * 1-5");
        self.private().detail.append(self.private().pattern_entry.as(gtk.Widget));
        self.private().workflow_entry = gtk.Entry.new();
        self.private().workflow_entry.setPlaceholderText(".smithers/workflows/nightly.tsx");
        self.private().detail.append(self.private().workflow_entry.as(gtk.Widget));
        const create = ui.textButton("Create Trigger", true);
        _ = gtk.Button.signals.clicked.connect(create, *Self, createClicked, self, .{});
        self.private().detail.append(create.as(gtk.Widget));
    }

    fn renderDetail(self: *Self, index: usize) !void {
        if (index >= self.private().items.items.len) return;
        const alloc = self.allocator();
        const item = self.private().items.items[index];
        ui.clearBox(self.private().detail);
        const title_z = try alloc.dupeZ(u8, item.title);
        defer alloc.free(title_z);
        self.private().detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, self.private().detail, "Workflow", item.path);
        try vh.detailRow(alloc, self.private().detail, "Enabled", if (item.enabled orelse true) "true" else "false");
        try vh.detailRow(alloc, self.private().detail, "Status", item.status);
        const actions = gtk.Box.new(.horizontal, 8);
        const toggle = ui.textButton("Toggle", true);
        _ = gtk.Button.signals.clicked.connect(toggle, *Self, toggleClicked, self, .{});
        actions.append(toggle.as(gtk.Widget));
        const run_now = ui.textButton("Run Now", false);
        _ = gtk.Button.signals.clicked.connect(run_now, *Self, runNowClicked, self, .{});
        actions.append(run_now.as(gtk.Widget));
        const delete = ui.textButton("Delete", false);
        delete.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(delete, *Self, deleteClicked, self, .{});
        actions.append(delete.as(gtk.Widget));
        self.private().detail.append(actions.as(gtk.Widget));
    }

    fn createTrigger(self: *Self) void {
        const pattern = std.mem.trim(u8, std.mem.span(self.private().pattern_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        const workflow = std.mem.trim(u8, std.mem.span(self.private().workflow_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (pattern.len == 0 or workflow.len == 0) {
            self.private().window.showToast("Pattern and workflow path are required");
            return;
        }
        if (!isValidCronPattern(pattern)) {
            self.private().window.showToast("Cron pattern must have 5 fields");
            return;
        }
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "createCron", &.{
            .{ .key = "pattern", .value = .{ .string = pattern } },
            .{ .key = "workflowPath", .value = .{ .string = workflow } },
        }) catch |err| {
            self.private().window.showToastFmt("Create trigger failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToast("Trigger created");
        self.private().create_visible = false;
        self.refresh();
    }

    fn triggerAction(self: *Self, method: []const u8, label: []const u8) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().items.items.len) return;
        const item = self.private().items.items[index];
        const alloc = self.allocator();
        const json = if (std.mem.eql(u8, method, "toggleCron"))
            vh.callJson(alloc, self.client(), method, &.{
                .{ .key = "cronID", .value = .{ .string = item.id } },
                .{ .key = "enabled", .value = .{ .boolean = !(item.enabled orelse true) } },
            })
        else
            vh.callJson(alloc, self.client(), method, &.{.{ .key = "cronID", .value = .{ .string = item.id } }});
        const result = json catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(result);
        self.private().window.showToastFmt("{s} {s}", .{ label, item.id });
        self.refresh();
    }

    fn isValidCronPattern(pattern: []const u8) bool {
        var parts = std.mem.tokenizeAny(u8, pattern, " \t");
        var count: usize = 0;
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            count += 1;
        }
        return count == 5;
    }

    fn newClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().create_visible = !self.private().create_visible;
        if (self.private().create_visible) self.renderCreate() catch {} else self.refresh();
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.private().create_visible = false;
        self.renderDetail(index) catch {};
    }

    fn createClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.createTrigger();
    }

    fn toggleClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.triggerAction("toggleCron", "Updated");
    }

    fn deleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.triggerAction("deleteCron", "Deleted");
    }

    fn runNowClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.triggerAction("runCronNow", "Started");
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            vh.clearItems(self.allocator(), &priv.items);
            priv.items.deinit(self.allocator());
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
