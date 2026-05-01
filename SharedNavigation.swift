// SharedNavigation.swift
//
// Shared navigation/state owner for the Smithers app shell. Extracted from
// ContentView.swift and SidebarView.swift as part of ticket 0122. Both the
// macOS and iOS app shells observe this store so destination and history
// state stay platform-neutral.
//
// IMPORTANT: This file is compiled into BOTH the macOS (`SmithersGUI`) and
// iOS (`SmithersiOS`) targets. It must not pull in AppKit (or UIKit) and
// must not reference any AppKit-only symbols (open-panel, workspace-open,
// app-terminate, pasteboard, key-window, screen geometry).

import Foundation
import SwiftUI

// MARK: - Navigation Destination

/// The cross-platform route vocabulary for the Smithers app shell.
///
/// The macOS `NavigationSplitView` shell and the iOS `NavigationStack`
/// shell both drive navigation off of this single enum. Destinations that
/// only make sense on one platform (e.g. multi-surface terminal workspaces)
/// still live here so the shared shell code does not have to branch on
/// `#if os(macOS)` for routing decisions.
enum NavDestination: Hashable {
    case home
    case dashboard
    case vcsDashboard
    case agents
    case changes
    case runs
    case snapshots
    case workflows
    case triggers
    case jjhubWorkflows
    case approvals
    case prompts
    case scores
    case memory
    case search
    case sql
    case landings
    case tickets
    case issues
    case terminal(id: String = "default")
    case terminalCommand(binary: String, workingDirectory: String, name: String)
    case liveRun(runId: String, nodeId: String?)
    case runInspect(runId: String, workflowName: String?)
    case workspaces
    case logs
    case settings

    var isTerminal: Bool {
        if case .terminal = self { return true }
        if case .terminalCommand = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .terminal: return "Terminal"
        case .terminalCommand(binary: _, workingDirectory: _, name: let name): return name
        case .liveRun: return "Live Run"
        case .runInspect: return "Run Inspector"
        case .dashboard: return "Dashboard"
        case .vcsDashboard: return "VCS Dashboard"
        case .agents: return "Agents"
        case .changes: return "Changes"
        case .runs: return "Runs"
        case .snapshots: return "Snapshots"
        case .workflows: return "Workflows"
        case .triggers: return "Triggers"
        case .jjhubWorkflows: return "JJHub Workflows"
        case .approvals: return "Approvals"
        case .prompts: return "Prompts"
        case .scores: return "Scores"
        case .memory: return "Memory"
        case .search: return "Search"
        case .sql: return "SQL Browser"
        case .landings: return "Landings"
        case .tickets: return "Tickets"
        case .issues: return "Issues"
        case .workspaces: return "Workspaces"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .terminal: return "terminal.fill"
        case .terminalCommand(binary: _, workingDirectory: _, name: _): return "terminal.fill"
        case .liveRun: return "dot.radiowaves.left.and.right"
        case .runInspect: return "sidebar.right"
        case .dashboard: return "square.grid.2x2"
        case .vcsDashboard: return "point.3.connected.trianglepath.dotted"
        case .agents: return "person.2"
        case .changes: return "point.3.connected.trianglepath.dotted"
        case .runs: return "play.circle"
        case .snapshots: return "camera"
        case .workflows: return "arrow.triangle.branch"
        case .triggers: return "clock.arrow.circlepath"
        case .jjhubWorkflows: return "point.3.filled.connected.trianglepath.dotted"
        case .approvals: return "checkmark.shield"
        case .prompts: return "doc.text"
        case .scores: return "chart.bar"
        case .memory: return "brain"
        case .search: return "magnifyingglass"
        case .sql: return "tablecells"
        case .landings: return "arrow.down.to.line"
        case .tickets: return "ticket"
        case .issues: return "exclamationmark.circle"
        case .workspaces: return "desktopcomputer"
        case .logs: return "doc.text.below.ecg"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Navigation State Store

/// Shared observable navigation state. Owns the current destination plus
/// navigation history so both platform shells can wire back/forward,
/// palette navigation, and route handoffs through the same model.
@MainActor
final class NavigationStateStore: ObservableObject {
    @Published var destination: NavDestination
    @Published private(set) var history: [NavDestination]
    @Published private(set) var historyIndex: Int

    private var isNavigatingThroughHistory = false
    private let historyCap: Int

    init(initialDestination: NavDestination = .home, historyCap: Int = 50) {
        self.destination = initialDestination
        self.history = [initialDestination]
        self.historyIndex = 0
        self.historyCap = historyCap
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    /// Navigate the shell to a new destination. Caller wires
    /// `recordHistory(_:)` from `onChange(of: destination)` so SwiftUI
    /// stays the source-of-truth for destination updates regardless of how
    /// navigation was triggered (palette, sidebar, shortcut).
    func navigate(to next: NavDestination) {
        destination = next
    }

    /// Record history after SwiftUI dispatches `onChange(of: destination)`.
    /// Call exactly once per external destination change.
    func recordHistory(_ next: NavDestination) {
        if isNavigatingThroughHistory {
            isNavigatingThroughHistory = false
            return
        }
        if history.indices.contains(historyIndex), history[historyIndex] == next {
            return
        }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(next)
        historyIndex = history.count - 1
        trimHistoryIfNeeded()
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        isNavigatingThroughHistory = true
        destination = history[historyIndex]
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        isNavigatingThroughHistory = true
        destination = history[historyIndex]
    }

    private func trimHistoryIfNeeded() {
        if history.count > historyCap {
            let overflow = history.count - historyCap
            history.removeFirst(overflow)
            historyIndex -= overflow
        }
    }
}
