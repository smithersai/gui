const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const models = @import("../models.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const ApprovalsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersApprovalsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        approvals: std.ArrayList(models.Approval) = .empty,
        decisions: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        show_history: bool = false,
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
        self.load() catch |err| {
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Approvals unavailable", @errorName(err));
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
        const header = vh.makeHeader("Approvals", null);
        const history = ui.textButton("History", false);
        _ = gtk.Button.signals.clicked.connect(history, *Self, historyClicked, self, .{});
        header.append(history.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh approvals");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const split = vh.splitPane(330);
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
        vh.setStatus(self.allocator(), self.private().detail, "security-high-symbolic", "Select an approval", "Approval payload and actions appear here.");
    }

    fn load(self: *Self) !void {
        const alloc = self.allocator();
        if (self.private().show_history) {
            const json = try vh.callJson(alloc, self.client(), "listRecentDecisions", &.{.{ .key = "limit", .value = .{ .integer = 50 } }});
            defer alloc.free(json);
            const parsed = try vh.parseItems(alloc, json, &.{ "decisions", "items", "data" }, .{
                .id = &.{"id"},
                .title = &.{ "gate", "nodeId", "node_id" },
                .subtitle = &.{ "runId", "run_id" },
                .status = &.{ "action", "decision", "status" },
                .body = &.{ "payload", "note", "reason" },
                .run_id = &.{ "runId", "run_id" },
                .node_id = &.{ "nodeId", "node_id" },
            });
            vh.clearItems(alloc, &self.private().decisions);
            self.private().decisions = parsed;
        } else {
            const json = try smithers.callJson(alloc, self.client(), "listPendingApprovals", "{}");
            defer alloc.free(json);
            const parsed = try models.parseApprovals(alloc, json);
            models.clearList(models.Approval, alloc, &self.private().approvals);
            self.private().approvals = parsed;
        }
        self.private().selected_index = null;
        try self.renderList();
        vh.setStatus(alloc, self.private().detail, "security-high-symbolic", "Select an approval", "Approval payload and actions appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        const list = self.private().list;
        ui.clearList(list);
        if (self.private().show_history) {
            if (self.private().decisions.items.len == 0) {
                list.append((try ui.row(alloc, "document-open-recent-symbolic", "No recent decisions", "Approved and denied gates appear here.")).as(gtk.Widget));
                return;
            }
            for (self.private().decisions.items, 0..) |item, index| {
                const row = try vh.itemRow(alloc, item, if (item.status != null and std.ascii.eqlIgnoreCase(item.status.?, "denied")) "dialog-error-symbolic" else "emblem-ok-symbolic");
                vh.setIndex(row.as(gobject.Object), index);
                list.append(row.as(gtk.Widget));
            }
            return;
        }
        if (self.private().approvals.items.len == 0) {
            list.append((try ui.row(alloc, "emblem-ok-symbolic", "No pending approvals", "Paused approval gates appear here.")).as(gtk.Widget));
            return;
        }
        for (self.private().approvals.items, 0..) |approval, index| {
            const title = approval.gate orelse approval.node_id;
            const subtitle = try std.fmt.allocPrint(alloc, "Run {s} - {s}", .{ approval.run_id, approval.status });
            defer alloc.free(subtitle);
            const row = try ui.row(alloc, "security-high-symbolic", title, subtitle);
            vh.setIndex(row.as(gobject.Object), index);
            list.append(row.as(gtk.Widget));
        }
    }

    fn renderDetail(self: *Self, index: usize) !void {
        const alloc = self.allocator();
        const detail = self.private().detail;
        ui.clearBox(detail);
        if (self.private().show_history) {
            if (index >= self.private().decisions.items.len) return;
            const item = self.private().decisions.items[index];
            const title_z = try alloc.dupeZ(u8, item.title);
            defer alloc.free(title_z);
            detail.append(ui.heading(title_z).as(gtk.Widget));
            try vh.detailRow(alloc, detail, "Run", item.run_id orelse item.subtitle);
            try vh.detailRow(alloc, detail, "Node", item.node_id);
            try vh.detailRow(alloc, detail, "Decision", item.status);
            try vh.detailRow(alloc, detail, "Payload", item.body);
            return;
        }
        if (index >= self.private().approvals.items.len) return;
        const approval = self.private().approvals.items[index];
        const title = approval.gate orelse approval.node_id;
        const title_z = try alloc.dupeZ(u8, title);
        defer alloc.free(title_z);
        detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, detail, "Run", approval.run_id);
        try vh.detailRow(alloc, detail, "Node", approval.node_id);
        try vh.detailRow(alloc, detail, "Status", approval.status);
        try vh.detailRow(alloc, detail, "Source", approval.source);
        const actions = gtk.Box.new(.horizontal, 8);
        const approve = ui.textButton("Approve", true);
        _ = gtk.Button.signals.clicked.connect(approve, *Self, approveClicked, self, .{});
        actions.append(approve.as(gtk.Widget));
        const deny = ui.textButton("Deny", false);
        deny.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(deny, *Self, denyClicked, self, .{});
        actions.append(deny.as(gtk.Widget));
        detail.append(actions.as(gtk.Widget));
    }

    fn complete(self: *Self, method: []const u8, label: []const u8) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().approvals.items.len) return;
        const approval = self.private().approvals.items[index];
        const alloc = self.allocator();
        const args = vh.jsonObject(alloc, &.{
            .{ .key = "runId", .value = .{ .string = approval.run_id } },
            .{ .key = "nodeId", .value = .{ .string = approval.node_id } },
            .{ .key = "iteration", .value = if (approval.iteration) |iteration| .{ .integer = iteration } else .null },
        }) catch return;
        defer alloc.free(args);
        const json = smithers.callJson(alloc, self.client(), method, args) catch |err| {
            self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("{s} {s}", .{ label, approval.gate orelse approval.node_id });
        self.refresh();
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn historyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().show_history = !self.private().show_history;
        self.refresh();
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.renderDetail(index) catch {};
    }

    fn approveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.complete("approveNode", "Approved");
    }

    fn denyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.complete("denyNode", "Denied");
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            models.clearList(models.Approval, self.allocator(), &priv.approvals);
            priv.approvals.deinit(self.allocator());
            vh.clearItems(self.allocator(), &priv.decisions);
            priv.decisions.deinit(self.allocator());
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
