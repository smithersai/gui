import SwiftUI
import os

struct NodeInspectorView: View {
    @ObservedObject var store: DevToolsStore
    @Binding var selectedTab: InspectorTab
    private let outputProvider: NodeOutputProvider
    private let logsStreamProvider: ChatStreamProviding
    private let logsHistoryProvider: ChatHistoryProviding
    var onOpenPrompt: (() -> Void)? = nil

    @State private var buildStart: CFAbsoluteTime = 0

    private struct InspectorToolCall: Identifiable, Equatable {
        let id: String
        let name: String
        let sideEffect: String?
        let status: String?
    }

    @MainActor
    init(
        store: DevToolsStore,
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

    private var toolCalls: [InspectorToolCall] {
        guard let node else { return [] }
        let keys = ["toolCalls", "tool_calls", "tools"]
        for key in keys {
            guard let value = node.props[key] else { continue }
            if let parsed = parseToolCalls(from: value), !parsed.isEmpty {
                return parsed
            }
        }
        return []
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
                    if !toolCalls.isEmpty {
                        toolCallsSection(toolCalls)
                    }
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

    private func toolCallsSection(_ calls: [InspectorToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("tool calls")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)
                .textCase(.uppercase)

            ForEach(calls) { call in
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)

                    Text(call.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let status = call.status, !status.isEmpty {
                        Text(status)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                    }

                    Spacer()

                    if let sideEffect = call.sideEffect, !sideEffect.isEmpty {
                        sideEffectBadge(sideEffect)
                    }
                }
                .accessibilityIdentifier("inspector.toolCall.\(call.id)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .accessibilityIdentifier("inspector.toolCalls")
    }

    private func sideEffectBadge(_ sideEffect: String) -> some View {
        let style = sideEffectStyle(sideEffect)
        return Text(style.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(style.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(style.color.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel("Side effect: \(style.label)")
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

    private func parseToolCalls(from value: JSONValue) -> [InspectorToolCall]? {
        guard case .array(let values) = value else { return nil }
        return values.enumerated().compactMap { index, item in
            guard case .object(let object) = item else { return nil }
            let id = stringValue(object["id"])
                ?? stringValue(object["callId"])
                ?? stringValue(object["toolCallId"])
                ?? "tool-call-\(index)"
            let name = stringValue(object["name"])
                ?? stringValue(object["tool"])
                ?? stringValue(object["toolName"])
                ?? stringValue(object["function"])
                ?? "tool-call-\(index + 1)"
            let sideEffect = stringValue(object["sideEffect"])
                ?? stringValue(object["side_effect"])
                ?? stringValue(object["effect"])
                ?? stringValue(object["effects"])
            let status = stringValue(object["status"]) ?? stringValue(object["state"])
            return InspectorToolCall(id: id, name: name, sideEffect: sideEffect, status: status)
        }
    }

    private func sideEffectStyle(_ rawValue: String) -> (label: String, color: Color) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return ("UNKNOWN", Theme.textTertiary)
        }
        if normalized.contains("read") || normalized == "none" {
            return (normalized.uppercased(), Theme.textTertiary)
        }
        if normalized.contains("write") ||
            normalized.contains("mutat") ||
            normalized.contains("network") ||
            normalized.contains("shell") ||
            normalized.contains("external") ||
            normalized.contains("file") ||
            normalized.contains("delete") ||
            normalized.contains("create") ||
            normalized.contains("modify") {
            return (normalized.uppercased(), Theme.warning)
        }
        return (normalized.uppercased(), Theme.accent)
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }
}
