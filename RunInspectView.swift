import SwiftUI

struct RunInspectView: View {
    @ObservedObject var smithers: SmithersClient
    let runId: String
    var onOpenLiveChat: ((String, String?) -> Void)? = nil
    var onOpenTerminalCommand: ((String, String, String) -> Void)? = nil
    var onClose: () -> Void = {}

    @State private var inspection: RunInspection?
    @State private var mode: InspectMode = .list
    @State private var selectedTaskIndex = 0

    @State private var isLoading = true
    @State private var error: String?
    @State private var actionMessage: String?
    @State private var actionMessageColor: Color = Theme.textTertiary

    @State private var hijacking = false
    @State private var rerunning = false
    @State private var approvalActionInFlight = false
    @State private var pendingDenyTask: RunTask?

    @State private var nodeInspectSelection: RunTask?
    @State private var showingSnapshots = false
    @State private var snapshotsNodeFilter: String?

    enum InspectMode: String, CaseIterable, Identifiable {
        case list = "List"
        case dag = "DAG"

        var id: String { rawValue }
    }

    private var tasks: [RunTask] {
        inspection?.tasks ?? []
    }

    private var selectedTask: RunTask? {
        guard tasks.indices.contains(selectedTaskIndex) else { return nil }
        return tasks[selectedTaskIndex]
    }

    private var blockedApprovalTask: RunTask? {
        tasks.first(where: isApprovalBlockedTask)
    }

    private var shortRunID: String {
        String(runId.prefix(8))
    }

    private var runDisplayName: String {
        inspection?.run.workflowName ?? shortRunID
    }

    private var runStatusText: String {
        inspection?.run.status.label ?? "UNKNOWN"
    }

    private var runStatusColor: Color {
        guard let status = inspection?.run.status else { return Theme.textTertiary }
        switch status {
        case .running: return Theme.accent
        case .waitingApproval: return Theme.warning
        case .finished: return Theme.success
        case .failed: return Theme.danger
        case .cancelled, .unknown: return Theme.textTertiary
        }
    }

