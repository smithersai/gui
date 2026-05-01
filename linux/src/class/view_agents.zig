const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const AgentsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersAgentsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        search_entry: *gtk.Entry = undefined,
        agents: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        active_only: bool = true,
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
        self.refreshImpl() catch |err| {
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Agents unavailable", @errorName(err));
        };
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.private().window.allocator();
    }

    fn build(self: *Self) !void {
        const root = self.as(gtk.Box);
        root.as(gtk.Orientable).setOrientation(.vertical);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>r", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "F5", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>f", self, shortcutSearch);
        const header = vh.makeHeader("Agents", null);
        self.private().search_entry = gtk.Entry.new();
        self.private().search_entry.setPlaceholderText("Search agents");
        self.private().search_entry.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().search_entry.as(gtk.Editable), *Self, searchChanged, self, .{});
        header.append(self.private().search_entry.as(gtk.Widget));
        const active = ui.textButton("Active", false);
        _ = gtk.Button.signals.clicked.connect(active, *Self, activeClicked, self, .{});
        header.append(active.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh agents");
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
        vh.setStatus(self.allocator(), self.private().detail, "system-users-symbolic", "Select an agent", "Agent status, configuration, and recent runs appear here.");
    }

    fn refreshImpl(self: *Self) !void {
        const alloc = self.allocator();
        const json = smithers.callJson(alloc, self.private().window.app().client(), "listActiveAgents", "{}") catch fallback: {
            break :fallback try smithers.callJson(alloc, self.private().window.app().client(), "listAgents", "{}");
        };
        defer alloc.free(json);
        const parsed = try vh.parseItems(alloc, json, &.{ "activeAgents", "active_agents", "agents", "items", "data" }, .{
            .id = &.{ "agentId", "agent_id", "id", "name" },
            .title = &.{ "name", "agent", "engine", "id" },
            .subtitle = &.{ "runId", "run_id", "workflowName", "workflow_name", "command", "binaryPath", "binary_path" },
            .status = &.{ "status", "state", "availability" },
            .body = &.{ "config", "settings", "description" },
            .path = &.{ "cwd", "workspace", "binaryPath", "binary_path", "command" },
            .run_id = &.{ "runId", "run_id" },
            .enabled = &.{ "active", "running", "usable" },
        });
        vh.clearItems(alloc, &self.private().agents);
        self.private().agents = parsed;
        self.private().selected_index = null;
        try self.renderList();
        vh.setStatus(alloc, self.private().detail, "system-users-symbolic", "Select an agent", "Agent status, configuration, and recent runs appear here.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        const list = self.private().list;
        ui.clearList(list);
        if (self.private().agents.items.len == 0) {
            list.append((try ui.row(alloc, "system-users-symbolic", "No agents found", "Active agents and configured agent binaries appear here.")).as(gtk.Widget));
            return;
        }
        const query = std.mem.trim(u8, std.mem.span(self.private().search_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        var visible: usize = 0;
        for (self.private().agents.items, 0..) |agent, index| {
            if (self.private().active_only and !isActiveAgent(agent)) continue;
            if (query.len > 0 and
                !vh.containsIgnoreCase(agent.title, query) and
                !vh.containsIgnoreCase(agent.id, query) and
                !(agent.status != null and vh.containsIgnoreCase(agent.status.?, query)) and
                !(agent.subtitle != null and vh.containsIgnoreCase(agent.subtitle.?, query))) continue;
            const row = try vh.itemRow(alloc, agent, agentIcon(agent));
            vh.setIndex(row.as(gobject.Object), index);
            list.append(row.as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            list.append((try ui.row(alloc, "system-search-symbolic", "No agents match filters", "Adjust search or active filter.")).as(gtk.Widget));
        }
    }

    fn renderDetail(self: *Self, index: usize) !void {
        if (index >= self.private().agents.items.len) return;
        const alloc = self.allocator();
        const agent = self.private().agents.items[index];
        const detail = self.private().detail;
        ui.clearBox(detail);
        const title_z = try alloc.dupeZ(u8, agent.title);
        defer alloc.free(title_z);
        detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, detail, "Agent", agent.id);
        try vh.detailRow(alloc, detail, "Status", agent.status);
        try vh.detailRow(alloc, detail, "Run", agent.run_id);
        try vh.detailRow(alloc, detail, "Command", agent.path);
        if (vh.rawJsonFieldValueString(alloc, agent.raw_json, &.{ "roles", "capabilities" }) catch null) |roles| {
            defer alloc.free(roles);
            try vh.detailRow(alloc, detail, "Roles", roles);
        }
        if (vh.rawJsonFieldString(alloc, agent.raw_json, &.{ "version", "binaryVersion", "binary_version" }) catch null) |version| {
            defer alloc.free(version);
            try vh.detailRow(alloc, detail, "Version", version);
        }

        const actions = vh.actionBar();
        const stop = ui.textButton("Stop Agent", false);
        stop.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(stop, *Self, stopClicked, self, .{});
        actions.append(stop.as(gtk.Widget));
        const refresh_button = ui.textButton("Refresh", true);
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        actions.append(refresh_button.as(gtk.Widget));
        detail.append(actions.as(gtk.Widget));

        if (vh.rawJsonFieldJson(alloc, agent.raw_json, &.{ "config", "settings", "launch", "environment", "env" }) catch null) |config| {
            defer alloc.free(config);
            try vh.appendJsonViewer(alloc, detail, "Config", config, 180);
        } else if (agent.raw_json) |raw| {
            try vh.appendJsonViewer(alloc, detail, "Agent JSON", raw, 180);
        }
        try self.appendRecentRuns(agent);
    }

    fn appendRecentRuns(self: *Self, agent: vh.Item) !void {
        const alloc = self.allocator();
        const runs_json: ?[]u8 = vh.callJson(alloc, self.private().window.app().client(), "listAgentRuns", &.{
            .{ .key = "agentID", .value = .{ .string = agent.id } },
            .{ .key = "limit", .value = .{ .integer = 5 } },
        }) catch (smithers.callJson(alloc, self.private().window.app().client(), "listRuns", "{}") catch null);
        const json = runs_json orelse return;
        defer alloc.free(json);
        var runs = vh.parseItems(alloc, json, &.{ "runs", "items", "data" }, .{
            .id = &.{ "runId", "run_id", "id" },
            .title = &.{ "workflowName", "workflow_name", "workflow", "runId", "run_id", "id" },
            .subtitle = &.{ "status", "state", "workflowPath", "workflow_path" },
            .status = &.{ "status", "state" },
            .run_id = &.{ "runId", "run_id", "id" },
        }) catch std.ArrayList(vh.Item).empty;
        defer {
            vh.clearItems(alloc, &runs);
            runs.deinit(alloc);
        }
        vh.addSectionTitle(self.private().detail, "Recent Runs");
        const list = vh.listBox();
        if (runs.items.len == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No recent runs", "Runs for this agent appear here.")).as(gtk.Widget));
        } else {
            for (runs.items[0..@min(runs.items.len, 5)]) |run| {
                list.append((try vh.itemRow(alloc, run, "media-playback-start-symbolic")).as(gtk.Widget));
            }
        }
        self.private().detail.append(list.as(gtk.Widget));
    }

    fn stopSelectedAgent(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().agents.items.len) return;
        const agent = self.private().agents.items[index];
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.private().window.app().client(), "stopAgent", &.{
            .{ .key = "agentID", .value = .{ .string = agent.id } },
            .{ .key = "runId", .value = .{ .optional_string = agent.run_id } },
        }) catch |err| {
            self.private().window.showToastFmt("Stop agent failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Stopped {s}", .{agent.title});
        self.refresh();
    }

    fn isActiveAgent(agent: vh.Item) bool {
        if (agent.enabled orelse false) return true;
        if (agent.run_id != null) return true;
        if (agent.status) |status| {
            return std.ascii.eqlIgnoreCase(status, "active") or
                std.ascii.eqlIgnoreCase(status, "running") or
                std.ascii.eqlIgnoreCase(status, "busy") or
                std.ascii.eqlIgnoreCase(status, "started");
        }
        return false;
    }

    fn agentIcon(agent: vh.Item) [:0]const u8 {
        if (isActiveAgent(agent)) return "media-playback-start-symbolic";
        if (agent.status) |status| {
            if (std.ascii.eqlIgnoreCase(status, "failed") or std.ascii.eqlIgnoreCase(status, "error")) return "dialog-error-symbolic";
            if (std.ascii.eqlIgnoreCase(status, "unavailable")) return "process-stop-symbolic";
        }
        return "system-users-symbolic";
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.renderList() catch {};
    }

    fn activeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().active_only = !self.private().active_only;
        self.renderList() catch {};
        self.private().window.showToast(if (self.private().active_only) "Showing active agents" else "Showing all agents");
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.renderDetail(index) catch {};
    }

    fn stopClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.stopSelectedAgent();
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
            vh.clearItems(self.allocator(), &priv.agents);
            priv.agents.deinit(self.allocator());
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
