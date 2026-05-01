//! GObject class exports and shared helpers for the Smithers GTK apprt.

const gobject = @import("gobject");

pub const Application = @import("class/application.zig").Application;
pub const BrowserSurface = @import("class/browser_surface.zig").BrowserSurface;
pub const ChatView = @import("class/chat.zig").ChatView;
pub const CommandPalette = @import("class/command_palette.zig").CommandPalette;
pub const DeveloperDebugView = @import("class/developer_debug.zig").DeveloperDebugView;
pub const DiffHunk = @import("class/diff_hunk.zig");
pub const FrameScrubber = @import("class/live_run_frame_scrubber.zig").FrameScrubber;
pub const HeartbeatView = @import("class/heartbeat.zig").HeartbeatView;
pub const LiveRunHeader = @import("class/live_run_header.zig").LiveRunHeader;
pub const LiveRunOutput = @import("class/live_run_output.zig").LiveRunOutput;
pub const LiveRunTree = @import("class/live_run_tree.zig").LiveRunTree;
pub const LiveRunView = @import("class/live_run.zig").LiveRunView;
pub const LogsViewer = @import("class/logs_viewer.zig").LogsViewer;
pub const MainWindow = @import("class/main_window.zig").MainWindow;
pub const MarkdownEditor = @import("class/markdown_editor.zig").MarkdownEditor;
pub const MarkdownSurface = @import("class/markdown.zig").MarkdownSurface;
pub const NewTabPicker = @import("class/new_tab_picker.zig").NewTabPicker;
pub const NodeInspector = @import("class/node_inspector.zig").NodeInspector;
pub const PropsTable = @import("class/props_table.zig").PropsTable;
pub const QuickLaunchConfirmSheet = @import("class/quick_launch.zig").QuickLaunchConfirmSheet;
pub const SearchView = @import("class/search.zig").SearchView;
pub const SessionWidget = @import("class/session.zig").SessionWidget;
pub const ShortcutRecorder = @import("class/shortcut_recorder.zig").ShortcutRecorder;
pub const Sidebar = @import("class/sidebar.zig").Sidebar;
pub const TerminalSurface = @import("class/terminal.zig").TerminalSurface;
pub const UnifiedDiffView = @import("class/diff.zig").UnifiedDiffView;
pub const WorkspaceContent = @import("class/workspace_content.zig").WorkspaceContent;
pub const AgentsView = @import("class/view_agents.zig").AgentsView;
pub const ApprovalsView = @import("class/view_approvals.zig").ApprovalsView;
pub const ChangesView = @import("class/view_changes.zig").ChangesView;
pub const DashboardView = @import("class/view_dashboard.zig").DashboardView;
pub const IssuesView = @import("class/view_issues.zig").IssuesView;
pub const JJHubWorkflowsView = @import("class/view_jjhub_workflows.zig").JJHubWorkflowsView;
pub const LandingsView = @import("class/view_landings.zig").LandingsView;
pub const MemoryView = @import("class/view_memory.zig").MemoryView;
pub const PromptsView = @import("class/view_prompts.zig").PromptsView;
pub const RunInspectView = @import("class/view_run_inspect.zig").RunInspectView;
pub const RunsView = @import("class/view_runs.zig").RunsView;
pub const ScoresView = @import("class/view_scores.zig").ScoresView;
pub const TicketsView = @import("class/view_tickets.zig").TicketsView;
pub const TriggersView = @import("class/view_triggers.zig").TriggersView;
pub const VCSDashboardView = @import("class/view_vcs_dashboard.zig").VCSDashboardView;
pub const WorkflowsView = @import("class/view_workflows.zig").WorkflowsView;

pub fn Common(comptime Self: type, comptime Private: ?type) type {
    return struct {
        pub fn as(self: *Self, comptime T: type) *T {
            return gobject.ext.as(T, self);
        }

        pub fn ref(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.ref(self.as(gobject.Object))));
        }

        pub fn refSink(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.refSink(self.as(gobject.Object))));
        }

        pub fn unref(self: *Self) void {
            gobject.Object.unref(self.as(gobject.Object));
        }

        pub const private = if (Private) |P| (struct {
            fn private(self: *Self) *P {
                return gobject.ext.impl_helpers.getPrivate(self, P, P.offset);
            }
        }).private else {};

        pub const Class = struct {
            pub fn as(class: *Self.Class, comptime T: type) *T {
                return gobject.ext.as(T, class);
            }
        };
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
