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
    const ApprovalFilter = enum { pending, resolved, all };
    const ApprovalRowKind = enum { pending, decision };
    const ApprovalRowRef = struct { kind: ApprovalRowKind, index: usize };

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
        reason_entry: *gtk.Entry = undefined,
        deny_note: ?*gtk.TextView = null,
        approvals: std.ArrayList(models.Approval) = .empty,
        decisions: std.ArrayList(vh.Item) = .empty,
        visible_rows: std.ArrayList(ApprovalRowRef) = .empty,
        selected: std.ArrayList(bool) = .empty,
        selected_index: ?usize = null,
        filter: ApprovalFilter = .pending,
        sort_oldest: bool = true,
        group_by_run: bool = false,
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
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>r", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "a", self, shortcutApprove);
        vh.installShortcut(Self, root.as(gtk.Widget), "d", self, shortcutDeny);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Shift>a", self, shortcutBatchApprove);
        const header = vh.makeHeader("Approvals", null);
        inline for (.{ "Pending", "Resolved", "All" }) |label| {
            const button = ui.textButton(label, std.mem.eql(u8, label, "Pending"));
            button.as(gobject.Object).setData("smithers-approval-filter", @constCast(label.ptr));
            _ = gtk.Button.signals.clicked.connect(button, *Self, filterClicked, self, .{});
            header.append(button.as(gtk.Widget));
        }
        const sort = ui.textButton("Oldest First", false);
        _ = gtk.Button.signals.clicked.connect(sort, *Self, sortClicked, self, .{});
        header.append(sort.as(gtk.Widget));
        const group = ui.textButton("Group by Run", false);
        _ = gtk.Button.signals.clicked.connect(group, *Self, groupClicked, self, .{});
        header.append(group.as(gtk.Widget));
        self.private().reason_entry = gtk.Entry.new();
        self.private().reason_entry.setPlaceholderText("Shared reason/note");
        self.private().reason_entry.as(gtk.Widget).setSizeRequest(180, -1);
        header.append(self.private().reason_entry.as(gtk.Widget));
        const batch_approve = ui.textButton("Approve Selected", true);
        _ = gtk.Button.signals.clicked.connect(batch_approve, *Self, batchApproveClicked, self, .{});
        header.append(batch_approve.as(gtk.Widget));
        const batch_deny = ui.textButton("Deny Selected", false);
        batch_deny.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(batch_deny, *Self, batchDenyClicked, self, .{});
        header.append(batch_deny.as(gtk.Widget));
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
        const approvals_json = try smithers.callJson(alloc, self.client(), "listPendingApprovals", "{}");
        defer alloc.free(approvals_json);
        const approvals = try models.parseApprovals(alloc, approvals_json);
        models.clearList(models.Approval, alloc, &self.private().approvals);
        self.private().approvals = approvals;
        self.private().selected.clearRetainingCapacity();
        try self.private().selected.appendNTimes(alloc, false, self.private().approvals.items.len);

        const decisions_json = try vh.callJson(alloc, self.client(), "listRecentDecisions", &.{.{ .key = "limit", .value = .{ .integer = 100 } }});
        defer alloc.free(decisions_json);
        const decisions = try vh.parseItems(alloc, decisions_json, &.{ "decisions", "items", "data" }, .{
            .id = &.{"id"},
            .title = &.{ "gate", "nodeId", "node_id" },
            .subtitle = &.{ "runId", "run_id" },
            .status = &.{ "action", "decision", "status" },
            .body = &.{ "payload", "note", "reason" },
            .run_id = &.{ "runId", "run_id" },
            .node_id = &.{ "nodeId", "node_id" },
            .number = &.{ "resolvedAt", "resolvedAtMs", "resolved_at", "resolved_at_ms", "decidedAt", "decidedAtMs", "decided_at", "decided_at_ms", "requestedAt", "requestedAtMs", "requested_at", "requested_at_ms" },
        });
        vh.clearItems(alloc, &self.private().decisions);
        self.private().decisions = decisions;
        self.private().selected_index = null;
        try self.renderList();
        vh.setStatus(alloc, self.private().detail, "security-high-symbolic", "Select an approval", "Approval payload and actions appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        const list = self.private().list;
        ui.clearList(list);
        self.private().visible_rows.clearRetainingCapacity();
        if (self.private().filter == .pending or self.private().filter == .all) {
            for (self.private().approvals.items, 0..) |_, index| {
                try self.private().visible_rows.append(alloc, .{ .kind = .pending, .index = index });
            }
        }
        if (self.private().filter == .resolved or self.private().filter == .all) {
            for (self.private().decisions.items, 0..) |_, index| {
                try self.private().visible_rows.append(alloc, .{ .kind = .decision, .index = index });
            }
        }
        std.mem.sort(ApprovalRowRef, self.private().visible_rows.items, self, approvalRowLess);

        if (self.private().visible_rows.items.len == 0) {
            const title = switch (self.private().filter) {
                .pending => "No pending approvals",
                .resolved => "No recent decisions",
                .all => "No approvals",
            };
            list.append((try ui.row(alloc, "emblem-ok-symbolic", title, "Approval gates appear here.")).as(gtk.Widget));
            return;
        }

        var last_run: ?[]const u8 = null;
        for (self.private().visible_rows.items, 0..) |row_ref, visible_index| {
            const run = self.rowRun(row_ref);
            if (self.private().group_by_run and (last_run == null or !std.mem.eql(u8, last_run.?, run))) {
                list.append((try groupRow(alloc, run)).as(gtk.Widget));
                last_run = run;
            }
            switch (row_ref.kind) {
                .pending => {
                    const approval = self.private().approvals.items[row_ref.index];
                    const title = approval.gate orelse approval.node_id;
                    const subtitle = try std.fmt.allocPrint(alloc, "Run {s} - {s}", .{ approval.run_id, approval.status });
                    defer alloc.free(subtitle);
                    const row = gtk.ListBoxRow.new();
                    row.setActivatable(1);
                    const row_box = gtk.Box.new(.horizontal, 10);
                    ui.margin(row_box.as(gtk.Widget), 10);

                    const check = gtk.CheckButton.new();
                    check.setActive(if (row_ref.index < self.private().selected.items.len and self.private().selected.items[row_ref.index]) 1 else 0);
                    vh.setIndex(check.as(gobject.Object), row_ref.index);
                    _ = gtk.CheckButton.signals.toggled.connect(check, *Self, selectionToggled, self, .{});
                    row_box.append(check.as(gtk.Widget));

                    const text_box = gtk.Box.new(.vertical, 2);
                    text_box.as(gtk.Widget).setHexpand(1);
                    const title_z = try alloc.dupeZ(u8, title);
                    defer alloc.free(title_z);
                    const title_label = ui.label(title_z, "heading");
                    title_label.setWrap(0);
                    title_label.setEllipsize(.end);
                    text_box.append(title_label.as(gtk.Widget));
                    const subtitle_z = try alloc.dupeZ(u8, subtitle);
                    defer alloc.free(subtitle_z);
                    text_box.append(ui.dim(subtitle_z).as(gtk.Widget));
                    row_box.append(text_box.as(gtk.Widget));
                    row.setChild(row_box.as(gtk.Widget));
                    vh.setIndex(row.as(gobject.Object), visible_index);
                    list.append(row.as(gtk.Widget));
                },
                .decision => {
                    const item = self.private().decisions.items[row_ref.index];
                    const row = try vh.itemRow(alloc, item, if (item.status != null and std.ascii.eqlIgnoreCase(item.status.?, "denied")) "dialog-error-symbolic" else "emblem-ok-symbolic");
                    vh.setIndex(row.as(gobject.Object), visible_index);
                    list.append(row.as(gtk.Widget));
                },
            }
        }
    }

    fn renderDetail(self: *Self, visible_index: usize) !void {
        const alloc = self.allocator();
        const detail = self.private().detail;
        ui.clearBox(detail);
        self.private().deny_note = null;
        if (visible_index >= self.private().visible_rows.items.len) return;
        const row_ref = self.private().visible_rows.items[visible_index];
        if (row_ref.kind == .decision) {
            if (row_ref.index >= self.private().decisions.items.len) return;
            const item = self.private().decisions.items[row_ref.index];
            const title_z = try alloc.dupeZ(u8, item.title);
            defer alloc.free(title_z);
            detail.append(ui.heading(title_z).as(gtk.Widget));
            try vh.detailRow(alloc, detail, "Run", item.run_id orelse item.subtitle);
            try vh.detailRow(alloc, detail, "Node", item.node_id);
            try vh.detailRow(alloc, detail, "Decision", item.status);
            try vh.detailRow(alloc, detail, "Payload", item.body);
            try vh.detailRow(alloc, detail, "Raw", item.raw_json);
            return;
        }
        const index = row_ref.index;
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
        vh.addSectionTitle(detail, "Decision Reason");
        const deny_note = vh.textView(true);
        self.private().deny_note = deny_note;
        try vh.setTextViewText(alloc, deny_note, "");
        const note_scroll = ui.scrolled(deny_note.as(gtk.Widget));
        note_scroll.as(gtk.Widget).setSizeRequest(-1, 110);
        detail.append(note_scroll.as(gtk.Widget));
        const actions = vh.actionBar();
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
        const visible_index = self.private().selected_index orelse return;
        if (visible_index >= self.private().visible_rows.items.len) return;
        const row_ref = self.private().visible_rows.items[visible_index];
        if (row_ref.kind != .pending) {
            self.private().window.showToast("Select a pending approval");
            return;
        }
        const index = row_ref.index;
        if (index >= self.private().approvals.items.len) return;
        const approval = self.private().approvals.items[index];
        const alloc = self.allocator();
        const shared_note = alloc.dupe(u8, vh.trimEntryText(self.private().reason_entry)) catch return;
        defer alloc.free(shared_note);
        var detail_note: ?[]u8 = null;
        defer if (detail_note) |note| alloc.free(note);
        if (std.mem.eql(u8, method, "denyNode") and std.mem.trim(u8, shared_note, &std.ascii.whitespace).len == 0) {
            if (self.private().deny_note) |view| {
                detail_note = vh.getTextViewText(alloc, view) catch return;
            }
        }
        const candidate_note = if (std.mem.trim(u8, shared_note, &std.ascii.whitespace).len > 0) shared_note else (detail_note orelse shared_note);
        const trimmed_note = std.mem.trim(u8, candidate_note, &std.ascii.whitespace);
        if (std.mem.eql(u8, method, "denyNode") and trimmed_note.len == 0) {
            self.private().window.showToast("A deny reason is required");
            return;
        }
        const args = vh.jsonObject(alloc, &.{
            .{ .key = "runId", .value = .{ .string = approval.run_id } },
            .{ .key = "nodeId", .value = .{ .string = approval.node_id } },
            .{ .key = "iteration", .value = if (approval.iteration) |iteration| .{ .integer = iteration } else .null },
            .{ .key = if (std.mem.eql(u8, method, "denyNode")) "reason" else "note", .value = .{ .string = trimmed_note } },
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

    fn completeSelected(self: *Self, method: []const u8, label: []const u8, requires_reason: bool) void {
        const alloc = self.allocator();
        const reason = alloc.dupe(u8, vh.trimEntryText(self.private().reason_entry)) catch return;
        defer alloc.free(reason);
        const trimmed_reason = std.mem.trim(u8, reason, &std.ascii.whitespace);
        if (requires_reason and trimmed_reason.len == 0) {
            self.private().window.showToast("A shared deny reason is required");
            return;
        }
        var completed: usize = 0;
        for (self.private().approvals.items, 0..) |approval, index| {
            if (index >= self.private().selected.items.len or !self.private().selected.items[index]) continue;
            const args = vh.jsonObject(alloc, &.{
                .{ .key = "runId", .value = .{ .string = approval.run_id } },
                .{ .key = "nodeId", .value = .{ .string = approval.node_id } },
                .{ .key = "iteration", .value = if (approval.iteration) |iteration| .{ .integer = iteration } else .null },
                .{ .key = if (std.mem.eql(u8, method, "denyNode")) "reason" else "note", .value = .{ .string = trimmed_reason } },
            }) catch continue;
            defer alloc.free(args);
            const json = smithers.callJson(alloc, self.client(), method, args) catch continue;
            alloc.free(json);
            completed += 1;
        }
        if (completed == 0) {
            self.private().window.showToast("Select pending approvals first");
            return;
        }
        self.private().window.showToastFmt("{s} {d} approval(s)", .{ label, completed });
        self.refresh();
    }

    fn approvalRowLess(self: *Self, lhs: ApprovalRowRef, rhs: ApprovalRowRef) bool {
        if (self.private().group_by_run) {
            const run_order = std.mem.order(u8, self.rowRun(lhs), self.rowRun(rhs));
            if (run_order != .eq) return run_order == .lt;
        }
        const lhs_time = self.rowTime(lhs);
        const rhs_time = self.rowTime(rhs);
        if (lhs_time != rhs_time) return if (self.private().sort_oldest) lhs_time < rhs_time else lhs_time > rhs_time;
        const lhs_title = self.rowTitle(lhs);
        const rhs_title = self.rowTitle(rhs);
        return std.mem.order(u8, lhs_title, rhs_title) == .lt;
    }

    fn rowRun(self: *Self, row_ref: ApprovalRowRef) []const u8 {
        return switch (row_ref.kind) {
            .pending => if (row_ref.index < self.private().approvals.items.len) self.private().approvals.items[row_ref.index].run_id else "",
            .decision => if (row_ref.index < self.private().decisions.items.len) self.private().decisions.items[row_ref.index].run_id orelse self.private().decisions.items[row_ref.index].subtitle orelse "" else "",
        };
    }

    fn rowTitle(self: *Self, row_ref: ApprovalRowRef) []const u8 {
        return switch (row_ref.kind) {
            .pending => if (row_ref.index < self.private().approvals.items.len) self.private().approvals.items[row_ref.index].gate orelse self.private().approvals.items[row_ref.index].node_id else "",
            .decision => if (row_ref.index < self.private().decisions.items.len) self.private().decisions.items[row_ref.index].title else "",
        };
    }

    fn rowTime(self: *Self, row_ref: ApprovalRowRef) i64 {
        return switch (row_ref.kind) {
            .pending => if (row_ref.index < self.private().approvals.items.len) self.private().approvals.items[row_ref.index].requested_at orelse 0 else 0,
            .decision => if (row_ref.index < self.private().decisions.items.len) self.private().decisions.items[row_ref.index].number orelse 0 else 0,
        };
    }

    fn groupRow(alloc: std.mem.Allocator, run_id: []const u8) !*gtk.ListBoxRow {
        const title = try std.fmt.allocPrint(alloc, "Run {s}", .{run_id});
        defer alloc.free(title);
        const row = try ui.row(alloc, "folder-symbolic", title, null);
        const lb_row = row.as(gtk.ListBoxRow);
        lb_row.setActivatable(0);
        lb_row.setSelectable(0);
        return lb_row;
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn filterClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-approval-filter") orelse return;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        self.private().filter = if (std.mem.eql(u8, text, "Resolved")) .resolved else if (std.mem.eql(u8, text, "All")) .all else .pending;
        self.private().selected_index = null;
        self.renderList() catch {};
        vh.setStatus(self.allocator(), self.private().detail, "security-high-symbolic", "Select an approval", "Approval payload and actions appear here.");
    }

    fn sortClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().sort_oldest = !self.private().sort_oldest;
        self.renderList() catch {};
        self.private().window.showToast(if (self.private().sort_oldest) "Approvals sorted oldest first" else "Approvals sorted newest first");
    }

    fn groupClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().group_by_run = !self.private().group_by_run;
        self.renderList() catch {};
        self.private().window.showToast(if (self.private().group_by_run) "Approvals grouped by run" else "Approval grouping disabled");
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.renderDetail(index) catch {};
    }

    fn selectionToggled(button: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const index = vh.getIndex(button.as(gobject.Object)) orelse return;
        if (index >= self.private().selected.items.len) return;
        self.private().selected.items[index] = button.getActive() != 0;
    }

    fn approveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.complete("approveNode", "Approved");
    }

    fn denyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.complete("denyNode", "Denied");
    }

    fn batchApproveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.completeSelected("approveNode", "Approved", false);
    }

    fn batchDenyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.completeSelected("denyNode", "Denied", true);
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn shortcutApprove(self: *Self) void {
        self.complete("approveNode", "Approved");
    }

    fn shortcutDeny(self: *Self) void {
        self.complete("denyNode", "Denied");
    }

    fn shortcutBatchApprove(self: *Self) void {
        self.completeSelected("approveNode", "Approved", false);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            models.clearList(models.Approval, self.allocator(), &priv.approvals);
            priv.approvals.deinit(self.allocator());
            vh.clearItems(self.allocator(), &priv.decisions);
            priv.decisions.deinit(self.allocator());
            priv.visible_rows.deinit(self.allocator());
            priv.selected.deinit(self.allocator());
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
