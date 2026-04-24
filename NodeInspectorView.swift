import SwiftUI
import os

struct NodeInspectorView: View {
    @ObservedObject var store: LiveRunDevToolsStore
    @Binding var selectedTab: InspectorTab
    private let outputProvider: NodeOutputProvider
    private let logsStreamProvider: ChatStreamProviding
    private let logsHistoryProvider: ChatHistoryProviding
    var onOpenPrompt: (() -> Void)? = nil

    @State private var buildStart: CFAbsoluteTime = 0

    @MainActor
    init(
        store: LiveRunDevToolsStore,
        selectedTab: Binding<InspectorTab>,
        outputProvider: NodeOutputProvider? = nil,
        logsStreamProvider: ChatStreamProviding? = nil,
        logsHistoryProvider: ChatHistoryProviding? = nil,
        onOpenPrompt: (() -> Void)? = nil
    ) {
        self.store = store
        _selectedTab = selectedTab
        self.outputProvider = outputProvider ?? SmithersClient()
        self.logsStreamProvider = logsStreamProvider ?? EmptyChatStreamProvider.shared
        self.logsHistoryProvider = logsHistoryProvider ?? EmptyChatHistoryProvider.shared
        self.onOpenPrompt = onOpenPrompt
    }

    private var node: DevToolsNode? {
        store.selectedNode
    }

    private var nodeState: String {
        guard let node else { return "pending" }
        if case .string(let s) = node.props["state"] { return s }
        return "pending"
    }

    private var isTaskNode: Bool {
        node?.type == .task
    }

    private var hasOutput: Bool {
        guard let node else { return false }
        return node.props["output"] != nil
    }

    private var hasDiff: Bool {
        guard let node else { return false }
        return node.props["diff"] != nil
    }

    private var hasLogs: Bool {
        guard let node else { return false }
        return node.props["logs"] != nil
    }

    private var nodeRoleDescription: String {
        guard let node else { return "" }
        switch node.type {
        case .workflow: return "Root workflow container that orchestrates all child tasks."
        case .sequence: return "Runs children in order, one after another."
        case .parallel: return "Runs all children concurrently."
        case .forEach: return "Iterates over a collection, running children for each item."
        case .conditional: return "Conditionally renders children based on a predicate."
        case .mergeQueue: return "Coordinates merge queue execution for child tasks."
        case .branch: return "Represents a branch of workflow execution."
        case .loop: return "Repeats child execution while loop conditions hold."
        case .worktree: return "Represents a worktree-scoped execution context."
        case .approval: return "Represents an approval gate."
        case .timer: return "Represents a timer-driven wait."
        case .subflow: return "Runs a nested workflow."
        case .waitForEvent: return "Waits for an external event signal."
        case .saga: return "Coordinates saga-style compensating tasks."
        case .tryCatch: return "Handles success/failure branches with catch/finally semantics."
        case .fragment: return "Logical grouping node with no direct execution."
        case .task: return "Executable task unit."
        case .unknown: return "Unknown node type."
        }
    }

    private var selectedGhostUnmountedFrameNo: Int? {
        store.selectedGhostRecord?.unmountedFrameNo
    }

    var body: some View {
        VStack(spacing: 0) {
            if let node {
                nodeContent(node)
            } else {
                emptyState
            }
        }
        .background(Theme.surface1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("view.node.inspector")
        .onAppear { buildStart = CFAbsoluteTimeGetCurrent() }
        .onChange(of: store.selectedNodeId) { _ in
            buildStart = CFAbsoluteTimeGetCurrent()
            updateDefaultTab()
            logSelectionChange()
        }
    }

    @ViewBuilder
    private func nodeContent(_ node: DevToolsNode) -> some View {
        NodeInspectorHeader(node: node)

        NodeErrorBanner(
            node: node,
            runSupportsRetry: store.runSupportsRetry,
            onRetry: { nodeId in
                store.retryNode(nodeId: nodeId)
            }
        )

        GhostBanner(
            isVisible: store.isGhost,
            unmountedFrameNo: selectedGhostUnmountedFrameNo
        ) {
            store.clearSelection()
        }

        if isTaskNode {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    propsSection(node)
                }
            }

            InspectorTabSwitcher(
                selectedTab: $selectedTab,
                availableTabs: InspectorTab.allCases
            )

            tabContent
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    propsSection(node)
                    nonTaskFooter
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 24))
                .foregroundColor(Theme.textTertiary)
            Text("Select a node to inspect")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("inspector.empty")
    }

    private func propsSection(_ node: DevToolsNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("props")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)
                .textCase(.uppercase)

            PropsTableView(props: node.props, onOpenPrompt: onOpenPrompt)
        }
        .padding(12)
    }

    private var nonTaskFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().background(Theme.border)
            Text(nodeRoleDescription)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .padding(12)
        }
        .accessibilityIdentifier("inspector.role.description")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .output:
            OutputTab(
                store: store,
                outputProvider: outputProvider
            )
            .accessibilityIdentifier("inspector.tab.content.output")
        case .diff:
            DiffTab(
                runId: store.runId,
                selectedNode: node,
                client: (outputProvider as? NodeDiffFetching) ?? EmptyNodeDiffFetcher.shared
            )
                .accessibilityIdentifier("inspector.tab.content.diff")
        case .logs:
            LogsTab(
                store: store,
                streamProvider: logsStreamProvider,
                historyProvider: logsHistoryProvider
            )
                .accessibilityIdentifier("inspector.tab.content.logs")
        }
    }

    private func updateDefaultTab() {
        guard let node else { return }
        if let defaultTab = DefaultTabPicker.pickDefault(
            nodeType: node.type,
            state: nodeState == "pending" ? nil : nodeState,
            hasOutput: hasOutput,
            hasDiff: hasDiff,
            hasLogs: hasLogs
        ) {
            selectedTab = defaultTab
        }
    }

    private func logSelectionChange() {
        guard let node else { return }
        let buildMs = Int((CFAbsoluteTimeGetCurrent() - buildStart) * 1000)
        AppLogger.ui.debug("Inspector selection changed", metadata: [
            "node_id": String(node.id),
            "prop_count": String(node.props.count),
            "build_ms": String(buildMs),
        ])
    }
}
