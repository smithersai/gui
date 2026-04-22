const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const models = @import("../models.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Sidebar = @import("sidebar.zig").Sidebar;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const NewTabPicker = @import("new_tab_picker.zig").NewTabPicker;
const SessionWidget = @import("session.zig").SessionWidget;
const DashboardView = @import("view_dashboard.zig").DashboardView;
const RunsView = @import("view_runs.zig").RunsView;
const RunInspectView = @import("view_run_inspect.zig").RunInspectView;
const WorkflowsView = @import("view_workflows.zig").WorkflowsView;
const JJHubWorkflowsView = @import("view_jjhub_workflows.zig").JJHubWorkflowsView;
const ApprovalsView = @import("view_approvals.zig").ApprovalsView;
const TicketsView = @import("view_tickets.zig").TicketsView;
const ChangesView = @import("view_changes.zig").ChangesView;
const IssuesView = @import("view_issues.zig").IssuesView;
const LandingsView = @import("view_landings.zig").LandingsView;
const AgentsView = @import("view_agents.zig").AgentsView;
const PromptsView = @import("view_prompts.zig").PromptsView;
const ScoresView = @import("view_scores.zig").ScoresView;
const MemoryView = @import("view_memory.zig").MemoryView;
const TriggersView = @import("view_triggers.zig").TriggersView;
const VCSDashboardView = @import("view_vcs_dashboard.zig").VCSDashboardView;

const log = std.log.scoped(.smithers_gtk_window);

pub const MainWindow = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersMainWindow",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const Nav = enum {
        welcome,
        dashboard,
        vcs_dashboard,
        workflows,
        jjhub_workflows,
        runs,
        run_inspect,
        approvals,
        tickets,
        changes,
        issues,
        landings,
        agents,
        prompts,
        scores,
        memory,
        triggers,
        workspaces,
        settings,
        inspector,
        session,
    };

    const Private = struct {
        app: *Application = undefined,
        toast_overlay: *adw.ToastOverlay = undefined,
        split_view: *adw.NavigationSplitView = undefined,
        sidebar: *Sidebar = undefined,
        stack: *gtk.Stack = undefined,
        title_label: *gtk.Label = undefined,
        workspace_entry: *gtk.Entry = undefined,

        dashboard_box: *gtk.Box = undefined,
        workflows_list: *gtk.ListBox = undefined,
        runs_list: *gtk.ListBox = undefined,
        approvals_list: *gtk.ListBox = undefined,
        agents_list: *gtk.ListBox = undefined,
        workspaces_box: *gtk.Box = undefined,
        inspector_box: *gtk.Box = undefined,
        settings_box: *gtk.Box = undefined,

        dashboard_view: *DashboardView = undefined,
        runs_view: *RunsView = undefined,
        run_inspect_view: *RunInspectView = undefined,
        workflows_view: *WorkflowsView = undefined,
        jjhub_workflows_view: *JJHubWorkflowsView = undefined,
        approvals_view: *ApprovalsView = undefined,
        tickets_view: *TicketsView = undefined,
        changes_view: *ChangesView = undefined,
        issues_view: *IssuesView = undefined,
        landings_view: *LandingsView = undefined,
        agents_view: *AgentsView = undefined,
        prompts_view: *PromptsView = undefined,
        scores_view: *ScoresView = undefined,
        memory_view: *MemoryView = undefined,
        triggers_view: *TriggersView = undefined,
        vcs_dashboard_view: *VCSDashboardView = undefined,

        command_palette: ?*CommandPalette = null,
        new_tab_picker: ?*NewTabPicker = null,

        workspace_handle: smithers.c.smithers_workspace_t = null,
        active_workspace: ?[]u8 = null,
        opening_workspace: bool = false,
        opening_session: bool = false,
        closing_workspace: bool = false,
        sidebar_hidden: bool = false,
        active_session_index: ?usize = null,
        visible: Nav = .welcome,
        workflows: std.ArrayList(models.Workflow) = .empty,
        runs: std.ArrayList(models.RunSummary) = .empty,
        approvals: std.ArrayList(models.Approval) = .empty,
        agents: std.ArrayList(models.Agent) = .empty,
        workspaces: std.ArrayList(models.Workspace) = .empty,
        sessions: std.ArrayList(*SessionWidget) = .empty,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(application: *Application) !*Self {
        const self = gobject.ext.newInstance(Self, .{
            .application = application.as(gtk.Application),
        });
        errdefer self.unref();

        const priv = self.private();
        priv.* = .{ .app = application };
        try self.buildShell();
        try self.loadInitialWorkspace();
        return self;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.private().app.allocator();
    }

    pub fn app(self: *Self) *Application {
        return self.private().app;
    }

    pub fn tick(self: *Self) void {
        const priv = self.private();
        for (priv.sessions.items) |session| session.drainEvents() catch |err| {
            log.warn("session event drain failed: {}", .{err});
        };
    }

    pub fn presentCommandPalette(self: *Self) void {
        const priv = self.private();
        if (priv.command_palette == null) {
            priv.command_palette = CommandPalette.new(self) catch |err| {
                self.showToastFmt("Unable to open command palette: {}", .{err});
                return;
            };
        }
        priv.command_palette.?.present();
    }

    pub fn dismissCommandPalette(self: *Self) void {
        if (self.private().command_palette) |palette| palette.dismiss();
    }

    pub fn presentNewTabPicker(self: *Self) void {
        const priv = self.private();
        if (priv.new_tab_picker == null) {
            priv.new_tab_picker = NewTabPicker.new(self) catch |err| {
                self.showToastFmt("Unable to open new tab picker: {}", .{err});
                return;
            };
        }
        priv.new_tab_picker.?.present();
    }

    pub fn showToast(self: *Self, title: []const u8) void {
        const alloc = self.allocator();
        const title_z = alloc.dupeZ(u8, title) catch return;
        defer alloc.free(title_z);
        const toast = adw.Toast.new(title_z.ptr);
        self.private().toast_overlay.addToast(toast);
    }

    pub fn showToastFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const alloc = self.allocator();
        const msg = std.fmt.allocPrint(alloc, fmt, args) catch return;
        defer alloc.free(msg);
        self.showToast(msg);
    }

    pub fn openWorkspace(self: *Self, path: []const u8) !void {
        const alloc = self.allocator();
        const z = try alloc.dupeZ(u8, path);
        defer alloc.free(z);

        self.private().opening_workspace = true;
        defer self.private().opening_workspace = false;

        const ws = smithers.c.smithers_app_open_workspace(self.private().app.core(), z.ptr);
        if (ws == null) return error.OpenWorkspaceFailed;
        errdefer smithers.c.smithers_app_close_workspace(self.private().app.core(), ws);

        try self.adoptWorkspace(path, ws);
    }

    pub fn workspaceOpenedFromCore(self: *Self, path: []const u8) bool {
        if (self.private().opening_workspace) return true;
        self.adoptWorkspace(path, null) catch |err| {
            log.warn("workspace action adoption failed: {}", .{err});
            self.showToastFmt("Workspace refresh failed: {}", .{err});
            return false;
        };
        return true;
    }

    pub fn closeWorkspace(self: *Self) void {
        const priv = self.private();
        if (priv.workspace_handle) |ws| {
            priv.workspace_handle = null;
            priv.closing_workspace = true;
            smithers.c.smithers_app_close_workspace(priv.app.core(), ws);
            priv.closing_workspace = false;
        }
        self.clearWorkspaceUi();
    }

    pub fn workspaceClosedFromCore(self: *Self) void {
        if (self.private().closing_workspace) return;
        self.clearWorkspaceUi();
    }

    fn adoptWorkspace(self: *Self, path: []const u8, handle: smithers.c.smithers_workspace_t) !void {
        const alloc = self.allocator();
        const owned_path = try alloc.dupe(u8, path);
        errdefer alloc.free(owned_path);

        if (self.private().workspace_handle) |old| {
            if (handle == null or old != handle.?) self.closeWorkspaceHandle();
        }
        self.closeAllSessions();

        self.private().workspace_handle = handle;
        if (self.private().active_workspace) |old| alloc.free(old);
        self.private().active_workspace = owned_path;
        self.private().sidebar.refresh();
        self.refreshAll() catch |err| {
            log.warn("refresh after workspace open failed: {}", .{err});
            self.showToast("Workspace opened, but some data could not be loaded");
        };
        self.showNav(.dashboard);
    }

    fn clearWorkspaceUi(self: *Self) void {
        const priv = self.private();
        const alloc = self.allocator();
        self.closeWorkspaceHandle();
        if (priv.active_workspace) |path| {
            alloc.free(path);
            priv.active_workspace = null;
        }
        self.closeAllSessions();
        models.clearList(models.Workflow, alloc, &priv.workflows);
        models.clearList(models.RunSummary, alloc, &priv.runs);
        models.clearList(models.Approval, alloc, &priv.approvals);
        models.clearList(models.Agent, alloc, &priv.agents);
        models.clearList(models.Workspace, alloc, &priv.workspaces);
        self.showNav(.welcome);
    }

    fn closeWorkspaceHandle(self: *Self) void {
        const priv = self.private();
        const ws = priv.workspace_handle orelse return;
        priv.workspace_handle = null;
        priv.closing_workspace = true;
        smithers.c.smithers_app_close_workspace(priv.app.core(), ws);
        priv.closing_workspace = false;
    }

    pub fn showNav(self: *Self, nav: Nav) void {
        const priv = self.private();
        priv.visible = nav;
        switch (nav) {
            .welcome => {
                self.setTitle("Welcome");
                priv.stack.setVisibleChildName("welcome");
            },
            .dashboard => {
                priv.dashboard_view.refresh();
                self.setTitle("Dashboard");
                priv.stack.setVisibleChildName("dashboard");
            },
            .vcs_dashboard => {
                priv.vcs_dashboard_view.refresh();
                self.setTitle("VCS Dashboard");
                priv.stack.setVisibleChildName("vcs-dashboard");
            },
            .workflows => {
                priv.workflows_view.refresh();
                self.setTitle("Workflows");
                priv.stack.setVisibleChildName("workflows");
            },
            .jjhub_workflows => {
                priv.jjhub_workflows_view.refresh();
                self.setTitle("JJHub Workflows");
                priv.stack.setVisibleChildName("jjhub-workflows");
            },
            .runs => {
                priv.runs_view.refresh();
                self.setTitle("Runs");
                priv.stack.setVisibleChildName("runs");
            },
            .run_inspect => {
                priv.run_inspect_view.refresh();
                self.setTitle("Run Inspector");
                priv.stack.setVisibleChildName("run-inspect");
            },
            .approvals => {
                priv.approvals_view.refresh();
                self.setTitle("Approvals");
                priv.stack.setVisibleChildName("approvals");
            },
            .tickets => {
                priv.tickets_view.refresh();
                self.setTitle("Tickets");
                priv.stack.setVisibleChildName("tickets");
            },
            .changes => {
                priv.changes_view.refresh();
                self.setTitle("Changes");
                priv.stack.setVisibleChildName("changes");
            },
            .issues => {
                priv.issues_view.refresh();
                self.setTitle("Issues");
                priv.stack.setVisibleChildName("issues");
            },
            .landings => {
                priv.landings_view.refresh();
                self.setTitle("Landings");
                priv.stack.setVisibleChildName("landings");
            },
            .agents => {
                priv.agents_view.refresh();
                self.setTitle("Agents");
                priv.stack.setVisibleChildName("agents");
            },
            .prompts => {
                priv.prompts_view.refresh();
                self.setTitle("Prompts");
                priv.stack.setVisibleChildName("prompts");
            },
            .scores => {
                priv.scores_view.refresh();
                self.setTitle("Scores");
                priv.stack.setVisibleChildName("scores");
            },
            .memory => {
                priv.memory_view.refresh();
                self.setTitle("Memory");
                priv.stack.setVisibleChildName("memory");
            },
            .triggers => {
                priv.triggers_view.refresh();
                self.setTitle("Triggers");
                priv.stack.setVisibleChildName("triggers");
            },
            .workspaces => {
                self.refreshWorkspacesPage() catch |err| self.showToastFmt("Workspace refresh failed: {}", .{err});
                self.setTitle("Workspaces");
                priv.stack.setVisibleChildName("workspaces");
            },
            .settings => {
                self.setTitle("Settings");
                priv.stack.setVisibleChildName("settings");
            },
            .inspector => {
                priv.run_inspect_view.refresh();
                self.setTitle("Run Inspector");
                priv.stack.setVisibleChildName("run-inspect");
            },
            .session => {},
        }
        priv.sidebar.refresh();
    }

    pub fn refreshVisible(self: *Self) void {
        self.showNav(self.private().visible);
    }

    pub fn sessionCount(self: *Self) usize {
        return self.private().sessions.items.len;
    }

    pub fn sessionAt(self: *Self, index: usize) ?*SessionWidget {
        const sessions = self.private().sessions.items;
        if (index >= sessions.len) return null;
        return sessions[index];
    }

    pub fn activeWorkspace(self: *Self) ?[]const u8 {
        return self.private().active_workspace;
    }

    pub fn isOpeningSession(self: *Self) bool {
        return self.private().opening_session;
    }

    pub fn focusSidebar(self: *Self) void {
        const priv = self.private();
        priv.sidebar_hidden = false;
        priv.split_view.setCollapsed(0);
        priv.split_view.setShowContent(0);
        _ = priv.sidebar.as(gtk.Widget).grabFocus();
    }

    pub fn focusContent(self: *Self) void {
        const priv = self.private();
        priv.split_view.setShowContent(1);
        _ = priv.stack.as(gtk.Widget).grabFocus();
    }

    pub fn toggleSidebar(self: *Self) void {
        const priv = self.private();
        if (priv.sidebar_hidden) {
            priv.sidebar_hidden = false;
            priv.split_view.setCollapsed(0);
            priv.split_view.setShowContent(1);
        } else {
            priv.sidebar_hidden = true;
            priv.split_view.setCollapsed(1);
            priv.split_view.setShowContent(1);
        }
    }

    pub fn cycleSession(self: *Self, offset: isize) void {
        const priv = self.private();
        const len = priv.sessions.items.len;
        if (len == 0) {
            self.showToast("No sessions");
            return;
        }
        const current = priv.active_session_index orelse 0;
        const next = @mod(@as(isize, @intCast(current)) + offset, @as(isize, @intCast(len)));
        self.showSession(@intCast(next));
    }

    pub fn openRecentWorkspace(self: *Self, index: usize) void {
        if (self.private().workspaces.items.len <= index) {
            self.loadWorkspaces() catch |err| {
                self.showToastFmt("Workspace refresh failed: {}", .{err});
                return;
            };
        }
        if (index >= self.private().workspaces.items.len) {
            self.showToast("No recent workspace");
            return;
        }
        self.openWorkspace(self.private().workspaces.items[index].id) catch |err| {
            self.showToastFmt("Open workspace failed: {}", .{err});
        };
    }

    pub fn toggleFullscreen(self: *Self) void {
        const window = self.as(gtk.Window);
        if (window.isFullscreen() != 0) {
            window.unfullscreen();
        } else {
            window.fullscreen();
        }
    }

    pub fn openSession(
        self: *Self,
        kind: smithers.c.smithers_session_kind_e,
        target_id: ?[]const u8,
    ) !void {
        const workspace = self.private().active_workspace;
        self.private().opening_session = true;
        defer self.private().opening_session = false;
        const session = try SessionWidget.new(self.private().app, kind, workspace, target_id);
        errdefer session.unref();
        try self.appendSessionWidget(session);
    }

    pub fn adoptSessionHandle(self: *Self, handle: smithers.c.smithers_session_t) !bool {
        if (handle == null) return false;
        if (self.showSessionHandle(handle)) return true;

        const session = try SessionWidget.fromHandle(self.private().app, handle);
        errdefer session.unref();
        try self.appendSessionWidget(session);
        return true;
    }

    fn appendSessionWidget(self: *Self, session: *SessionWidget) !void {
        const next_index = self.private().sessions.items.len;
        const name = try std.fmt.allocPrintSentinel(self.allocator(), "session-{d}", .{next_index + 1}, 0);
        defer self.allocator().free(name);
        const title_z = try session.titleZ(self.allocator());
        defer self.allocator().free(title_z);

        try self.private().sessions.ensureUnusedCapacity(self.allocator(), 1);
        _ = session.ref();
        self.private().sessions.appendAssumeCapacity(session);

        _ = self.private().stack.addTitled(session.as(gtk.Widget), name.ptr, title_z.ptr);
        self.private().stack.setVisibleChild(session.as(gtk.Widget));
        self.private().visible = .session;
        self.private().active_session_index = next_index;
        self.setTitle(title_z);
        self.private().sidebar.refresh();
    }

    pub fn showSession(self: *Self, index: usize) void {
        if (index >= self.private().sessions.items.len) return;
        const session = self.private().sessions.items[index];
        self.private().stack.setVisibleChild(session.as(gtk.Widget));
        self.private().visible = .session;
        self.private().active_session_index = index;
        if (session.titleZ(self.allocator())) |title_z| {
            defer self.allocator().free(title_z);
            self.setTitle(title_z);
        } else |_| {
            self.setTitle("Session");
        }
        self.private().sidebar.refresh();
    }

    pub fn showSessionHandle(self: *Self, handle: smithers.c.smithers_session_t) bool {
        if (handle == null) return false;
        for (self.private().sessions.items, 0..) |session, index| {
            if (session.handle() == handle) {
                self.showSession(index);
                return true;
            }
        }
        return false;
    }

    pub fn closeCurrentSession(self: *Self) void {
        const priv = self.private();
        if (priv.visible != .session) {
            self.as(gtk.Window).close();
            return;
        }
        const index = priv.active_session_index orelse {
            self.as(gtk.Window).close();
            return;
        };
        self.closeSession(index);
    }

    pub fn closeSessionHandle(self: *Self, handle: smithers.c.smithers_session_t) bool {
        if (handle == null) return false;
        for (self.private().sessions.items, 0..) |session, index| {
            if (session.handle() == handle) {
                self.closeSession(index);
                return true;
            }
        }
        return false;
    }

    pub fn closeSession(self: *Self, index: usize) void {
        const priv = self.private();
        if (index >= priv.sessions.items.len) return;

        const session = priv.sessions.orderedRemove(index);
        priv.stack.remove(session.as(gtk.Widget));
        session.unref();

        if (priv.sessions.items.len == 0) {
            priv.active_session_index = null;
            self.showNav(if (priv.active_workspace == null) .welcome else .dashboard);
            return;
        }

        const next_index = if (index >= priv.sessions.items.len) priv.sessions.items.len - 1 else index;
        self.showSession(next_index);
    }

    fn closeAllSessions(self: *Self) void {
        const priv = self.private();
        for (priv.sessions.items) |session| {
            priv.stack.remove(session.as(gtk.Widget));
            session.unref();
        }
        priv.sessions.clearRetainingCapacity();
        priv.active_session_index = null;
    }

    pub fn inspectRun(self: *Self, run_id: []const u8) void {
        self.openSession(smithers.c.SMITHERS_SESSION_KIND_RUN_INSPECT, run_id) catch |err| {
            self.showToastFmt("Run inspector failed: {}", .{err});
            self.private().run_inspect_view.setRun(run_id);
            self.showNav(.run_inspect);
        };
    }

    fn buildShell(self: *Self) !void {
        const priv = self.private();
        self.as(gtk.Window).setTitle("Smithers");
        self.as(gtk.Window).setDefaultSize(1180, 760);

        priv.toast_overlay = adw.ToastOverlay.new();
        priv.split_view = adw.NavigationSplitView.new();
        priv.split_view.setMinSidebarWidth(240);
        priv.split_view.setMaxSidebarWidth(360);
        priv.split_view.setSidebarWidthFraction(0.25);

        priv.sidebar = try Sidebar.new(self);
        const sidebar_page = adw.NavigationPage.new(priv.sidebar.as(gtk.Widget), "Smithers");
        priv.split_view.setSidebar(sidebar_page);

        const toolbar = adw.ToolbarView.new();
        const header = adw.HeaderBar.new();
        priv.title_label = ui.heading("Welcome");
        header.setTitleWidget(priv.title_label.as(gtk.Widget));

        const palette = ui.iconButton("system-search-symbolic", "Command palette");
        _ = gtk.Button.signals.clicked.connect(palette, *Self, paletteClicked, self, .{});
        header.packEnd(palette.as(gtk.Widget));

        const refresh = ui.iconButton("view-refresh-symbolic", "Refresh");
        _ = gtk.Button.signals.clicked.connect(refresh, *Self, refreshClicked, self, .{});
        header.packEnd(refresh.as(gtk.Widget));

        toolbar.addTopBar(header.as(gtk.Widget));
        priv.stack = gtk.Stack.new();
        priv.stack.setTransitionType(.crossfade);
        toolbar.setContent(priv.stack.as(gtk.Widget));
        const content_page = adw.NavigationPage.new(toolbar.as(gtk.Widget), "Smithers");
        priv.split_view.setContent(content_page);
        priv.toast_overlay.setChild(priv.split_view.as(gtk.Widget));
        self.as(adw.ApplicationWindow).setContent(priv.toast_overlay.as(gtk.Widget));

        try self.buildPages();
    }

    fn buildPages(self: *Self) !void {
        const priv = self.private();
        _ = priv.stack.addTitled(try self.buildWelcome(), "welcome", "Welcome");

        priv.dashboard_view = try DashboardView.new(self);
        _ = priv.stack.addTitled(priv.dashboard_view.as(gtk.Widget), "dashboard", "Dashboard");

        priv.vcs_dashboard_view = try VCSDashboardView.new(self);
        _ = priv.stack.addTitled(priv.vcs_dashboard_view.as(gtk.Widget), "vcs-dashboard", "VCS Dashboard");

        priv.workflows_view = try WorkflowsView.new(self);
        _ = priv.stack.addTitled(priv.workflows_view.as(gtk.Widget), "workflows", "Workflows");

        priv.jjhub_workflows_view = try JJHubWorkflowsView.new(self);
        _ = priv.stack.addTitled(priv.jjhub_workflows_view.as(gtk.Widget), "jjhub-workflows", "JJHub Workflows");

        priv.runs_view = try RunsView.new(self);
        _ = priv.stack.addTitled(priv.runs_view.as(gtk.Widget), "runs", "Runs");

        priv.run_inspect_view = try RunInspectView.new(self);
        _ = priv.stack.addTitled(priv.run_inspect_view.as(gtk.Widget), "run-inspect", "Run Inspector");

        priv.approvals_view = try ApprovalsView.new(self);
        _ = priv.stack.addTitled(priv.approvals_view.as(gtk.Widget), "approvals", "Approvals");

        priv.tickets_view = try TicketsView.new(self);
        _ = priv.stack.addTitled(priv.tickets_view.as(gtk.Widget), "tickets", "Tickets");

        priv.changes_view = try ChangesView.new(self);
        _ = priv.stack.addTitled(priv.changes_view.as(gtk.Widget), "changes", "Changes");

        priv.issues_view = try IssuesView.new(self);
        _ = priv.stack.addTitled(priv.issues_view.as(gtk.Widget), "issues", "Issues");

        priv.landings_view = try LandingsView.new(self);
        _ = priv.stack.addTitled(priv.landings_view.as(gtk.Widget), "landings", "Landings");

        priv.agents_view = try AgentsView.new(self);
        _ = priv.stack.addTitled(priv.agents_view.as(gtk.Widget), "agents", "Agents");

        priv.prompts_view = try PromptsView.new(self);
        _ = priv.stack.addTitled(priv.prompts_view.as(gtk.Widget), "prompts", "Prompts");

        priv.scores_view = try ScoresView.new(self);
        _ = priv.stack.addTitled(priv.scores_view.as(gtk.Widget), "scores", "Scores");

        priv.memory_view = try MemoryView.new(self);
        _ = priv.stack.addTitled(priv.memory_view.as(gtk.Widget), "memory", "Memory");

        priv.triggers_view = try TriggersView.new(self);
        _ = priv.stack.addTitled(priv.triggers_view.as(gtk.Widget), "triggers", "Triggers");

        priv.workspaces_box = gtk.Box.new(.vertical, 16);
        ui.margin(priv.workspaces_box.as(gtk.Widget), 24);
        _ = priv.stack.addTitled(ui.scrolled(priv.workspaces_box.as(gtk.Widget)).as(gtk.Widget), "workspaces", "Workspaces");

        priv.settings_box = gtk.Box.new(.vertical, 16);
        ui.margin(priv.settings_box.as(gtk.Widget), 24);
        try self.populateSettings();
        _ = priv.stack.addTitled(ui.scrolled(priv.settings_box.as(gtk.Widget)).as(gtk.Widget), "settings", "Settings");
    }

    fn listPage(self: *Self, name: [:0]const u8, title: [:0]const u8) *gtk.ListBox {
        const box = gtk.Box.new(.vertical, 12);
        ui.margin(box.as(gtk.Widget), 24);
        box.append(ui.heading(title).as(gtk.Widget));
        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("boxed-list");
        list.setSelectionMode(.none);
        list.setShowSeparators(1);
        box.append(list.as(gtk.Widget));
        _ = self.private().stack.addTitled(ui.scrolled(box.as(gtk.Widget)).as(gtk.Widget), name.ptr, title.ptr);
        return list;
    }

    fn buildWelcome(self: *Self) !*gtk.Widget {
        const alloc = self.allocator();
        const box = gtk.Box.new(.vertical, 18);
        ui.margin(box.as(gtk.Widget), 32);
        box.as(gtk.Widget).setValign(.center);
        box.as(gtk.Widget).setHalign(.center);
        box.as(gtk.Widget).setSizeRequest(520, -1);

        box.append(ui.heading("Smithers").as(gtk.Widget));
        box.append(ui.dim("Open a workspace to inspect workflows, runs, approvals, agents, and durable sessions.").as(gtk.Widget));

        const path_row = gtk.Box.new(.horizontal, 8);
        const cwd = smithers.cwdResolve(alloc, null) catch try alloc.dupe(u8, ".");
        defer alloc.free(cwd);
        const cwd_z = try alloc.dupeZ(u8, cwd);
        defer alloc.free(cwd_z);

        self.private().workspace_entry = gtk.Entry.new();
        self.private().workspace_entry.as(gtk.Editable).setText(cwd_z.ptr);
        self.private().workspace_entry.setPlaceholderText("Workspace path");
        self.private().workspace_entry.as(gtk.Widget).setHexpand(1);
        path_row.append(self.private().workspace_entry.as(gtk.Widget));

        const open = ui.textButton("Open", true);
        _ = gtk.Button.signals.clicked.connect(open, *Self, openWorkspaceClicked, self, .{});
        path_row.append(open.as(gtk.Widget));
        box.append(path_row.as(gtk.Widget));

        const recent_button = ui.textButton("Recent Workspaces", false);
        _ = gtk.Button.signals.clicked.connect(recent_button, *Self, workspacesClicked, self, .{});
        box.append(recent_button.as(gtk.Widget));
        return box.as(gtk.Widget);
    }

    fn loadInitialWorkspace(self: *Self) !void {
        const alloc = self.allocator();
        if (smithers.activeWorkspacePath(alloc, self.private().app.core())) |path| {
            defer alloc.free(path);
            if (path.len > 0) {
                self.private().active_workspace = try alloc.dupe(u8, path);
                try self.refreshAll();
                self.showNav(.dashboard);
                return;
            }
        } else |_| {}
        self.showNav(.welcome);
    }

    fn refreshAll(self: *Self) !void {
        try self.loadWorkflows();
        try self.loadRuns();
        try self.loadApprovals();
        try self.loadAgents();
        try self.loadWorkspaces();
    }

    fn loadWorkflows(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.private().app.client(), "listWorkflows", "{}");
        defer alloc.free(json);
        const parsed = try models.parseWorkflows(alloc, json);
        models.clearList(models.Workflow, alloc, &self.private().workflows);
        self.private().workflows = parsed;
    }

    fn loadRuns(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.private().app.client(), "listRuns", "{}");
        defer alloc.free(json);
        const parsed = try models.parseRuns(alloc, json);
        models.clearList(models.RunSummary, alloc, &self.private().runs);
        self.private().runs = parsed;
    }

    fn loadApprovals(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.private().app.client(), "listPendingApprovals", "{}");
        defer alloc.free(json);
        const parsed = try models.parseApprovals(alloc, json);
        models.clearList(models.Approval, alloc, &self.private().approvals);
        self.private().approvals = parsed;
    }

    fn loadAgents(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.private().app.client(), "listAgents", "{}");
        defer alloc.free(json);
        const parsed = try models.parseAgents(alloc, json);
        models.clearList(models.Agent, alloc, &self.private().agents);
        self.private().agents = parsed;
    }

    fn loadWorkspaces(self: *Self) !void {
        const alloc = self.allocator();
        const json = smithers.callJson(alloc, self.private().app.client(), "listWorkspaces", "{}") catch
            try smithers.recentWorkspacesJson(alloc, self.private().app.core());
        defer alloc.free(json);
        const parsed = try models.parseWorkspaces(alloc, json);
        models.clearList(models.Workspace, alloc, &self.private().workspaces);
        self.private().workspaces = parsed;
    }

    fn refreshDashboard(self: *Self) !void {
        try self.refreshAll();
        const priv = self.private();
        ui.clearBox(priv.dashboard_box);
        priv.dashboard_box.append(ui.heading("Dashboard").as(gtk.Widget));

        if (priv.active_workspace) |path| {
            const z = try self.allocator().dupeZ(u8, path);
            defer self.allocator().free(z);
            priv.dashboard_box.append(ui.dim(z).as(gtk.Widget));
        } else {
            priv.dashboard_box.append(ui.dim("No workspace selected").as(gtk.Widget));
        }

        const stats = gtk.Box.new(.horizontal, 12);
        stats.as(gtk.Widget).setHexpand(1);
        try self.addMetric(stats, "Runs", priv.runs.items.len, "recent workflow executions");
        try self.addMetric(stats, "Workflows", priv.workflows.items.len, "available workflow definitions");
        try self.addMetric(stats, "Approvals", priv.approvals.items.len, "pending approval gates");
        try self.addMetric(stats, "Agents", priv.agents.items.len, "detected local agents");
        priv.dashboard_box.append(stats.as(gtk.Widget));

        const recent = gtk.ListBox.new();
        recent.as(gtk.Widget).addCssClass("boxed-list");
        recent.setSelectionMode(.none);
        recent.setShowSeparators(1);
        _ = gtk.ListBox.signals.row_activated.connect(recent, *Self, runRowActivated, self, .{});
        const max = @min(priv.runs.items.len, 5);
        if (max == 0) {
            recent.append((try ui.row(self.allocator(), "view-list-symbolic", "No recent runs", "Runs will appear here after workflows start.")).as(gtk.Widget));
        } else {
            for (priv.runs.items[0..max], 0..) |run, index| {
                const title = run.workflow_name orelse run.run_id;
                const subtitle = try std.fmt.allocPrint(self.allocator(), "{s} - {s}", .{ run.run_id, run.status });
                defer self.allocator().free(subtitle);
                const row = try ui.row(self.allocator(), runIcon(run.status), title, subtitle);
                ui.setIndex(row.as(gobject.Object), index);
                recent.append(row.as(gtk.Widget));
            }
        }
        priv.dashboard_box.append(ui.heading("Recent Runs").as(gtk.Widget));
        priv.dashboard_box.append(recent.as(gtk.Widget));
    }

    fn addMetric(self: *Self, parent: *gtk.Box, title: []const u8, value: usize, detail: []const u8) !void {
        const alloc = self.allocator();
        const box = gtk.Box.new(.vertical, 4);
        box.as(gtk.Widget).setHexpand(1);
        box.as(gtk.Widget).addCssClass("card");
        ui.margin(box.as(gtk.Widget), 12);
        const value_z = try std.fmt.allocPrintSentinel(alloc, "{d}", .{value}, 0);
        defer alloc.free(value_z);
        const title_z = try alloc.dupeZ(u8, title);
        defer alloc.free(title_z);
        const detail_z = try alloc.dupeZ(u8, detail);
        defer alloc.free(detail_z);
        box.append(ui.heading(value_z).as(gtk.Widget));
        box.append(ui.label(title_z, "heading").as(gtk.Widget));
        box.append(ui.dim(detail_z).as(gtk.Widget));
        parent.append(box.as(gtk.Widget));
    }

    fn refreshWorkflows(self: *Self) !void {
        try self.loadWorkflows();
        const list = self.private().workflows_list;
        ui.clearList(list);
        if (self.private().workflows.items.len == 0) {
            list.append((try ui.row(self.allocator(), "emblem-documents-symbolic", "No workflows found", "Create .smithers/workflows entries to launch them here.")).as(gtk.Widget));
            return;
        }
        for (self.private().workflows.items, 0..) |workflow, index| {
            const row = gtk.ListBoxRow.new();
            row.setActivatable(1);
            ui.setIndex(row.as(gobject.Object), index);
            const box = gtk.Box.new(.horizontal, 12);
            ui.margin(box.as(gtk.Widget), 10);
            const text = gtk.Box.new(.vertical, 3);
            text.as(gtk.Widget).setHexpand(1);
            const name_z = try self.allocator().dupeZ(u8, workflow.name);
            defer self.allocator().free(name_z);
            text.append(ui.label(name_z, "heading").as(gtk.Widget));
            const path = workflow.relative_path orelse workflow.id;
            const subtitle = try std.fmt.allocPrintSentinel(self.allocator(), "{s} - {s}", .{ path, workflow.status }, 0);
            defer self.allocator().free(subtitle);
            text.append(ui.dim(subtitle).as(gtk.Widget));
            box.append(text.as(gtk.Widget));
            const run = ui.textButton("Run", true);
            ui.setIndex(run.as(gobject.Object), index);
            _ = gtk.Button.signals.clicked.connect(run, *Self, workflowRunClicked, self, .{});
            box.append(run.as(gtk.Widget));
            row.setChild(box.as(gtk.Widget));
            list.append(row.as(gtk.Widget));
        }
    }

    fn refreshRuns(self: *Self) !void {
        try self.loadRuns();
        const list = self.private().runs_list;
        ui.clearList(list);
        if (self.private().runs.items.len == 0) {
            list.append((try ui.row(self.allocator(), "media-playback-start-symbolic", "No runs found", "Launch a workflow to inspect run state.")).as(gtk.Widget));
            return;
        }
        for (self.private().runs.items, 0..) |run, index| {
            const title = run.workflow_name orelse run.run_id;
            const detail = try std.fmt.allocPrint(self.allocator(), "{s} - {s} - {d}/{d} nodes", .{
                run.run_id,
                run.status,
                run.finished + run.failed,
                run.total,
            });
            defer self.allocator().free(detail);
            const row = try ui.row(self.allocator(), runIcon(run.status), title, detail);
            ui.setIndex(row.as(gobject.Object), index);
            list.append(row.as(gtk.Widget));
        }
    }

    fn refreshApprovals(self: *Self) !void {
        try self.loadApprovals();
        const list = self.private().approvals_list;
        ui.clearList(list);
        if (self.private().approvals.items.len == 0) {
            list.append((try ui.row(self.allocator(), "emblem-ok-symbolic", "No pending approvals", "Approval gates will appear here when a run pauses.")).as(gtk.Widget));
            return;
        }
        for (self.private().approvals.items, 0..) |approval, index| {
            const title = approval.gate orelse approval.node_id;
            const subtitle = if (approval.iteration) |iteration|
                try std.fmt.allocPrint(self.allocator(), "Run {s} - node {s} - iteration {d} - {s}", .{ approval.run_id, approval.node_id, iteration, approval.status })
            else
                try std.fmt.allocPrint(self.allocator(), "Run {s} - node {s} - {s}", .{ approval.run_id, approval.node_id, approval.status });
            defer self.allocator().free(subtitle);

            const row = gtk.ListBoxRow.new();
            row.setActivatable(0);
            row.setSelectable(0);
            const box = gtk.Box.new(.horizontal, 12);
            ui.margin(box.as(gtk.Widget), 10);

            const icon = gtk.Image.newFromIconName("security-high-symbolic");
            icon.setPixelSize(20);
            icon.as(gtk.Widget).setValign(.center);
            box.append(icon.as(gtk.Widget));

            const text = gtk.Box.new(.vertical, 3);
            text.as(gtk.Widget).setHexpand(1);
            const title_z = try self.allocator().dupeZ(u8, title);
            defer self.allocator().free(title_z);
            text.append(ui.label(title_z, "heading").as(gtk.Widget));
            const subtitle_z = try self.allocator().dupeZ(u8, subtitle);
            defer self.allocator().free(subtitle_z);
            text.append(ui.dim(subtitle_z).as(gtk.Widget));
            box.append(text.as(gtk.Widget));

            const approve = ui.textButton("Approve", true);
            ui.setIndex(approve.as(gobject.Object), index);
            _ = gtk.Button.signals.clicked.connect(approve, *Self, approveClicked, self, .{});
            box.append(approve.as(gtk.Widget));

            const deny = ui.textButton("Deny", false);
            deny.as(gtk.Widget).addCssClass("destructive-action");
            ui.setIndex(deny.as(gobject.Object), index);
            _ = gtk.Button.signals.clicked.connect(deny, *Self, denyClicked, self, .{});
            box.append(deny.as(gtk.Widget));

            row.setChild(box.as(gtk.Widget));
            list.append(row.as(gtk.Widget));
        }
    }

    fn refreshAgents(self: *Self) !void {
        try self.loadAgents();
        const list = self.private().agents_list;
        ui.clearList(list);
        if (self.private().agents.items.len == 0) {
            list.append((try ui.row(self.allocator(), "system-users-symbolic", "No agents detected", "Install Claude Code, Codex, or another supported agent.")).as(gtk.Widget));
            return;
        }
        for (self.private().agents.items) |agent| {
            const subtitle = try std.fmt.allocPrint(self.allocator(), "{s}{s}{s}", .{
                agent.status,
                if (agent.version != null) " - " else "",
                agent.version orelse "",
            });
            defer self.allocator().free(subtitle);
            list.append((try ui.row(self.allocator(), if (agent.usable) "emblem-ok-symbolic" else "dialog-warning-symbolic", agent.name, subtitle)).as(gtk.Widget));
        }
    }

    fn refreshWorkspacesPage(self: *Self) !void {
        try self.loadWorkspaces();
        const box = self.private().workspaces_box;
        ui.clearBox(box);
        box.append(ui.heading("Workspaces").as(gtk.Widget));
        box.append(ui.dim("Recent and JJHub workspaces known to Smithers.").as(gtk.Widget));

        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("boxed-list");
        list.setSelectionMode(.none);
        list.setShowSeparators(1);
        _ = gtk.ListBox.signals.row_activated.connect(list, *Self, workspaceRowActivated, self, .{});
        if (self.private().workspaces.items.len == 0) {
            list.append((try ui.row(self.allocator(), "folder-symbolic", "No recent workspaces", "Open a directory from the welcome screen.")).as(gtk.Widget));
        } else {
            for (self.private().workspaces.items, 0..) |workspace, index| {
                const subtitle = workspace.status orelse workspace.id;
                const row = try ui.row(self.allocator(), "folder-symbolic", workspace.name, subtitle);
                ui.setIndex(row.as(gobject.Object), index);
                list.append(row.as(gtk.Widget));
            }
        }
        box.append(list.as(gtk.Widget));
    }

    fn populateSettings(self: *Self) !void {
        const box = self.private().settings_box;
        ui.clearBox(box);
        box.append(ui.heading("Settings").as(gtk.Widget));
        box.append(ui.dim("Keyboard shortcuts").as(gtk.Widget));
        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("boxed-list");
        list.setSelectionMode(.none);
        list.setShowSeparators(1);
        list.append((try ui.row(self.allocator(), "system-search-symbolic", "Command Palette", "Ctrl+K")).as(gtk.Widget));
        list.append((try ui.row(self.allocator(), "tab-new-symbolic", "New Tab", "Ctrl+N or Ctrl+T")).as(gtk.Widget));
        list.append((try ui.row(self.allocator(), "window-close-symbolic", "Close Tab", "Ctrl+W")).as(gtk.Widget));
        list.append((try ui.row(self.allocator(), "view-refresh-symbolic", "Refresh Current View", "Toolbar refresh button")).as(gtk.Widget));
        box.append(list.as(gtk.Widget));
    }

    fn populateInspector(self: *Self, run_id: []const u8) !void {
        const alloc = self.allocator();
        const args = try jsonObject1(alloc, "runId", run_id);
        defer alloc.free(args);
        const json = try smithers.callJson(alloc, self.private().app.client(), "inspectRun", args);
        defer alloc.free(json);
        var inspection = try models.parseRunInspection(alloc, json);
        defer inspection.deinit(alloc);

        const box = self.private().inspector_box;
        ui.clearBox(box);
        const title = inspection.run.workflow_name orelse inspection.run.run_id;
        const title_z = try alloc.dupeZ(u8, title);
        defer alloc.free(title_z);
        box.append(ui.heading(title_z).as(gtk.Widget));
        const summary = try std.fmt.allocPrintSentinel(alloc, "{s} - {s} - {d}/{d} nodes", .{
            inspection.run.run_id,
            inspection.run.status,
            inspection.run.finished + inspection.run.failed,
            inspection.run.total,
        }, 0);
        defer alloc.free(summary);
        box.append(ui.dim(summary).as(gtk.Widget));

        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("boxed-list");
        list.setSelectionMode(.none);
        list.setShowSeparators(1);
        if (inspection.tasks.items.len == 0) {
            list.append((try ui.row(alloc, "view-list-symbolic", "No task details", "The run inspector returned no node records.")).as(gtk.Widget));
        } else {
            for (inspection.tasks.items) |task| {
                const label = task.label orelse task.node_id;
                list.append((try ui.row(alloc, taskIcon(task.state), label, task.state)).as(gtk.Widget));
            }
        }
        box.append(list.as(gtk.Widget));
    }

    fn launchWorkflow(self: *Self, index: usize) void {
        if (index >= self.private().workflows.items.len) return;
        const workflow = self.private().workflows.items[index];
        const path = workflow.relative_path orelse workflow.id;
        const args = jsonObject1(self.allocator(), "workflowPath", path) catch {
            self.showToast("Unable to encode workflow launch");
            return;
        };
        defer self.allocator().free(args);
        const json = smithers.callJson(self.allocator(), self.private().app.client(), "runWorkflow", args) catch |err| {
            self.showToastFmt("Workflow launch failed: {}", .{err});
            return;
        };
        defer self.allocator().free(json);
        self.showToastFmt("Launched {s}", .{workflow.name});
        self.showNav(.runs);
    }

    fn completeApproval(self: *Self, index: usize, method: []const u8, verb: []const u8) void {
        if (index >= self.private().approvals.items.len) return;
        const approval = self.private().approvals.items[index];
        const args = approvalArgs(self.allocator(), approval) catch {
            self.showToast("Unable to encode approval action");
            return;
        };
        defer self.allocator().free(args);
        const json = smithers.callJson(self.allocator(), self.private().app.client(), method, args) catch |err| {
            self.showToastFmt("{s} failed: {}", .{ verb, err });
            return;
        };
        defer self.allocator().free(json);
        self.showToastFmt("{s} {s}", .{ verb, approval.gate orelse approval.node_id });
        self.refreshApprovals() catch |err| self.showToastFmt("Approval refresh failed: {}", .{err});
    }

    fn setTitle(self: *Self, text: [:0]const u8) void {
        self.private().title_label.setText(text.ptr);
    }

    fn jsonObject1(alloc: std.mem.Allocator, comptime key: []const u8, value: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = try .initCapacity(alloc, value.len + key.len + 16);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField(key);
        try jw.write(value);
        try jw.endObject();
        return try out.toOwnedSlice();
    }

    fn approvalArgs(alloc: std.mem.Allocator, approval: models.Approval) ![]u8 {
        var out: std.Io.Writer.Allocating = try .initCapacity(alloc, approval.run_id.len + approval.node_id.len + 64);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("runId");
        try jw.write(approval.run_id);
        try jw.objectField("nodeId");
        try jw.write(approval.node_id);
        if (approval.iteration) |iteration| {
            try jw.objectField("iteration");
            try jw.write(iteration);
        }
        try jw.endObject();
        return try out.toOwnedSlice();
    }

    fn runIcon(status: []const u8) [:0]const u8 {
        if (std.ascii.eqlIgnoreCase(status, "running")) return "media-playback-start-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "waiting-approval") or std.ascii.eqlIgnoreCase(status, "blocked")) return "security-high-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "finished")) return "emblem-ok-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "failed")) return "dialog-error-symbolic";
        return "view-list-symbolic";
    }

    fn taskIcon(status: []const u8) [:0]const u8 {
        if (std.ascii.eqlIgnoreCase(status, "running")) return "media-playback-start-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "finished")) return "emblem-ok-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "failed")) return "dialog-error-symbolic";
        if (std.ascii.eqlIgnoreCase(status, "blocked") or std.ascii.eqlIgnoreCase(status, "waiting-approval")) return "security-high-symbolic";
        return "view-list-symbolic";
    }

    fn paletteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.presentCommandPalette();
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refreshVisible();
    }

    fn workspacesClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showNav(.workspaces);
    }

    fn openWorkspaceClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const text = std.mem.span(self.private().workspace_entry.as(gtk.Editable).getText());
        self.openWorkspace(text) catch |err| self.showToastFmt("Open workspace failed: {}", .{err});
    }

    fn workflowRunClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        self.launchWorkflow(index);
    }

    fn approveClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        self.completeApproval(index, "approveNode", "Approved");
    }

    fn denyClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        self.completeApproval(index, "denyNode", "Denied");
    }

    fn workflowRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = ui.getIndex(row.as(gobject.Object)) orelse return;
        self.launchWorkflow(index);
    }

    fn runRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = ui.getIndex(row.as(gobject.Object)) orelse return;
        if (index >= self.private().runs.items.len) return;
        self.inspectRun(self.private().runs.items[index].run_id);
    }

    fn workspaceRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const index = ui.getIndex(row.as(gobject.Object)) orelse return;
        if (index >= self.private().workspaces.items.len) return;
        self.openWorkspace(self.private().workspaces.items[index].id) catch |err| {
            self.showToastFmt("Open workspace failed: {}", .{err});
        };
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            const alloc = self.allocator();
            if (priv.command_palette) |palette| {
                palette.unref();
                priv.command_palette = null;
            }
            if (priv.new_tab_picker) |picker| {
                picker.unref();
                priv.new_tab_picker = null;
            }
            if (priv.workspace_handle) |ws| {
                smithers.c.smithers_app_close_workspace(priv.app.core(), ws);
                priv.workspace_handle = null;
            }
            if (priv.active_workspace) |path| {
                alloc.free(path);
                priv.active_workspace = null;
            }
            models.clearList(models.Workflow, alloc, &priv.workflows);
            priv.workflows.deinit(alloc);
            models.clearList(models.RunSummary, alloc, &priv.runs);
            priv.runs.deinit(alloc);
            models.clearList(models.Approval, alloc, &priv.approvals);
            priv.approvals.deinit(alloc);
            models.clearList(models.Agent, alloc, &priv.agents);
            priv.agents.deinit(alloc);
            models.clearList(models.Workspace, alloc, &priv.workspaces);
            priv.workspaces.deinit(alloc);
            for (priv.sessions.items) |session| session.unref();
            priv.sessions.deinit(alloc);

            self.as(adw.ApplicationWindow).setContent(null);
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
