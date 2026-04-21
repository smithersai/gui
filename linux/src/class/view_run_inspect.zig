const std = @import("std");
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
        run_id: ?[]u8 = null,
        inspection: ?models.RunInspection = null,
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
        const cancel = ui.textButton("Cancel", false);
        cancel.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(cancel, *Self, cancelClicked, self, .{});
        actions.append(cancel.as(gtk.Widget));
        const rerun = ui.textButton("Rerun", false);
        _ = gtk.Button.signals.clicked.connect(rerun, *Self, rerunClicked, self, .{});
        actions.append(rerun.as(gtk.Widget));
        const hijack = ui.textButton("Hijack", false);
        _ = gtk.Button.signals.clicked.connect(hijack, *Self, hijackClicked, self, .{});
        actions.append(hijack.as(gtk.Widget));
        if (blockedTask(inspection.*)) |_| {
            const approve = ui.textButton("Approve", true);
            _ = gtk.Button.signals.clicked.connect(approve, *Self, approveClicked, self, .{});
            actions.append(approve.as(gtk.Widget));
            const deny = ui.textButton("Deny", false);
            deny.as(gtk.Widget).addCssClass("destructive-action");
            _ = gtk.Button.signals.clicked.connect(deny, *Self, denyClicked, self, .{});
            actions.append(deny.as(gtk.Widget));
        }
        body.append(actions.as(gtk.Widget));

        const group = gtk.Box.new(.vertical, 4);
        group.as(gtk.Widget).addCssClass("card");
        ui.margin(group.as(gtk.Widget), 12);
        try vh.detailRow(alloc, group, "Run ID", inspection.run.run_id);
        try vh.detailRow(alloc, group, "Workflow", inspection.run.workflow_path orelse inspection.run.workflow_name);
        try vh.detailRow(alloc, group, "Status", inspection.run.status);
        if (inspection.run.error_json) |err| try vh.detailRow(alloc, group, "Error", err);
        body.append(group.as(gtk.Widget));

        body.append(ui.heading("Tasks").as(gtk.Widget));
        const list = vh.listBox();
        if (inspection.tasks.items.len == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No tasks", "The run inspector returned no nodes.")).as(gtk.Widget));
        } else {
            for (inspection.tasks.items) |task| {
                const title_task = task.label orelse task.node_id;
                const subtitle = if (task.iteration) |iteration|
                    try std.fmt.allocPrint(alloc, "{s} - iteration {d}", .{ task.state, iteration })
                else
                    try alloc.dupe(u8, task.state);
                defer alloc.free(subtitle);
                list.append((try ui.row(alloc, taskIcon(task.state), title_task, subtitle)).as(gtk.Widget));
            }
        }
        body.append(list.as(gtk.Widget));
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

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.simpleRunAction("cancelRun", "Cancelled");
    }

    fn rerunClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.simpleRunAction("rerunRun", "Reran");
    }

    fn hijackClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.simpleRunAction("hijackRun", "Hijacked");
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
            if (priv.run_id) |run_id| {
                self.allocator().free(run_id);
                priv.run_id = null;
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
