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
    const SortKey = enum { score, scorer, date };

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
        type_entry: *gtk.Entry = undefined,
        start_entry: *gtk.Entry = undefined,
        end_entry: *gtk.Entry = undefined,
        min_entry: *gtk.Entry = undefined,
        max_entry: *gtk.Entry = undefined,
        runs: std.ArrayList(models.RunSummary) = .empty,
        scores: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        sort_key: SortKey = .score,
        sort_desc: bool = true,
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
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>r", self, shortcutRefresh);
        const header = vh.makeHeader("Scores", null);
        self.private().type_entry = gtk.Entry.new();
        self.private().type_entry.setPlaceholderText("Score type");
        self.private().type_entry.as(gtk.Widget).setSizeRequest(110, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().type_entry, *Self, scoreFilterActivated, self, .{});
        header.append(self.private().type_entry.as(gtk.Widget));
        self.private().start_entry = gtk.Entry.new();
        self.private().start_entry.setPlaceholderText("Start YYYY-MM-DD");
        self.private().start_entry.as(gtk.Widget).setSizeRequest(130, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().start_entry, *Self, scoreFilterActivated, self, .{});
        header.append(self.private().start_entry.as(gtk.Widget));
        self.private().end_entry = gtk.Entry.new();
        self.private().end_entry.setPlaceholderText("End YYYY-MM-DD");
        self.private().end_entry.as(gtk.Widget).setSizeRequest(130, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().end_entry, *Self, scoreFilterActivated, self, .{});
        header.append(self.private().end_entry.as(gtk.Widget));
        self.private().min_entry = gtk.Entry.new();
        self.private().min_entry.setPlaceholderText("Min");
        self.private().min_entry.as(gtk.Widget).setSizeRequest(70, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().min_entry, *Self, scoreFilterActivated, self, .{});
        header.append(self.private().min_entry.as(gtk.Widget));
        self.private().max_entry = gtk.Entry.new();
        self.private().max_entry.setPlaceholderText("Max");
        self.private().max_entry.as(gtk.Widget).setSizeRequest(70, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().max_entry, *Self, scoreFilterActivated, self, .{});
        header.append(self.private().max_entry.as(gtk.Widget));
        inline for (.{ "Score", "Scorer", "Date" }) |label| {
            const button = ui.textButton(label, false);
            button.as(gobject.Object).setData("smithers-score-sort", @constCast(label.ptr));
            _ = gtk.Button.signals.clicked.connect(button, *Self, sortClicked, self, .{});
            header.append(button.as(gtk.Widget));
        }
        const export_button = ui.textButton("Export CSV", false);
        _ = gtk.Button.signals.clicked.connect(export_button, *Self, exportClicked, self, .{});
        header.append(export_button.as(gtk.Widget));
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
            .status = &.{ "source", "scoreType", "score_type", "type", "kind" },
            .body = &.{ "reason", "metaJson", "meta_json" },
            .number = &.{ "scoredAtMs", "scored_at_ms", "createdAtMs", "created_at_ms" },
            .score = &.{"score"},
            .run_id = &.{ "runId", "run_id" },
            .node_id = &.{ "nodeId", "node_id" },
        }) catch std.ArrayList(vh.Item).empty;
        vh.clearItems(alloc, &self.private().scores);
        self.private().scores = parsed;
        self.sortScores();
        self.renderScores(run) catch {};
    }

    fn renderScores(self: *Self, run: models.RunSummary) !void {
        const alloc = self.allocator();
        const body = self.private().body;
        ui.clearBox(body);
        body.append(ui.heading("Score Summary").as(gtk.Widget));
        const visible = self.visibleScoreStats();
        const metrics = gtk.Box.new(.horizontal, 12);
        try vh.appendMetric(alloc, metrics, "Evaluations", visible.count, run.run_id);
        try vh.appendMetric(alloc, metrics, "Mean Score", visible.mean, "visible average");
        try vh.appendMetric(alloc, metrics, "P50 Score", visible.p50, "visible median");
        try vh.appendMetric(alloc, metrics, "P99 Score", visible.p99, "visible tail");
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
            var visible_count: usize = 0;
            for (self.private().scores.items) |score| {
                if (!self.scoreMatchesFilters(score)) continue;
                const score_text = if (score.score) |value| try std.fmt.allocPrint(alloc, "{d:.2} - {s} - {s}", .{ value, scoreType(score), score.body orelse "" }) else try alloc.dupe(u8, score.body orelse "");
                defer alloc.free(score_text);
                list.append((try ui.row(alloc, "emblem-ok-symbolic", score.title, score_text)).as(gtk.Widget));
                visible_count += 1;
            }
            if (visible_count == 0) {
                list.append((try ui.row(alloc, "system-search-symbolic", "No scores in range", "Adjust min/max score filters.")).as(gtk.Widget));
            }
        }
        body.append(list.as(gtk.Widget));
    }

    const ScoreStats = struct { count: usize, mean: usize, p50: usize, p99: usize };

    fn visibleScoreStats(self: *Self) ScoreStats {
        const alloc = self.allocator();
        var values: std.ArrayList(f64) = .empty;
        defer values.deinit(alloc);
        var sum: f64 = 0;
        for (self.private().scores.items) |score| {
            if (!self.scoreMatchesFilters(score)) continue;
            const value = score.score orelse 0;
            values.append(alloc, value) catch continue;
            sum += value;
        }
        if (values.items.len == 0) return .{ .count = 0, .mean = 0, .p50 = 0, .p99 = 0 };
        std.mem.sort(f64, values.items, {}, floatLess);
        return .{
            .count = values.items.len,
            .mean = @intFromFloat((sum / @as(f64, @floatFromInt(values.items.len))) * 100.0),
            .p50 = @intFromFloat(percentile(values.items, 50) * 100.0),
            .p99 = @intFromFloat(percentile(values.items, 99) * 100.0),
        };
    }

    fn scoreMatchesFilters(self: *Self, score: vh.Item) bool {
        const value = score.score orelse 0;
        const type_filter = vh.trimEntryText(self.private().type_entry);
        if (type_filter.len > 0 and !vh.containsIgnoreCase(scoreType(score), type_filter) and !vh.containsIgnoreCase(score.title, type_filter)) return false;
        if (parseScoreEntry(self.private().min_entry)) |min| {
            if (value < min) return false;
        }
        if (parseScoreEntry(self.private().max_entry)) |max| {
            if (value > max) return false;
        }
        if (parseDateEntry(self.private().start_entry, false)) |start_ms| {
            const scored_at = scoreDateMs(score) orelse return false;
            if (scored_at < start_ms) return false;
        }
        if (parseDateEntry(self.private().end_entry, true)) |end_ms| {
            const scored_at = scoreDateMs(score) orelse return false;
            if (scored_at > end_ms) return false;
        }
        return true;
    }

    fn parseScoreEntry(entry: *gtk.Entry) ?f64 {
        const text = vh.trimEntryText(entry);
        if (text.len == 0) return null;
        const raw = std.fmt.parseFloat(f64, text) catch return null;
        return if (raw > 1.0) raw / 100.0 else raw;
    }

    fn sortScores(self: *Self) void {
        std.mem.sort(vh.Item, self.private().scores.items, self, scoreLess);
    }

    fn scoreLess(self: *Self, lhs: vh.Item, rhs: vh.Item) bool {
        const order = switch (self.private().sort_key) {
            .score => compareFloat(lhs.score orelse 0, rhs.score orelse 0),
            .scorer => std.mem.order(u8, lhs.title, rhs.title),
            .date => compareInt(scoreDateMs(lhs) orelse 0, scoreDateMs(rhs) orelse 0),
        };
        if (order == .eq) return std.mem.order(u8, lhs.id, rhs.id) == .lt;
        return if (self.private().sort_desc) order == .gt else order == .lt;
    }

    fn compareFloat(lhs: f64, rhs: f64) std.math.Order {
        if (lhs < rhs) return .lt;
        if (lhs > rhs) return .gt;
        return .eq;
    }

    fn compareInt(lhs: i64, rhs: i64) std.math.Order {
        if (lhs < rhs) return .lt;
        if (lhs > rhs) return .gt;
        return .eq;
    }

    fn floatLess(_: void, lhs: f64, rhs: f64) bool {
        return lhs < rhs;
    }

    fn percentile(sorted: []const f64, pct: usize) f64 {
        if (sorted.len == 0) return 0;
        const rank = @max(@as(usize, 1), (sorted.len * pct + 99) / 100);
        return sorted[@min(sorted.len - 1, rank - 1)];
    }

    fn scoreType(score: vh.Item) []const u8 {
        return score.status orelse "score";
    }

    fn scoreDateMs(score: vh.Item) ?i64 {
        return score.number;
    }

    fn parseDateEntry(entry: *gtk.Entry, end_of_day: bool) ?i64 {
        const text = vh.trimEntryText(entry);
        if (text.len == 0) return null;
        if (std.fmt.parseInt(i64, text, 10)) |raw| {
            return if (raw < 10_000_000_000) raw * 1000 else raw;
        } else |_| {}
        if (text.len < 10 or text[4] != '-' or text[7] != '-') return null;
        const year = std.fmt.parseInt(u16, text[0..4], 10) catch return null;
        const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
        if (year < 1970 or month < 1 or month > 12 or day < 1) return null;
        var days: u64 = 0;
        var y: u16 = 1970;
        while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
        var m: u8 = 1;
        while (m < month) : (m += 1) {
            days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
        }
        const max_day = std.time.epoch.getDaysInMonth(year, @enumFromInt(month));
        if (day > max_day) return null;
        days += day - 1;
        const day_ms: i64 = @as(i64, std.time.epoch.secs_per_day) * 1000;
        const start_ms: i64 = @intCast(days * @as(u64, std.time.epoch.secs_per_day) * 1000);
        return if (end_of_day) start_ms + (day_ms - 1) else start_ms;
    }

    fn exportCsv(self: *Self) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator());
        defer out.deinit();
        out.writer.writeAll("id,run_id,node_id,scorer,score,type,detail\n") catch return;
        for (self.private().scores.items) |score| {
            if (!self.scoreMatchesFilters(score)) continue;
            csvField(&out.writer, score.id) catch return;
            out.writer.writeByte(',') catch return;
            csvField(&out.writer, score.run_id orelse "") catch return;
            out.writer.writeByte(',') catch return;
            csvField(&out.writer, score.node_id orelse "") catch return;
            out.writer.writeByte(',') catch return;
            csvField(&out.writer, score.title) catch return;
            out.writer.writeByte(',') catch return;
            out.writer.print("{d:.4}", .{score.score orelse 0}) catch return;
            out.writer.writeByte(',') catch return;
            csvField(&out.writer, scoreType(score)) catch return;
            out.writer.writeByte(',') catch return;
            csvField(&out.writer, score.body orelse "") catch return;
            out.writer.writeByte('\n') catch return;
        }
        const csv = out.toOwnedSlice() catch return;
        defer self.allocator().free(csv);
        const z = self.allocator().dupeZ(u8, csv) catch return;
        defer self.allocator().free(z);
        self.as(gtk.Widget).getClipboard().setText(z.ptr);
        self.private().window.showToast("Visible scores exported as CSV to clipboard");
    }

    fn csvField(writer: *std.Io.Writer, text: []const u8) !void {
        try writer.writeByte('"');
        for (text) |ch| {
            if (ch == '"') try writer.writeByte('"');
            try writer.writeByte(ch);
        }
        try writer.writeByte('"');
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn scoreFilterActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        if (self.private().selected_index) |index| {
            if (index < self.private().runs.items.len) self.renderScores(self.private().runs.items[index]) catch {};
        }
    }

    fn sortClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-score-sort") orelse return;
        const label = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        const next_key: SortKey = if (std.mem.eql(u8, label, "Scorer")) .scorer else if (std.mem.eql(u8, label, "Date")) .date else .score;
        if (self.private().sort_key == next_key) {
            self.private().sort_desc = !self.private().sort_desc;
        } else {
            self.private().sort_key = next_key;
            self.private().sort_desc = true;
        }
        self.sortScores();
        if (self.private().selected_index) |index| {
            if (index < self.private().runs.items.len) self.renderScores(self.private().runs.items[index]) catch {};
        }
        self.private().window.showToast(if (self.private().sort_desc) "Scores sorted descending" else "Scores sorted ascending");
    }

    fn exportClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.exportCsv();
    }

    fn runActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.loadScores(index);
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
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
