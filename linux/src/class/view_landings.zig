const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;
const UnifiedDiffView = @import("diff.zig").UnifiedDiffView;
const logx = @import("../log.zig");
const log = std.log.scoped(.smithers_gtk_view_landings);

pub const LandingsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLandingsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        title_entry: *gtk.Entry = undefined,
        target_entry: *gtk.Entry = undefined,
        body_view: *gtk.TextView = undefined,
        review_view: *gtk.TextView = undefined,
        items: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        state_filter: ?[]const u8 = null,
        pending_land_number: ?i64 = null,
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
        logx.event(log, "refresh_start", "view=landings state={s}", .{self.private().state_filter orelse "all"});
        const t = logx.startTimer();
        self.load() catch |err| {
            logx.catchWarn(log, "refresh load", err);
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Landings unavailable", @errorName(err));
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
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>r", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "F5", self, shortcutRefresh);
        const header = vh.makeHeader("Landings", null);
        inline for (.{ "All", "Open", "Draft", "Merged", "Closed" }) |label| {
            const button = ui.textButton(label, false);
            button.as(gobject.Object).setData("smithers-landing-filter", @constCast(label.ptr));
            _ = gtk.Button.signals.clicked.connect(button, *Self, filterClicked, self, .{});
            header.append(button.as(gtk.Widget));
        }
        const add = ui.iconButton("list-add-symbolic", "New landing");
        _ = gtk.Button.signals.clicked.connect(add, *Self, newClicked, self, .{});
        header.append(add.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh landings");
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
        const detail_scroll = ui.scrolled(self.private().detail.as(gtk.Widget));
        detail_scroll.as(gtk.Widget).setVexpand(1);
        split.right.append(detail_scroll.as(gtk.Widget));
        root.append(split.root.as(gtk.Widget));
    }

    fn load(self: *Self) !void {
        const alloc = self.allocator();
        const rpc_t = logx.startTimer();
        const json = try vh.callJson(alloc, self.client(), "listLandings", &.{.{ .key = "state", .value = .{ .optional_string = self.private().state_filter } }});
        logx.endTimerDebug(log, "rpc=listLandings", rpc_t);
        defer alloc.free(json);
        const parsed = try vh.parseItems(alloc, json, &.{ "landings", "items", "data" }, .{
            .id = &.{ "id", "number", "title" },
            .title = &.{"title"},
            .subtitle = &.{ "targetBranch", "target_bookmark", "author" },
            .status = &.{ "state", "reviewStatus", "review_status" },
            .body = &.{ "description", "body" },
            .number = &.{"number"},
        });
        vh.clearItems(alloc, &self.private().items);
        self.private().items = parsed;
        self.private().selected_index = null;
        try self.renderList();
        logx.event(log, "refresh_done", "view=landings rows={d}", .{self.private().items.items.len});
        if (self.private().create_visible) try self.renderCreate() else vh.setStatus(alloc, self.private().detail, "emblem-documents-symbolic", "Select a landing", "Landing details, checks, and review actions appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        if (self.private().items.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "emblem-documents-symbolic", "No landings found", "Create one with the plus button.")).as(gtk.Widget));
            return;
        }
        for (self.private().items.items, 0..) |item, index| {
            const row = try vh.itemRow(alloc, item, "emblem-documents-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
        }
    }

    fn renderCreate(self: *Self) !void {
        ui.clearBox(self.private().detail);
        self.private().detail.append(ui.heading("New Landing").as(gtk.Widget));
        self.private().title_entry = gtk.Entry.new();
        self.private().title_entry.setPlaceholderText("Title");
        self.private().detail.append(self.private().title_entry.as(gtk.Widget));
        self.private().target_entry = gtk.Entry.new();
        self.private().target_entry.setPlaceholderText("Target bookmark");
        self.private().detail.append(self.private().target_entry.as(gtk.Widget));
        self.private().body_view = vh.textView(true);
        const scroll = ui.scrolled(self.private().body_view.as(gtk.Widget));
        scroll.as(gtk.Widget).setSizeRequest(-1, 220);
        self.private().detail.append(scroll.as(gtk.Widget));
        const create = ui.textButton("Create Landing", true);
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
        const number_text = if (item.number) |n| try std.fmt.allocPrint(alloc, "#{d}", .{n}) else null;
        defer if (number_text) |text| alloc.free(text);
        try vh.detailRow(alloc, self.private().detail, "Number", number_text);
        try vh.detailRow(alloc, self.private().detail, "State", item.status);
        try vh.detailRow(alloc, self.private().detail, "Target", item.subtitle);
        try vh.detailRow(alloc, self.private().detail, "Description", item.body);
        const pr_url = vh.rawJsonFieldString(alloc, item.raw_json, &.{ "pullRequestUrl", "pull_request_url", "prUrl", "pr_url", "html_url", "web_url", "url", "permalink" }) catch null;
        defer if (pr_url) |value| alloc.free(value);
        try vh.detailRow(alloc, self.private().detail, "PR", pr_url);
        const actions = gtk.Box.new(.horizontal, 8);
        inline for (.{ "Diff", "Checks", "Open PR", "Land", "Approve", "Request Changes", "Comment" }) |label| {
            const button = ui.textButton(label, std.mem.eql(u8, label, "Approve"));
            if (std.mem.eql(u8, label, "Land") or std.mem.eql(u8, label, "Request Changes")) button.as(gtk.Widget).addCssClass("destructive-action");
            _ = gtk.Button.signals.clicked.connect(button, *Self, actionClicked, self, .{});
            button.as(gobject.Object).setData("smithers-landing-action", @constCast(label.ptr));
            actions.append(button.as(gtk.Widget));
        }
        self.private().detail.append(actions.as(gtk.Widget));
        self.private().review_view = vh.textView(true);
        vh.setTextViewText(alloc, self.private().review_view, "") catch {};
        const review_scroll = ui.scrolled(self.private().review_view.as(gtk.Widget));
        review_scroll.as(gtk.Widget).setSizeRequest(-1, 120);
        self.private().detail.append(review_scroll.as(gtk.Widget));
    }

    fn createLanding(self: *Self) void {
        const alloc = self.allocator();
        const title = std.mem.trim(u8, std.mem.span(self.private().title_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        const target = std.mem.trim(u8, std.mem.span(self.private().target_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        const body = vh.getTextViewText(alloc, self.private().body_view) catch return;
        defer alloc.free(body);
        if (title.len == 0) {
            self.private().window.showToast("Landing title is required");
            return;
        }
        const json = vh.callJson(alloc, self.client(), "createLanding", &.{
            .{ .key = "title", .value = .{ .string = title } },
            .{ .key = "body", .value = .{ .string = body } },
            .{ .key = "target", .value = .{ .optional_string = if (target.len == 0) null else target } },
            .{ .key = "stack", .value = .{ .boolean = true } },
        }) catch |err| {
            logx.catchWarn(log, "rpc=createLanding", err);
            self.private().window.showToastFmt("Create landing failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Created landing {s}", .{title});
        self.private().create_visible = false;
        self.refresh();
    }

    fn landingAction(self: *Self, label: []const u8) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().items.items.len) return;
        const item = self.private().items.items[index];
        const alloc = self.allocator();
        if (std.mem.eql(u8, label, "Open PR")) {
            self.openLandingPR(item);
            return;
        }
        const number = item.number orelse {
            self.private().window.showToast("Landing number is required");
            return;
        };
        if (std.mem.eql(u8, label, "Diff") or std.mem.eql(u8, label, "Checks")) {
            const method = if (std.mem.eql(u8, label, "Diff")) "landingDiff" else "landingChecks";
            const rpc_t = logx.startTimer();
            const json = vh.callJson(alloc, self.client(), method, &.{.{ .key = "number", .value = .{ .integer = number } }}) catch |err| {
                logx.catchWarn(log, method, err);
                self.private().window.showToastFmt("{s} failed: {}", .{ label, err });
                return;
            };
            logx.endTimerDebug(log, "rpc=landingDiffOrChecks", rpc_t);
            defer alloc.free(json);
            const text = vh.parseStringResult(alloc, json) catch |err1| blk: {
                logx.catchDebug(log, "parseStringResult", err1);
                break :blk alloc.dupe(u8, json) catch |err2| {
                    logx.catchWarn(log, "dupe json", err2);
                    return;
                };
            };
            defer alloc.free(text);
            if (std.mem.eql(u8, label, "Diff")) {
                const diff = UnifiedDiffView.new(alloc, text, "landing.diff") catch |err| {
                    logx.catchWarn(log, "UnifiedDiffView.new", err);
                    return;
                };
                diff.as(gtk.Widget).setSizeRequest(-1, 360);
                self.private().detail.append(diff.as(gtk.Widget));
            } else {
                vh.appendJsonViewer(alloc, self.private().detail, "Checks", text, 300) catch |err| {
                    logx.catchWarn(log, "appendJsonViewer", err);
                    return;
                };
            }
            return;
        }
        if (std.mem.eql(u8, label, "Land")) {
            self.confirmLand(number);
            return;
        }
        const body = vh.getTextViewText(alloc, self.private().review_view) catch |err| {
            logx.catchWarn(log, "getTextViewText", err);
            return;
        };
        defer alloc.free(body);
        const action = if (std.mem.eql(u8, label, "Approve")) "approve" else if (std.mem.eql(u8, label, "Request Changes")) "request_changes" else "comment";
        const rpc_t = logx.startTimer();
        const json = vh.callJson(alloc, self.client(), "reviewLanding", &.{
            .{ .key = "number", .value = .{ .integer = number } },
            .{ .key = "action", .value = .{ .string = action } },
            .{ .key = "body", .value = .{ .string = body } },
        }) catch |err| {
            logx.catchWarn(log, "rpc=reviewLanding", err);
            self.private().window.showToastFmt("Review failed: {}", .{err});
            return;
        };
        logx.endTimerDebug(log, "rpc=reviewLanding", rpc_t);
        defer alloc.free(json);
        self.private().window.showToastFmt("Reviewed #{d}", .{number});
        self.refresh();
    }

    fn refreshLandingDetail(self: *Self, index: usize) void {
        if (index >= self.private().items.items.len) return;
        const number = self.private().items.items[index].number orelse return;
        const alloc = self.allocator();
        const rpc_t = logx.startTimer();
        const json = vh.callJson(alloc, self.client(), "getLanding", &.{.{ .key = "number", .value = .{ .integer = number } }}) catch |err| {
            logx.catchWarn(log, "rpc=getLanding", err);
            return;
        };
        logx.endTimerDebug(log, "rpc=getLanding", rpc_t);
        defer alloc.free(json);
        var parsed = vh.parseItems(alloc, json, &.{ "landing", "landings", "items", "data" }, .{
            .id = &.{ "id", "number", "title" },
            .title = &.{"title"},
            .subtitle = &.{ "targetBranch", "target_bookmark", "targetBookmark", "author" },
            .status = &.{ "state", "reviewStatus", "review_status" },
            .body = &.{ "description", "body" },
            .number = &.{"number"},
        }) catch |err| {
            logx.catchWarn(log, "parseItems getLanding", err);
            return;
        };
        defer {
            vh.clearItems(alloc, &parsed);
            parsed.deinit(alloc);
        }
        if (parsed.items.len == 0) return;
        self.private().items.items[index].deinit(alloc);
        self.private().items.items[index] = parsed.items[0];
        _ = parsed.orderedRemove(0);
    }

    fn openLandingPR(self: *Self, item: vh.Item) void {
        const alloc = self.allocator();
        if (vh.rawJsonFieldString(alloc, item.raw_json, &.{ "pullRequestUrl", "pull_request_url", "prUrl", "pr_url", "html_url", "web_url", "url", "permalink" }) catch |rerr| blk: {
            logx.catchDebug(log, "rawJsonFieldString pr url", rerr);
            break :blk null;
        }) |url| {
            defer alloc.free(url);
            vh.openUrl(alloc, url) catch |err| {
                logx.catchWarn(log, "openUrl", err);
                self.private().window.showToastFmt("Open PR failed: {}", .{err});
            };
            return;
        }
        const number = item.number orelse {
            self.private().window.showToast("PR link is unavailable");
            return;
        };
        const json = vh.callJson(alloc, self.client(), "openLandingInBrowser", &.{.{ .key = "number", .value = .{ .integer = number } }}) catch |err| {
            logx.catchWarn(log, "rpc=openLandingInBrowser", err);
            self.private().window.showToastFmt("Open landing failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Opened landing #{d}", .{number});
    }

    fn confirmLand(self: *Self, number: i64) void {
        self.private().pending_land_number = number;
        const alloc = self.allocator();
        const body = std.fmt.allocPrintSentinel(alloc, "Land request #{d}? This will merge the landing request.", .{number}, 0) catch return;
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Land Request", body.ptr);
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("land", "Land");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");
        dialog.setResponseAppearance("land", .destructive);
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, landDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn landPending(self: *Self) void {
        const number = self.private().pending_land_number orelse return;
        self.private().pending_land_number = null;
        const alloc = self.allocator();
        const rpc_t = logx.startTimer();
        const json = vh.callJson(alloc, self.client(), "landLanding", &.{.{ .key = "number", .value = .{ .integer = number } }}) catch |err| {
            logx.catchWarn(log, "rpc=landLanding", err);
            self.private().window.showToastFmt("Land failed: {}", .{err});
            return;
        };
        logx.endTimerDebug(log, "rpc=landLanding", rpc_t);
        defer alloc.free(json);
        self.private().window.showToastFmt("Landed #{d}", .{number});
        self.refresh();
    }

    fn newClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().create_visible = !self.private().create_visible;
        if (self.private().create_visible) {
            self.renderCreate() catch |err| logx.catchWarn(log, "renderCreate", err);
        } else self.refresh();
    }

    fn filterClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-landing-filter") orelse return;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        self.private().state_filter = if (std.mem.eql(u8, text, "All")) null else if (std.mem.eql(u8, text, "Open")) "open" else if (std.mem.eql(u8, text, "Draft")) "draft" else if (std.mem.eql(u8, text, "Merged")) "merged" else "closed";
        self.refresh();
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.private().create_visible = false;
        logx.event(log, "row_selected", "view=landings index={d}", .{index});
        self.refreshLandingDetail(index);
        self.renderDetail(index) catch |err| logx.catchWarn(log, "renderDetail", err);
    }

    fn createClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.createLanding();
    }

    fn actionClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-landing-action") orelse return;
        self.landingAction(std.mem.span(@as([*:0]const u8, @ptrCast(raw))));
    }

    fn landDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        if (std.mem.orderZ(u8, response, "land") != .eq) {
            self.private().pending_land_number = null;
            return;
        }
        self.landPending();
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