    private var nodeProgressText: String {
        guard let inspection else { return "0/0" }

        let summary = inspection.run.summary ?? [:]
        let total = summary["total"] ?? tasks.count
        if total <= 0 { return "0/0" }

        let finished = summary["finished"] ?? 0
        let failed = summary["failed"] ?? 0
        let cancelled = summary["cancelled"] ?? 0
        let completed = max(0, finished + failed + cancelled)
        return "\(completed)/\(total)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            metadataBar
            actionBar

            if let actionMessage {
                actionBanner(text: actionMessage, color: actionMessageColor)
            }

            content
        }
        .background(Theme.surface1)
        .task(id: runId) {
            await loadInspection()
        }
        .confirmationDialog(
            "Deny Approval",
            isPresented: Binding(
                get: { pendingDenyTask != nil },
                set: { if !$0 { pendingDenyTask = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Deny Approval", role: .destructive) {
                if let pendingDenyTask {
                    self.pendingDenyTask = nil
                    Task { await denyNode(pendingDenyTask) }
                }
            }
            .accessibilityIdentifier("runinspect.confirmDenyButton")

            Button("Cancel", role: .cancel) {
                pendingDenyTask = nil
            }
            .accessibilityIdentifier("runinspect.cancelDenyButton")
        } message: {
            if let pendingDenyTask {
                Text("Deny approval for \(pendingDenyTask.nodeId)\(iterationSuffix(for: pendingDenyTask)) on run \(shortRunID)? This will fail the waiting gate.")
            } else {
                Text("Deny this approval? This will fail the waiting gate.")
            }
        }
        .sheet(item: $nodeInspectSelection) { task in
            NodeInspectView(
                runId: runId,
                task: task,
                onOpenLiveChat: { rid, nid in openLiveChat(runId: rid, nodeId: nid) },
                onOpenSnapshots: { nodeId in
                    snapshotsNodeFilter = nodeId
                    showingSnapshots = true
                },
                onClose: { nodeInspectSelection = nil }
            )
            .frame(minWidth: 560, minHeight: 420)
        }
        .sheet(isPresented: $showingSnapshots) {
            RunSnapshotsSheet(
                smithers: smithers,
                runId: runId,
                nodeIdFilter: snapshotsNodeFilter,
                onClose: { showingSnapshots = false }
            )
            .frame(minWidth: 840, minHeight: 520)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("view.runinspect")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Inspector")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("\(runDisplayName) · \(shortRunID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 16, height: 16)
            }

            iconButton("arrow.clockwise", color: Theme.textSecondary) {
                Task { await loadInspection() }
            }
            .accessibilityIdentifier("runinspect.action.refresh")

            iconButton("xmark", color: Theme.textSecondary, action: onClose)
                .accessibilityIdentifier("runinspect.close")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .border(Theme.border, edges: [.bottom])
    }

    private var metadataBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                statusChip
                metadataPill("Run", shortRunID)
                metadataPill("Nodes", nodeProgressText)

                if let iteration = selectedTask?.iteration {
                    metadataPill("Iteration", "\(iteration)")
                }
                if let attempt = selectedTask?.lastAttempt {
                    metadataPill("Attempt", "#\(attempt)")
                }

                if let started = inspection?.run.startedAtMs {
                    metadataPill("Started", runInspectorShortDate(started))
                }
                if let finished = inspection?.run.finishedAtMs {
                    metadataPill("Finished", runInspectorShortDate(finished))
                }
                if let run = inspection?.run, !run.elapsedString.isEmpty {
                    elapsedMetadataPill(run)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .border(Theme.border, edges: [.bottom])
    }

    private var statusChip: some View {
        Text(runStatusText)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(runStatusColor)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(runStatusColor.opacity(0.14))
            .cornerRadius(6)
    }

    private func metadataPill(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.inputBg)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private func elapsedMetadataPill(_ run: RunSummary) -> some View {
        if run.status == .running || run.status == .waitingApproval {
            TimelineView(.periodic(from: Date(), by: 1)) { _ in
                metadataPill("Elapsed", run.elapsedString)
            }
        } else {
            metadataPill("Elapsed", run.elapsedString)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            actionPill("Live Chat", icon: "message", color: Theme.accent) {
                openLiveChat(runId: runId, nodeId: nil)
            }
            .accessibilityIdentifier("runinspect.action.liveChat")

            actionPill("Snapshots", icon: "clock.arrow.circlepath", color: Theme.info) {
                snapshotsNodeFilter = nil
                showingSnapshots = true
            }
            .accessibilityIdentifier("runinspect.action.snapshots")

            actionPill(hijacking ? "Hijacking..." : "Hijack", icon: "arrow.trianglehead.branch", color: Theme.warning) {
                startHijack()
            }
            .disabled(hijacking || onOpenTerminalCommand == nil)
            .opacity((hijacking || onOpenTerminalCommand == nil) ? 0.55 : 1)
            .accessibilityIdentifier("runinspect.action.hijack")

            actionPill("Watch", icon: "eye", color: Theme.textSecondary) {
                openWatchHook()
            }
            .disabled(onOpenTerminalCommand == nil)
            .opacity(onOpenTerminalCommand == nil ? 0.55 : 1)
            .accessibilityIdentifier("runinspect.action.watch")

            actionPill(rerunning ? "Rerunning..." : "Rerun", icon: "arrow.clockwise.circle", color: Theme.success) {
                startRerun()
            }
            .disabled(rerunning)
            .opacity(rerunning ? 0.55 : 1)
            .accessibilityIdentifier("runinspect.action.rerun")

            if inspection?.run.status == .waitingApproval {
                if let blockedApprovalTask {
                    actionPill(approvalActionInFlight ? "Approving..." : "Approve", icon: "checkmark", color: Theme.success) {
                        Task { await approveNode(blockedApprovalTask) }
                    }
                    .disabled(approvalActionInFlight)
                    .opacity(approvalActionInFlight ? 0.55 : 1)
                    .accessibilityIdentifier("runinspect.action.approve")

                    actionPill("Deny", icon: "xmark", color: Theme.danger) {
                        pendingDenyTask = blockedApprovalTask
                    }
                    .disabled(approvalActionInFlight)
                    .opacity(approvalActionInFlight ? 0.55 : 1)
                    .accessibilityIdentifier("runinspect.action.deny")
                } else {
                    actionPill("Approve", icon: "checkmark", color: Theme.success) {}
                        .disabled(true)
                        .opacity(0.5)
                        .accessibilityIdentifier("runinspect.action.approve")
                    actionPill("Deny", icon: "xmark", color: Theme.danger) {}
                        .disabled(true)
                        .opacity(0.5)
                        .accessibilityIdentifier("runinspect.action.deny")
                }
            }

            Spacer()

            Picker("Mode", selection: $mode) {
                ForEach(InspectMode.allCases) { value in
                    Text(value.rawValue)
                        .tag(value)
                        .accessibilityIdentifier("runinspect.mode.\(value.rawValue.lowercased())")
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .accessibilityIdentifier("runinspect.modePicker")

            Button("List") { mode = .list }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: mode == .list ? .bold : .regular))
                .foregroundColor(mode == .list ? Theme.accent : Theme.textTertiary)
                .accessibilityIdentifier("runinspect.mode.listButton")

            Button("DAG") { mode = .dag }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: mode == .dag ? .bold : .regular))
                .foregroundColor(mode == .dag ? Theme.accent : Theme.textTertiary)
                .accessibilityIdentifier("runinspect.mode.dagButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .border(Theme.border, edges: [.bottom])
    }

    private func actionBanner(text: String, color: Color) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Theme.surface2)
        .border(Theme.border, edges: [.bottom])
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading run...")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.warning)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await loadInspection() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.textTertiary)
                Text("No nodes found")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if mode == .list {
                listModeView
            } else {
                dagModeView
            }
        }
    }

    private var listModeView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    nodeRow(index: index, task: task, treePrefix: nil)
                }
            }
            .padding(16)
        }
        .refreshable { await loadInspection() }
    }

    private var dagModeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.info)
                    Text(runDisplayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface2)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("runinspect.dag.root")

                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    nodeRow(
                        index: index,
                        task: task,
                        treePrefix: index == tasks.count - 1 ? "└─" : "├─"
                    )
                }

                if let selectedTask {
                    dagDetailPanel(selectedTask)
                        .padding(.top, 8)
                        .accessibilityIdentifier("runinspect.dag.detail")
                }
            }
            .padding(16)
        }
        .refreshable { await loadInspection() }
    }

    private func nodeRow(index: Int, task: RunTask, treePrefix: String?) -> some View {
        let isSelected = index == selectedTaskIndex

        return HStack(spacing: 8) {
            if let treePrefix {
                Text(treePrefix)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 22, alignment: .leading)
            }

            Image(systemName: runInspectorTaskStateIcon(task.state))
                .font(.system(size: 11))
                .foregroundColor(runInspectorTaskStateColor(task.state))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.label ?? task.nodeId)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Text(taskMetaLine(task))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(runInspectorTaskStateLabel(task.state))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(runInspectorTaskStateColor(task.state))

            iconButton("message", color: Theme.accent) {
                openLiveChat(runId: runId, nodeId: task.nodeId)
            }
            .accessibilityIdentifier("runinspect.nodeChat.\(runInspectorSafeID(task.id))")

            nodeActionButton("Inspect", icon: "sidebar.right", color: Theme.textSecondary) {
                nodeInspectSelection = task
            }
            .accessibilityIdentifier("runinspect.nodeInspect.\(runInspectorSafeID(task.id))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 8, defaultFill: Theme.surface2)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedTaskIndex == index {
                nodeInspectSelection = task
            } else {
                selectedTaskIndex = index
            }
        }
    }

    private func dagDetailPanel(_ task: RunTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected Node")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.textSecondary)

            metadataLine("Label", task.label ?? task.nodeId)
            metadataLine("ID", task.nodeId)
            metadataLine("State", runInspectorTaskStateLabel(task.state), color: runInspectorTaskStateColor(task.state))

            if let iteration = task.iteration {
                metadataLine("Iteration", "\(iteration)")
            }
            if let attempt = task.lastAttempt {
                metadataLine("Attempt", "#\(attempt)")
            }
            if let updatedAt = task.updatedAtMs {
                metadataLine("Updated", runInspectorRelativeDate(updatedAt))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func metadataLine(_ label: String, _ value: String, color: Color = Theme.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(color)
            Spacer()
        }
    }

    private func taskMetaLine(_ task: RunTask) -> String {
        var parts: [String] = [task.nodeId]

        if let iteration = task.iteration {
            parts.append("iter \(iteration)")
        }
        if let attempt = task.lastAttempt {
            parts.append("attempt #\(attempt)")
        }
        if let updatedAt = task.updatedAtMs {
            parts.append(runInspectorRelativeDate(updatedAt))
        }

        return parts.joined(separator: " · ")
    }

    private func isApprovalBlockedTask(_ task: RunTask) -> Bool {
        task.state == "blocked" || task.state == "waiting-approval"
    }

    private func iterationSuffix(for task: RunTask) -> String {
        guard let iteration = task.iteration else { return "" }
        return " iter \(iteration)"
    }

    private func iconButton(_ icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func nodeActionButton(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func actionPill(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(color.opacity(0.14))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func loadInspection() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
        }

        do {
            inspection = try await smithers.inspectRun(runId)
            clampSelection()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clampSelection() {
        guard !tasks.isEmpty else {
            selectedTaskIndex = 0
            return
        }
        if selectedTaskIndex < 0 {
            selectedTaskIndex = 0
        }
        if selectedTaskIndex >= tasks.count {
            selectedTaskIndex = tasks.count - 1
        }
    }

    private func openLiveChat(runId: String, nodeId: String?) {
        guard let onOpenLiveChat else {
            setActionMessage("Live chat hook is unavailable.", color: Theme.warning, level: .warning)
            return
        }

        onClose()
        DispatchQueue.main.async {
            onOpenLiveChat(runId, nodeId)
        }
    }

    private func startHijack() {
        guard !hijacking else { return }
        guard let onOpenTerminalCommand else {
            setActionMessage("Terminal command hook is unavailable.", color: Theme.warning, level: .warning)
            return
        }

        hijacking = true
        setActionMessage("Starting hijack session...", color: Theme.accent, level: .info)

        Task { @MainActor in
            defer { hijacking = false }

            do {
                let session = try await smithers.hijackRun(runId)
                guard session.supportsResume else {
                    setActionMessage("This agent does not support resumable hijack sessions.", color: Theme.warning, level: .warning)
                    return
                }

                guard let invocation = session.launchInvocation() else {
                    setActionMessage("Hijack session is missing resume details.", color: Theme.danger, level: .error)
                    return
                }

                let command = ([invocation.executable] + invocation.arguments)
                    .map(runInspectorShellQuote)
                    .joined(separator: " ")

                onClose()
                DispatchQueue.main.async {
                    onOpenTerminalCommand(command, invocation.workingDirectory, "Hijack \(shortRunID)")
                }
            } catch {
                setActionMessage("Hijack error: \(error.localizedDescription)", color: Theme.danger, level: .error)
            }
        }
    }

    private func openWatchHook() {
        guard let onOpenTerminalCommand else {
            setActionMessage("Terminal command hook is unavailable.", color: Theme.warning, level: .warning)
            return
        }

        let command = "jjhub run watch \(runInspectorShellQuote(runId))"
        onClose()
        DispatchQueue.main.async {
            onOpenTerminalCommand(command, FileManager.default.currentDirectoryPath, "Watch \(shortRunID)")
        }
    }

    private func startRerun() {
        guard !rerunning else { return }

        rerunning = true
        setActionMessage("Triggering JJHub rerun...", color: Theme.accent, level: .info)

        Task { @MainActor in
            defer { rerunning = false }

            do {
                let message = try await smithers.rerunRun(runId)
                setActionMessage(message, color: Theme.success, level: .success)
            } catch {
                setActionMessage(error.localizedDescription, color: Theme.danger, level: .error)
            }
        }
    }

    private func approveNode(_ task: RunTask) async {
        guard !approvalActionInFlight else { return }

        approvalActionInFlight = true
        defer { approvalActionInFlight = false }

        do {
            try await smithers.approveNode(runId: runId, nodeId: task.nodeId, iteration: task.iteration)
            setActionMessage("Approved \(task.nodeId) on run \(shortRunID)", color: Theme.success, level: .approval)
            await loadInspection()
        } catch {
            setActionMessage("Approve error: \(error.localizedDescription)", color: Theme.danger, level: .error)
        }
    }

    private func denyNode(_ task: RunTask) async {
        guard !approvalActionInFlight else { return }

        approvalActionInFlight = true
        defer { approvalActionInFlight = false }

        do {
            try await smithers.denyNode(runId: runId, nodeId: task.nodeId, iteration: task.iteration)
            setActionMessage("Denied \(task.nodeId) on run \(shortRunID)", color: Theme.success, level: .approval)
            await loadInspection()
        } catch {
            setActionMessage("Deny error: \(error.localizedDescription)", color: Theme.danger, level: .error)
        }
    }

    private func setActionMessage(_ message: String, color: Color, level: GUINotificationLevel) {
        actionMessage = message
        actionMessageColor = color
        AppNotifications.shared.post(title: "Run Inspector", message: message, level: level)
    }
}

struct RunSnapshotsSheet: View {
    @ObservedObject var smithers: SmithersClient
    let runId: String
    let nodeIdFilter: String?
    var onClose: () -> Void = {}

    @State private var snapshots: [Snapshot] = []
    @State private var selectedSnapshotID: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var actionMessage: String?
    @State private var actionMessageColor: Color = Theme.textTertiary

    private var visibleSnapshots: [Snapshot] {
        snapshots
            .filter { snapshot in
                guard let nodeIdFilter, !nodeIdFilter.isEmpty else { return true }
                return snapshot.nodeId == nodeIdFilter
            }
            .sorted { $0.createdAtMs > $1.createdAtMs }
    }

    private var selectedSnapshot: Snapshot? {
        if let id = selectedSnapshotID,
           let selected = visibleSnapshots.first(where: { $0.id == id }) {
            return selected
        }
        return visibleSnapshots.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let actionMessage {
                HStack {
                    Text(actionMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(actionMessageColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Theme.surface2)
                .border(Theme.border, edges: [.bottom])
            }

            content
        }
        .background(Theme.surface1)
        .task {
            await loadSnapshots()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("view.runsnapshots")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snapshots")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                if let nodeIdFilter, !nodeIdFilter.isEmpty {
                    Text("Run \(String(runId.prefix(8))) · Node \(nodeIdFilter)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                } else {
                    Text("Run \(String(runId.prefix(8)))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 16, height: 16)
            }

            button("Refresh", icon: "arrow.clockwise") {
                Task { await loadSnapshots() }
            }
            .accessibilityIdentifier("runsnapshots.action.refresh")

            button("Fork", icon: "arrow.triangle.branch") {
                forkSelectedSnapshot()
            }
            .disabled(selectedSnapshot == nil)
            .opacity(selectedSnapshot == nil ? 0.5 : 1)
            .accessibilityIdentifier("runsnapshots.action.fork")

            button("Replay", icon: "play.circle") {
                replaySelectedSnapshot()
            }
            .disabled(selectedSnapshot == nil)
            .opacity(selectedSnapshot == nil ? 0.5 : 1)
            .accessibilityIdentifier("runsnapshots.action.replay")

            button("Close", icon: "xmark", action: onClose)
                .accessibilityIdentifier("runsnapshots.close")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .border(Theme.border, edges: [.bottom])
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading snapshots...")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.warning)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Button("Retry") {
                    Task { await loadSnapshots() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleSnapshots.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.textTertiary)
                Text("No snapshots found")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                snapshotList
                    .frame(width: 320)
                    .background(Theme.surface2)
                Divider().background(Theme.border)
                snapshotDetail
            }
        }
    }

    private var snapshotList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(visibleSnapshots) { snapshot in
                    let isSelected = snapshot.id == selectedSnapshot?.id

                    Button {
                        selectedSnapshotID = snapshot.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.label ?? snapshot.id)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)

                            Text(snapshot.nodeId ?? "run")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                            HStack {
                                Text((snapshot.kind ?? "manual").uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.info)
                                Spacer()
                                Text(runInspectorShortDate(snapshot.createdAtMs))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 8, defaultFill: Theme.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("runsnapshots.row.\(runInspectorSafeID(snapshot.id))")
                }
            }
            .padding(12)
        }
        .refreshable { await loadSnapshots() }
    }

    private var snapshotDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = selectedSnapshot {
                    Text(snapshot.label ?? snapshot.id)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.textPrimary)

                    detailRow("Snapshot ID", snapshot.id)
                    detailRow("Run", snapshot.runId)
                    detailRow("Node", snapshot.nodeId ?? "-")
                    detailRow("Kind", snapshot.kind ?? "manual")
                    detailRow("Created", runInspectorShortDate(snapshot.createdAtMs))
                    detailRow("Relative", runInspectorRelativeDate(snapshot.createdAtMs))
                    detailRow("Parent", snapshot.parentId ?? "-")

                    Divider().background(Theme.border)

                    Text("Actions")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textSecondary)

                    Text("Use Fork to branch a new run from this snapshot, or Replay to rerun it with original context.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                } else {
                    Text("Select a snapshot")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
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

    private func iconButton(_ icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func loadSnapshots() async {
        isLoading = true
        error = nil

        do {
            snapshots = try await smithers.listSnapshots(runId: runId)
            let availableIDs = Set(visibleSnapshots.map(\.id))
            if let selectedSnapshotID, availableIDs.contains(selectedSnapshotID) {
                self.selectedSnapshotID = selectedSnapshotID
            } else {
                self.selectedSnapshotID = visibleSnapshots.first?.id
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func forkSelectedSnapshot() {
        guard let snapshot = selectedSnapshot else { return }

        Task { @MainActor in
            do {
                let run = try await smithers.forkRun(snapshotId: snapshot.id)
                setActionMessage("Forked run \(String(run.runId.prefix(8))) from snapshot.", color: Theme.success, level: .runUpdate)
            } catch {
                setActionMessage("Fork failed: \(error.localizedDescription)", color: Theme.danger, level: .error)
            }
        }
    }

    private func replaySelectedSnapshot() {
        guard let snapshot = selectedSnapshot else { return }

        Task { @MainActor in
            do {
                let run = try await smithers.replayRun(snapshotId: snapshot.id)
                setActionMessage("Replayed run as \(String(run.runId.prefix(8))).", color: Theme.success, level: .runUpdate)
            } catch {
                setActionMessage("Replay failed: \(error.localizedDescription)", color: Theme.danger, level: .error)
            }
        }
    }

    private func setActionMessage(_ message: String, color: Color, level: GUINotificationLevel) {
        actionMessage = message
        actionMessageColor = color
        AppNotifications.shared.post(title: "Run Snapshots", message: message, level: level)
    }
}

func runInspectorTaskStateIcon(_ state: String) -> String {
    switch state {
    case "running":
        return "circle.fill"
    case "finished":
        return "checkmark.circle.fill"
    case "failed":
        return "xmark.circle.fill"
    case "cancelled":
        return "minus.circle.fill"
    case "skipped":
        return "arrowshape.turn.up.right.circle.fill"
    case "blocked", "waiting-approval":
        return "pause.circle.fill"
    default:
        return "circle"
    }
}

func runInspectorTaskStateColor(_ state: String) -> Color {
    switch state {
    case "running":
        return Theme.accent
    case "finished":
        return Theme.success
    case "failed":
        return Theme.danger
    case "blocked", "waiting-approval":
        return Theme.warning
    case "cancelled", "skipped":
        return Theme.textTertiary
    default:
        return Theme.textTertiary
    }
}

func runInspectorTaskStateLabel(_ state: String) -> String {
    state.replacingOccurrences(of: "-", with: " ").uppercased()
}

func runInspectorSafeID(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return value.unicodeScalars
        .map { allowed.contains($0) ? Character($0) : "-" }
        .reduce(into: "") { $0.append($1) }
}

func runInspectorShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func runInspectorShortDate(_ ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
    return DateFormatters.yearMonthDayHourMinuteSecond.string(from: date)
}

func runInspectorRelativeDate(_ ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
    return DateFormatters.relativeShort.localizedString(for: date, relativeTo: Date())
}
