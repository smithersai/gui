import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct LiveRunChatView: View {
    @ObservedObject var smithers: SmithersClient
    let runId: String
    let nodeId: String?
    var onClose: () -> Void = {}

    @State private var run: RunSummary?
    @State private var tasks: [RunTask] = []

    @State private var allBlocks: [ChatBlock] = []
    @State private var attempts: [Int: [ChatBlock]] = [:]
    @State private var inFlightBlockIndexByLifecycleId: [String: Int] = [:]
    @State private var currentAttempt = 0
    @State private var maxAttempt = 0
    @State private var newBlocksInLatest = 0

    @State private var loadingRun = true
    @State private var loadingBlocks = true
    @State private var runError: String?
    @State private var blocksError: String?

    @State private var streamTask: Task<Void, Never>?
    @State private var streamGeneration = UUID()
    @State private var streamDone = false
    @State private var bufferingInitialStream = false
    @State private var initialStreamBuffer: [ChatBlock] = []

    @State private var follow = true
    @State private var showContextPane = false
    @State private var scrollRequest = UUID()
    @State private var selectedNodeId: String?
    @State private var hideNoise = true

    @State private var pollTask: Task<Void, Never>?

    @State private var hijacking = false
    @State private var hijackError: String?
    @State private var replayFallback = false
    @State private var promptResumeAutomation = false
    @State private var hijackReturnError: String?
    @State private var hijackReturned = false

    private let bottomAnchor = "live-run-chat-bottom"

    // MARK: - Noise filtering

    private static func isNoiseBlock(_ block: ChatBlock) -> Bool {
        let role = block.role.lowercased()
        guard role == "system" || role == "stderr" || role == "status" else { return false }
        let content = block.content
        if content.contains("ERROR codex_core::") || content.contains("ERROR codex_") { return true }
        if content.contains("state db missing rollout path") { return true }
        if content.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z\s+(ERROR|WARN)\s+"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Returns meaningful (non-noise) blocks for a given nodeId, deduped.
    /// Matches both exact nodeId and nodeId with iteration suffix (e.g. "task:review" matches "task:review:0").
    private func blocksForNode(_ nid: String) -> [ChatBlock] {
        let blocks = attempts.isEmpty ? allBlocks : attempts[currentAttempt] ?? []
        let prefix = nid + ":"
        return deduplicatedChatBlocks(blocks).filter { block in
            guard let blockNodeId = block.nodeId, !Self.isNoiseBlock(block) else { return false }
            return blockNodeId == nid || blockNodeId.hasPrefix(prefix)
        }
    }

    /// Last few meaningful messages for a node (assistant/tool only)
    private func tailBlocks(for nid: String, count: Int = 3) -> [ChatBlock] {
        let all = blocksForNode(nid)
        let meaningful = all.filter {
            let role = $0.role.lowercased()
            return role == "assistant" || role == "agent" || role == "tool" || role == "tool_call" || role == "tool_result"
        }
        return Array(meaningful.suffix(count))
    }

    // MARK: - Computed

    private var shortRunId: String {
        String(runId.prefix(8))
    }

    private var runTitle: String {
        if let workflowName = run?.workflowName, !workflowName.isEmpty {
            return "\(workflowName) · \(shortRunId)"
        }
        return shortRunId
    }

    private var nodeLabel: String? {
        guard let nodeId, !nodeId.isEmpty else { return nil }
        return nodeId
    }

    private var bodyError: String? {
        if let runError { return "Error loading run: \(runError)" }
        if let blocksError { return "Error loading chat: \(blocksError)" }
        return nil
    }

    private var isStreamingIndicatorVisible: Bool {
        guard let run else { return false }
        let isTerminal = run.status == .finished || run.status == .failed || run.status == .cancelled
        return !isTerminal && !streamDone
    }

    private var stateCounts: [(String, Int)] {
        if let summary = run?.summary, !summary.isEmpty {
            return summary
                .map { ($0.key, $0.value) }
                .sorted { $0.0 < $1.0 }
        }
        let grouped = Dictionary(grouping: tasks, by: { $0.state })
        return grouped
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            runHeader
            hijackBanner

            if let expandedNode = selectedNodeId {
                expandedTaskView(nodeId: expandedNode)
            } else {
                taskDashboard
            }
        }
        .background(Theme.surface1)
        .task {
            await loadAll()
            startPollingRunState()
        }
        .onDisappear {
            stopStreaming()
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: - Run Header

    private var runHeader: some View {
        HStack(spacing: 12) {
            if let run {
                runStatusBadge(run.status)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(run?.workflowName ?? shortRunId)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 8) {
                    Text(shortRunId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                    if let run {
                        Text(run.elapsedString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                    if runningCount > 0 {
                        HStack(spacing: 3) {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 10, height: 10)
                            Text("\(runningCount) active")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.accent)
                        }
                    }
                }
            }

            Spacer()

            if loadingRun || loadingBlocks {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 16, height: 16)
            }

            pillButton("Refresh", icon: "arrow.clockwise") {
                Task { await refresh() }
            }
            .accessibilityIdentifier("liverun.refresh")

            pillButton(hijacking ? "Hijacking..." : "Hijack", icon: "arrow.trianglehead.branch") {
                startHijack()
            }
            .disabled(hijacking)
            .opacity(hijacking ? 0.6 : 1)
            .accessibilityIdentifier("liverun.hijack")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("liverun.close")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    private func runStatusBadge(_ status: RunStatus) -> some View {
        let (icon, color): (String, Color) = {
            switch status {
            case .running: return ("circle.fill", Theme.accent)
            case .finished: return ("checkmark.circle.fill", Theme.success)
            case .failed: return ("xmark.circle.fill", Theme.danger)
            case .cancelled: return ("minus.circle.fill", Theme.warning)
            case .waitingApproval: return ("pause.circle.fill", Theme.warning)
            case .unknown: return ("questionmark.circle", Theme.textTertiary)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 14))
            .foregroundColor(color)
    }

    // MARK: - Task Helpers

    private var uniqueTasks: [RunTask] {
        var seen: [String: RunTask] = [:]
        for task in tasks { seen[task.nodeId] = task }
        return tasks.filter { seen[$0.nodeId]?.id == $0.id }
            .reduce(into: [RunTask]()) { result, task in
                if !result.contains(where: { $0.nodeId == task.nodeId }) {
                    result.append(task)
                }
            }
    }

    private var runningCount: Int {
        uniqueTasks.filter { $0.state == "running" || $0.state == "in-progress" }.count
    }

    private func taskStateInfo(_ state: String) -> (icon: String, color: Color, label: String) {
        switch state {
        case "running", "in-progress":
            return ("circle.dotted.circle", Theme.accent, "Running")
        case "finished", "complete":
            return ("checkmark.circle.fill", Theme.success, "Finished")
        case "failed", "error":
            return ("xmark.circle.fill", Theme.danger, "Failed")
        case "blocked", "waiting-approval":
            return ("pause.circle.fill", Theme.warning, "Blocked")
        case "skipped":
            return ("forward.fill", Theme.textTertiary, "Skipped")
        default:
            return ("circle", Theme.textTertiary, "Pending")
        }
    }

    private func taskSortOrder(_ state: String) -> Int {
        switch state {
        case "running", "in-progress": return 0
        case "blocked", "waiting-approval": return 1
        case "failed", "error": return 2
        case "pending": return 3
        case "finished", "complete": return 4
        default: return 5
        }
    }

    private func pillButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var hijackBanner: some View {
        if hijacking {
            banner(text: "Hijacking session...", color: Theme.accent)
        } else if let hijackError {
            banner(text: "Hijack error: \(hijackError)", color: Theme.danger)
        } else if replayFallback {
            banner(text: "Resume not supported by this agent. Conversation history is still available.", color: Theme.warning)
        } else if promptResumeAutomation {
            HStack(spacing: 10) {
                Text("Hijack session launched\(hijackReturnError.map { " (\($0))" } ?? "").")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("Resume automation", action: resumeAutomation)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.success)
                Button("Dismiss", action: dismissHijackPrompt)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.surface2)
            .border(Theme.border, edges: [.bottom])
        } else if hijackReturned {
            banner(text: "Returned from hijack session.", color: Theme.textTertiary)
        }
    }

    private func banner(text: String, color: Color) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surface2)
        .border(Theme.border, edges: [.bottom])
    }

    // MARK: - Task Dashboard (default view)

    private var taskDashboard: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if loadingRun && tasks.isEmpty {
                    loadingBody
                } else if let bodyError {
                    errorBody(bodyError)
                } else if uniqueTasks.isEmpty {
                    emptyBody
                } else {
                    let sorted = uniqueTasks.sorted { lhs, rhs in
                        taskSortOrder(lhs.state) < taskSortOrder(rhs.state)
                    }
                    ForEach(sorted) { task in
                        taskCard(task)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskCard(_ task: RunTask) -> some View {
        let info = taskStateInfo(task.state)
        let isActive = task.state == "running" || task.state == "in-progress"
        let tail = isActive ? tailBlocks(for: task.nodeId, count: 3) : []
        let totalMessages = blocksForNode(task.nodeId).count

        return Button(action: {
            let matchCount = blocksForNode(task.nodeId).count
            AppLogger.ui.info("Task selected", metadata: [
                "nodeId": task.nodeId,
                "state": task.state,
                "matching_blocks": "\(matchCount)",
                "total_blocks": "\(allBlocks.count)",
            ])
            selectedNodeId = task.nodeId
        }) {
            VStack(alignment: .leading, spacing: 0) {
                // Task header row
                HStack(spacing: 8) {
                    Image(systemName: info.icon)
                        .font(.system(size: 12))
                        .foregroundColor(info.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.label ?? task.nodeId)
                            .font(.system(size: 13, weight: isActive ? .bold : .medium))
                            .foregroundColor(Theme.textPrimary)
                        HStack(spacing: 6) {
                            Text(info.label.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(info.color)
                            if totalMessages > 0 {
                                Text("\(totalMessages) messages")
                                    .font(.system(size: 9))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            if let attempt = task.lastAttempt, attempt > 1 {
                                Text("attempt \(attempt)")
                                    .font(.system(size: 9))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                    Spacer()
                    if isActive {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Live tail for running tasks
                if isActive && !tail.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tail, id: \.stableId) { block in
                            tailMessageRow(block)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
            .background(isActive ? Theme.accent.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("liverun.task.\(task.nodeId)")
        .border(Theme.border, edges: [.bottom])
    }

    private func tailMessageRow(_ block: ChatBlock) -> some View {
        let role = block.role.lowercased()
        let isAssistant = role == "assistant" || role == "agent"
        let content = decodeHTMLEntities(block.content)
        let icon = isAssistant ? "sparkles" : "wrench"
        let color = isAssistant ? Theme.accent : Theme.warning

        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(color)
                .frame(width: 12, alignment: .center)
                .padding(.top, 2)
            Text(content)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Expanded Task View (drill-in)

    private func expandedTaskView(nodeId expandedNodeId: String) -> some View {
        let blocks = blocksForNode(expandedNodeId)
        let task = uniqueTasks.first(where: { $0.nodeId == expandedNodeId })
        let info: (icon: String, color: Color, label: String) = task.map { taskStateInfo($0.state) } ?? ("circle", Theme.textTertiary, "Unknown")

        return VStack(spacing: 0) {
            // Back bar
            HStack(spacing: 8) {
                Button(action: { selectedNodeId = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text("All Tasks")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("liverun.backToTasks")

                Divider().frame(height: 14)

                Image(systemName: info.icon)
                    .font(.system(size: 10))
                    .foregroundColor(info.color)
                Text(task?.label ?? expandedNodeId)
                    .accessibilityIdentifier("liverun.expandedTask.\(expandedNodeId)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(info.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(info.color)

                Spacer()

                Text("\(blocks.count) messages")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .accessibilityIdentifier("liverun.messageCount")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.surface2.opacity(0.5))
            .border(Theme.border, edges: [.bottom])

            // Chat transcript for this node
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(blocks, id: \.stableId) { block in
                            expandedBlockRow(block)
                        }

                        if let task, (task.state == "running" || task.state == "in-progress") {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                                Text("Running...")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                        } else if blocks.isEmpty, let task {
                            VStack(spacing: 10) {
                                Image(systemName: task.state == "failed" ? "xmark.circle" : "doc.text.magnifyingglass")
                                    .font(.system(size: 24))
                                    .foregroundColor(task.state == "failed" ? Theme.danger : Theme.textTertiary)
                                Text(task.state == "failed"
                                     ? "This task failed without producing output."
                                     : "No output available for this task.")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                                if task.state == "failed" {
                                    Text("smithers logs \(runId) | grep \"\(expandedNodeId)\"")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Theme.surface2)
                                        .cornerRadius(4)
                                }
                                if let attempt = task.lastAttempt {
                                    Text("Attempt \(attempt)")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textTertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .padding(.top, 20)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                    .padding(16)
                }
                .onChange(of: blocks.count) { _, _ in
                    guard follow else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: scrollRequest) { _, _ in
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func expandedBlockRow(_ block: ChatBlock) -> some View {
        let role = block.role.lowercased()
        let content = decodeHTMLEntities(block.content)
        let timestamp = timestampLabel(for: block)

        return Group {
            if role == "assistant" || role == "agent" {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.accent)
                        Text("ASSISTANT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.accent)
                        Spacer()
                        if !timestamp.isEmpty {
                            Text(timestamp)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    Text(content)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Theme.bubbleAssistant)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25), lineWidth: 1))
            } else if role == "user" {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("PROMPT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.success)
                        Spacer()
                        if !timestamp.isEmpty {
                            Text(timestamp)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    Text(content)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
                .padding(10)
                .background(Theme.bubbleUser.opacity(0.5))
                .cornerRadius(8)
            } else if role == "tool" || role == "tool_call" || role == "tool_result" {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "wrench")
                        .font(.system(size: 8))
                        .foregroundColor(Theme.warning)
                        .padding(.top, 2)
                    Text(content)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            } else {
                HStack(spacing: 4) {
                    Text(content)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary.opacity(0.7))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Loading / Error / Empty

    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6)
            Text("Loading...")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private func errorBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
                .textSelection(.enabled)
            Button("Retry") {
                Task { await refresh() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }

    private var emptyBody: some View {
        Text("No tasks yet.")
            .font(.system(size: 12))
            .foregroundColor(Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    // MARK: - Context Pane (kept for potential use)

    private var contextPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Context")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                contextRow("Run", shortRunId)
                if let workflow = run?.workflowName {
                    contextRow("Workflow", workflow)
                }
                if let status = run?.status.rawValue {
                    contextRow("Status", status)
                }
                if let nodeLabel {
                    contextRow("Node", nodeLabel)
                }

                if let elapsed = run?.elapsedString, !elapsed.isEmpty {
                    contextRow("Elapsed", elapsed)
                }

                if !stateCounts.isEmpty {
                    Divider().background(Theme.border)
                    Text("Nodes")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                    ForEach(stateCounts, id: \.0) { state, count in
                        HStack {
                            Text(state)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textTertiary)
                            Spacer()
                            Text("\(count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }

                if let errorJson = run?.errorJson, !errorJson.isEmpty {
                    Divider().background(Theme.border)
                    Text("Error")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.danger)
                    Text(errorJson)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private func contextRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Utilities

    private func timestampLabel(for block: ChatBlock) -> String {
        guard let blockTS = block.timestampMs else { return "" }
        if let runStart = run?.startedAtMs {
            let delta = max(0, blockTS - runStart)
            return "[\(formatDuration(deltaMs: delta))]"
        }
        let date = Date(timeIntervalSince1970: Double(blockTS) / 1000.0)
        return "[\(DateFormatters.hourMinuteSecond.string(from: date))]"
    }

    private func formatDuration(deltaMs: Int64) -> String {
        let seconds = Int(deltaMs / 1000)
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m \(seconds % 60)s"
    }

    private func previousAttempt() {
        guard currentAttempt > 0 else { return }
        currentAttempt -= 1
        scrollRequest = UUID()
    }

    private func nextAttempt() {
        guard currentAttempt < maxAttempt else { return }
        currentAttempt += 1
        if currentAttempt == maxAttempt {
            newBlocksInLatest = 0
        }
        scrollRequest = UUID()
    }

    // MARK: - Data Loading

    private func refresh() async {
        stopStreaming()
        pollTask?.cancel()
        await loadAll()
        startPollingRunState()
    }

    private func loadAll() async {
        async let runResult: () = loadRun()
        async let blocksResult: () = loadBlocks()
        _ = await (runResult, blocksResult)
    }

    private func loadRun() async {
        loadingRun = true
        runError = nil
        // Retry a few times — after a detached launch the server may not have
        // registered the run yet, leading to a transient RUN_NOT_FOUND error.
        for attempt in 0..<5 {
            do {
                let inspection = try await smithers.inspectRun(runId)
                run = inspection.run
                tasks = inspection.tasks
                loadingRun = false
                return
            } catch {
                let isNotFound = error.localizedDescription.contains("RUN_NOT_FOUND")
                    || error.localizedDescription.contains("Run not found")
                if isNotFound && attempt < 4 {
                    try? await Task.sleep(nanoseconds: UInt64((attempt + 1)) * 500_000_000)
                    continue
                }
                runError = error.localizedDescription
            }
        }
        loadingRun = false
    }

    private func loadBlocks() async {
        loadingBlocks = true
        blocksError = nil
        streamDone = false
        bufferingInitialStream = true
        initialStreamBuffer = []

        startStreaming()

        do {
            var blocks = try await smithers.getChatOutput(runId)
            blocks = blocks.filter(matchesNodeFilter)
            let uniqueNodeIds = Set(blocks.compactMap(\.nodeId))
            AppLogger.ui.info("loadBlocks complete", metadata: [
                "run_id": runId,
                "total_blocks": "\(blocks.count)",
                "unique_nodeIds": "\(uniqueNodeIds.count)",
                "sample_nodeIds": "\(Array(uniqueNodeIds.prefix(5)).joined(separator: ", "))",
            ])
            let bufferedBlocks = initialStreamBuffer
            bufferingInitialStream = false
            initialStreamBuffer = []
            rebuildAttempts(with: blocks)
            for block in bufferedBlocks {
                appendStreamBlock(block)
            }
        } catch {
            AppLogger.ui.warning("loadBlocks failed", metadata: ["run_id": runId, "error": "\(error.localizedDescription)"])
            bufferingInitialStream = false
            initialStreamBuffer = []
            if allBlocks.isEmpty {
                blocksError = error.localizedDescription
            }
        }

        loadingBlocks = false
    }

    // MARK: - Streaming

    private func startStreaming() {
        streamTask?.cancel()
        streamTask = nil
        let generation = UUID()
        streamGeneration = generation
        streamDone = false
        streamTask = Task {
            for await event in smithers.streamChat(runId) {
                if Task.isCancelled { break }
                guard let block = decodeStreamEvent(event) else { continue }
                await MainActor.run {
                    guard streamGeneration == generation, !Task.isCancelled else { return }
                    appendStreamBlock(block)
                }
            }
            await MainActor.run {
                guard streamGeneration == generation, !Task.isCancelled else { return }
                streamDone = true
            }
        }
    }

    private func startPollingRunState() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                guard !Task.isCancelled else { break }
                if let inspection = try? await smithers.inspectRun(runId) {
                    run = inspection.run
                    tasks = inspection.tasks
                }
                // Re-fetch blocks when SSE isn't delivering them
                if streamDone || allBlocks.isEmpty {
                    if var blocks = try? await smithers.getChatOutput(runId) {
                        blocks = blocks.filter(matchesNodeFilter)
                        rebuildAttempts(with: blocks)
                    }
                }
                let isTerminal = run?.status == .finished
                    || run?.status == .failed
                    || run?.status == .cancelled
                if isTerminal { break }
            }
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        streamGeneration = UUID()
        bufferingInitialStream = false
        initialStreamBuffer = []
    }

    private func decodeStreamEvent(_ event: SSEEvent) -> ChatBlock? {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }

        if let block = try? JSONDecoder().decode(ChatBlock.self, from: data) {
            return block
        }
        if let wrapped = try? JSONDecoder().decode(StreamBlockEnvelope.self, from: data) {
            return wrapped.block ?? wrapped.data
        }
        return nil
    }

    private func appendStreamBlock(_ block: ChatBlock) {
        guard matchesNodeFilter(block) else { return }
        if bufferingInitialStream {
            initialStreamBuffer.append(block)
        }

        if let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty {
            if replaceExistingStreamBlock(block, lifecycleId: lifecycleId) {
                if follow {
                    scrollRequest = UUID()
                }
                return
            }
        }

        if replaceLastAssistantOverlapStreamBlock(block) {
            if follow {
                scrollRequest = UUID()
            }
            return
        }

        allBlocks.append(block)
        if let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty {
            inFlightBlockIndexByLifecycleId[lifecycleId] = allBlocks.count - 1
        }
        indexBlock(block)

        if block.attemptIndex > currentAttempt {
            newBlocksInLatest += 1
            return
        }

        if follow {
            scrollRequest = UUID()
        }
    }

    private func rebuildAttempts(with blocks: [ChatBlock]) {
        allBlocks = blocks
        attempts = [:]
        inFlightBlockIndexByLifecycleId = [:]
        maxAttempt = 0
        currentAttempt = 0

        for (index, block) in blocks.enumerated() {
            if let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty {
                inFlightBlockIndexByLifecycleId[lifecycleId] = index
            }
            indexBlock(block)
        }

        currentAttempt = maxAttempt
        newBlocksInLatest = 0
        if follow {
            scrollRequest = UUID()
        }
    }

    private func indexBlock(_ block: ChatBlock) {
        let attempt = block.attemptIndex
        attempts[attempt, default: []].append(block)
        if attempt > maxAttempt {
            maxAttempt = attempt
        }
    }

    private func replaceExistingStreamBlock(_ block: ChatBlock, lifecycleId: String) -> Bool {
        let mappedIndex = inFlightBlockIndexByLifecycleId[lifecycleId]
            .flatMap { allBlocks.indices.contains($0) ? $0 : nil }
        let searchIndex = mappedIndex ?? allBlocks.lastIndex(where: { $0.lifecycleId == lifecycleId })
        guard let index = searchIndex else {
            return false
        }

        let existing = allBlocks[index]
        allBlocks[index] = existing.canMergeAssistantStream(with: block)
            ? existing.mergingAssistantStream(with: block)
            : block
        inFlightBlockIndexByLifecycleId[lifecycleId] = index
        rebuildAttemptIndexPreservingSelection()
        return true
    }

    private func replaceLastAssistantOverlapStreamBlock(_ block: ChatBlock) -> Bool {
        guard let index = allBlocks.indices.last else { return false }
        let existing = allBlocks[index]
        guard existing.canMergeAssistantStream(with: block),
              existing.hasStreamingContentOverlap(with: block) else {
            return false
        }

        allBlocks[index] = existing.mergingAssistantStream(with: block)
        if let existingLifecycleId = existing.lifecycleId, !existingLifecycleId.isEmpty {
            inFlightBlockIndexByLifecycleId[existingLifecycleId] = index
        }
        if let incomingLifecycleId = block.lifecycleId, !incomingLifecycleId.isEmpty {
            inFlightBlockIndexByLifecycleId[incomingLifecycleId] = index
        }
        if let mergedLifecycleId = allBlocks[index].lifecycleId, !mergedLifecycleId.isEmpty {
            inFlightBlockIndexByLifecycleId[mergedLifecycleId] = index
        }
        rebuildAttemptIndexPreservingSelection()
        return true
    }

    private func rebuildAttemptIndexPreservingSelection() {
        let selectedAttempt = currentAttempt
        attempts = [:]
        maxAttempt = 0

        for block in allBlocks {
            indexBlock(block)
        }

        currentAttempt = min(selectedAttempt, maxAttempt)
    }

    private func matchesNodeFilter(_ block: ChatBlock) -> Bool {
        guard let nodeId, !nodeId.isEmpty else { return true }
        return block.nodeId == nodeId
    }

    // MARK: - Hijack

    private func startHijack() {
        guard !hijacking else { return }

        hijacking = true
        hijackError = nil
        replayFallback = false

        Task { @MainActor in
            do {
                let session = try await smithers.hijackRun(runId)
                hijacking = false

                if !session.supportsResume {
                    replayFallback = true
                    appendStatusBlock("Agent does not support native resume. Conversation history remains available here.")
                    return
                }

                do {
                    try await launchHijackSession(session)
                    hijackReturned = true
                    promptResumeAutomation = true
                    appendStatusBlock("--------- HIJACK SESSION LAUNCHED ---------")
                    await loadRun()
                } catch {
                    hijackError = error.localizedDescription
                }
            } catch {
                hijacking = false
                hijackError = error.localizedDescription
            }
        }
    }

    private func resumeAutomation() {
        promptResumeAutomation = false
        hijackReturned = false
        appendStatusBlock("Resuming automation...")
        Task { await refresh() }
    }

    private func dismissHijackPrompt() {
        promptResumeAutomation = false
        hijackReturned = false
    }

    private func appendStatusBlock(_ message: String) {
        let block = ChatBlock(
            id: UUID().uuidString,
            runId: runId,
            nodeId: nodeId,
            attempt: maxAttempt,
            role: "system",
            content: message,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        allBlocks.append(block)
        indexBlock(block)
        if follow {
            scrollRequest = UUID()
        }
    }

    private func launchHijackSession(_ session: HijackSession) async throws {
        guard let invocation = session.launchInvocation() else {
            throw SmithersError.api("Hijack session is missing resume details")
        }

        #if os(macOS)
        let quotedArgs = invocation.arguments.map(shellQuote).joined(separator: " ")
        let command = "cd \(shellQuote(invocation.workingDirectory)); \(shellQuote(invocation.executable)) \(quotedArgs)"
        let script = """
        tell application "Terminal"
            activate
            do script \(appleScriptString(command))
        end tell
        """

        try await Self.runHijackLaunchScript(script)
        #else
        throw SmithersError.notAvailable("Hijack handoff is only available on macOS")
        #endif
    }

    #if os(macOS)
    private nonisolated static func runHijackLaunchScript(_ script: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stdoutCollector = HijackProcessOutputBuffer()
            let stderrCollector = HijackProcessOutputBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                stdoutCollector.append(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                stderrCollector.append(handle.availableData)
            }
            defer {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
            }

            try process.run()
            process.waitUntilExit()

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdoutCollector.append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderrCollector.append(stderr.fileHandleForReading.readDataToEndOfFile())

            guard process.terminationStatus == 0 else {
                let errText = String(decoding: stderrCollector.snapshot(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let outText = String(decoding: stdoutCollector.snapshot(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = errText.isEmpty ? outText : errText
                throw SmithersError.cli(message.isEmpty ? "Failed to launch hijack terminal session" : message)
            }
        }.value
    }
    #endif

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

#if os(macOS)
private final class HijackProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}
#endif

private struct StreamBlockEnvelope: Decodable {
    let block: ChatBlock?
    let data: ChatBlock?
}

// MARK: - HTML Entity Decoding

private func decodeHTMLEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let entities: [(String, String)] = [
        ("&quot;", "\""),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&#x27;", "'"),
        ("&#34;", "\""),
        ("&#x22;", "\""),
        ("&nbsp;", " "),
    ]
    var result = text
    for (entity, replacement) in entities {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result
}
