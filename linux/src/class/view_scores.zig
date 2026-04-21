const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const models = @import("../models.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const ScoresView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersScoresView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        runs_list: *gtk.ListBox = undefined,
        body: *gtk.Box = undefined,
        runs: std.ArrayList(models.RunSummary) = .empty,
        scores: std.ArrayList(vh.Item) = .empty,
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
        self.loadRuns() catch |err| vh.setStatus(self.allocator(), self.private().body, "dialog-error-symbolic", "Scores unavailable", @errorName(err));
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
        const header = vh.makeHeader("Scores", null);
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh scores");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));
        const split = vh.splitPane(330);
        self.private().runs_list = vh.listBox();
        _ = gtk.ListBox.signals.row_activated.connect(self.private().runs_list, *Self, runActivated, self, .{});
        const run_scroll = ui.scrolled(self.private().runs_list.as(gtk.Widget));
        run_scroll.as(gtk.Widget).setVexpand(1);
        split.left.append(run_scroll.as(gtk.Widget));
        self.private().body = gtk.Box.new(.vertical, 12);
        ui.margin(self.private().body.as(gtk.Widget), 18);
        const body_scroll = ui.scrolled(self.private().body.as(gtk.Widget));
        body_scroll.as(gtk.Widget).setVexpand(1);
        split.right.append(body_scroll.as(gtk.Widget));
        root.append(split.root.as(gtk.Widget));
    }

    fn loadRuns(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.client(), "listRuns", "{}");
        defer alloc.free(json);
        const parsed = try models.parseRuns(alloc, json);
        models.clearList(models.RunSummary, alloc, &self.private().runs);
        self.private().runs = parsed;
        try self.renderRuns();
        if (self.private().runs.items.len > 0) {
            self.private().selected_index = 0;
            self.loadScores(0);
        } else {
            vh.setStatus(alloc, self.private().body, "view-list-symbolic", "No runs available", "Scores are grouped by run.");
        }
    }

    fn renderRuns(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().runs_list);
        if (self.private().runs.items.len == 0) {
            self.private().runs_list.append((try ui.row(alloc, "view-list-symbolic", "No runs", "Launch a workflow first.")).as(gtk.Widget));
            return;
        }
        for (self.private().runs.items, 0..) |run, index| {
            const row = try ui.row(alloc, "media-playback-start-symbolic", run.workflow_name orelse run.run_id, run.run_id);
            vh.setIndex(row.as(gobject.Object), index);
            self.private().runs_list.append(row.as(gtk.Widget));
        }
    }

    fn loadScores(self: *Self, index: usize) void {
        if (index >= self.private().runs.items.len) return;
        const alloc = self.allocator();
        const run = self.private().runs.items[index];
        const json = vh.callJson(alloc, self.client(), "listRecentScores", &.{.{ .key = "runId", .value = .{ .string = run.run_id } }}) catch |err| {
            vh.setStatus(alloc, self.private().body, "dialog-error-symbolic", "Score load failed", @errorName(err));
            return;
        };
        defer alloc.free(json);
        const parsed = vh.parseItems(alloc, json, &.{ "scores", "items", "data" }, .{
            .id = &.{"id"},
            .title = &.{ "scorerName", "scorer_name", "scorerId", "scorer_id", "nodeId", "node_id" },
            .subtitle = &.{ "nodeId", "node_id", "reason" },
            .body = &.{ "reason", "metaJson", "meta_json" },
            .score = &.{"score"},
            .run_id = &.{ "runId", "run_id" },
            .node_id = &.{ "nodeId", "node_id" },
        }) catch std.ArrayList(vh.Item).empty;
        vh.clearItems(alloc, &self.private().scores);
        self.private().scores = parsed;
        self.renderScores(run) catch {};
    }

    fn renderScores(self: *Self, run: models.RunSummary) !void {
        const alloc = self.allocator();
        const body = self.private().body;
        ui.clearBox(body);
        body.append(ui.heading("Score Summary").as(gtk.Widget));
        const metrics = gtk.Box.new(.horizontal, 12);
        try vh.appendMetric(alloc, metrics, "Evaluations", self.private().scores.items.len, run.run_id);
        try vh.appendMetric(alloc, metrics, "Mean Score", meanScorePercent(self.private().scores.items), "average score");
        body.append(metrics.as(gtk.Widget));
        const token_json = vh.callJson(alloc, self.client(), "getTokenUsageMetrics", &.{.{ .key = "filters", .value = .{ .raw = "{}" } }}) catch null;
        if (token_json) |json| {
            defer alloc.free(json);
            try vh.detailRow(alloc, body, "Token Metrics", json);
        }
        body.append(ui.heading("Recent Scores").as(gtk.Widget));
        const list = vh.listBox();
        if (self.private().scores.items.len == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No scores", "Scorer output appears here.")).as(gtk.Widget));
        } else {
            for (self.private().scores.items) |score| {
                const score_text = if (score.score) |value| try std.fmt.allocPrint(alloc, "{d:.2} - {s}", .{ value, score.body orelse "" }) else try alloc.dupe(u8, score.body orelse "");
                defer alloc.free(score_text);
                list.append((try ui.row(alloc, "emblem-ok-symbolic", score.title, score_text)).as(gtk.Widget));
            }
        }
        body.append(list.as(gtk.Widget));
    }

    fn meanScorePercent(scores: []const vh.Item) usize {
        if (scores.len == 0) return 0;
        var sum: f64 = 0;
        for (scores) |score| sum += score.score orelse 0;
        return @intFromFloat((sum / @as(f64, @floatFromInt(scores.len))) * 100.0);
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn runActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.loadScores(index);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            models.clearList(models.RunSummary, self.allocator(), &priv.runs);
            priv.runs.deinit(self.allocator());
            vh.clearItems(self.allocator(), &priv.scores);
            priv.scores.deinit(self.allocator());
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
