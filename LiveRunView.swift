import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct LiveRunView: View {
    @ObservedObject var smithers: SmithersClient
    let runId: String
    let nodeId: String?
    var onOpenTerminalCommand: ((String, String, String) -> Void)? = nil
    var onOpenWorkflow: ((String) -> Void)? = nil
    var onOpenPrompt: (() -> Void)? = nil
    var onClose: () -> Void = {}

    @StateObject private var store: LiveRunDevToolsStore

    @State private var selectedTab: InspectorTab = .logs
    @State private var runSummary: RunSummary?
    @State private var blockedApprovalTask: RunTask?
    @State private var runLoadError: String?
    @State private var runNotFound = false

    @State private var pollTask: Task<Void, Never>?
    @State private var appearsAt = Date()

    @State private var actionMessage: String?
    @State private var actionMessageColor: Color = Theme.textTertiary

    @State private var hijacking = false
    @State private var cancelInFlight = false
    @State private var approvalActionInFlight = false

    @State private var showCancelConfirmation = false
    @State private var pendingDenyTask: RunTask?

    @State private var showRewindConfirmation = false
    @State private var pendingRewindFrameNo: Int?

    @State private var inspectorSheetPresented = false
    @State private var layoutMode: LiveRunLayoutMode = .wide

    @State private var pendingDeepLinkSelection = true
    @State private var orchestratorVersion: String?

    private var useLiveRunTreeHarness: Bool {
        UITestSupport.isEnabled && ProcessInfo.processInfo.environment["SMITHERS_GUI_UITEST_TREE"] == "1"
    }

    private var workflowName: String {
        let trimmed = runSummary?.workflowName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return "Live Run"
    }

    private var shortRunID: String {
        String(runId.prefix(8))
    }

    private var effectiveStatus: RunStatus {
        if store.runStatus != .unknown {
            return store.runStatus
        }
        return runSummary?.status ?? .unknown
    }

    private var canCancel: Bool {
        !effectiveStatus.isTerminal
    }

    private var canApprove: Bool {
        effectiveStatus == .waitingApproval && blockedApprovalTask != nil && !approvalActionInFlight
    }

    @MainActor
    init(
        smithers: SmithersClient,
        runId: String,
        nodeId: String?,
        onOpenTerminalCommand: ((String, String, String) -> Void)? = nil,
        onOpenWorkflow: ((String) -> Void)? = nil,
        onOpenPrompt: (() -> Void)? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        self.smithers = smithers
        self.runId = runId
        self.nodeId = nodeId
        self.onOpenTerminalCommand = onOpenTerminalCommand
        self.onOpenWorkflow = onOpenWorkflow
        self.onOpenPrompt = onOpenPrompt
        self.onClose = onClose
        _store = StateObject(wrappedValue: LiveRunDevToolsStore(streamProvider: smithers))
    }

    var body: some View {
        Group {
            if useLiveRunTreeHarness {
                LiveRunTreeUITestHarnessView(runId: runId, onClose: onClose)
            } else if runNotFound {
                runNotFoundState
            } else {
                liveRunContent
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("view.liveRun")
        .task(id: runId) {
            guard !useLiveRunTreeHarness else { return }
            await connect()
        }
        .onChange(of: store.seq) { _, _ in
            applyDeepLinkSelectionIfNeeded()
        }
        .onChange(of: store.runStatus) { _, status in
            if status != .unknown {
                runLoadError = nil
            }
        }
        .onDisappear {
            guard !useLiveRunTreeHarness else { return }
            teardown()
        }
        .rewindConfirmationDialog(isPresented: $showRewindConfirmation, frameNo: pendingRewindFrameNo) { frameNo in
            pendingRewindFrameNo = nil
            Task {
                await store.rewind(to: frameNo, confirm: true)
                await refreshRunSummary()
            }
        }
        .confirmationDialog(
            "Cancel Run",
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Run", role: .destructive) {
                Task { await cancelRun() }
            }
            .disabled(cancelInFlight)

            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Cancel run \(shortRunID)? This run is still active and will stop immediately.")
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
                guard let pendingDenyTask else { return }
                self.pendingDenyTask = nil
                Task { await deny(task: pendingDenyTask) }
            }
            .disabled(approvalActionInFlight)

            Button("Cancel", role: .cancel) {
                pendingDenyTask = nil
            }
        } message: {
            if let pendingDenyTask {
                Text("Deny approval for \(pendingDenyTask.nodeId) on run \(shortRunID)? This will fail the waiting gate.")
            } else {
                Text("Deny this approval? This will fail the waiting gate.")
            }
        }
    }

    private var liveRunContent: some View {
        VStack(spacing: 0) {
            LiveRunHeaderView(
                status: effectiveStatus,
                workflowName: workflowName,
                runId: runId,
                startedAt: runSummary?.startedAt,
                heartbeatMs: 1_000,
                lastEventAt: store.lastEventAt,
                lastSeq: store.seq,
                onCancel: canCancel ? { showCancelConfirmation = true } : nil,
                onHijack: startHijack,
                onOpenLogs: openLogsInTerminal,
                onRefresh: {
                    Task {
                        store.returnToLive()
                        store.connect(runId: runId)
                        await refreshRunSummary()
                    }
                },
                onOpenWorkflow: onOpenWorkflow.map { handler in
                    { handler(workflowName) }
                },
                smithersVersion: orchestratorVersion
            )

            FrameScrubberView(store: store) { frameNo in
                pendingRewindFrameNo = frameNo
                showRewindConfirmation = true
            }

            if let actionMessage {
                actionBanner(actionMessage, color: actionMessageColor)
            }

            if let runLoadError {
                errorBanner(runLoadError)
            }

            if case .error(let error) = store.connectionState {
                connectionBanner(error)
            }

            if effectiveStatus == .waitingApproval {
                approvalBanner
            }

            LiveRunLayout(
                hasSelection: store.selectedNodeId != nil,
                inspectorSheetPresented: $inspectorSheetPresented,
                onModeChange: handleLayoutModeChange
            ) {
                LiveRunTreeView(store: store) { selectedID in
                    store.selectNode(selectedID)
                    if layoutMode == .narrow {
                        inspectorSheetPresented = true
                    }
                }
            } inspectorPane: {
                NodeInspectorView(
                    store: store,
                    selectedTab: $selectedTab,
                    outputProvider: smithers,
                    logsStreamProvider: smithers,
                    logsHistoryProvider: smithers,
                    onOpenPrompt: onOpenPrompt
                )
            }
            .historicalOverlay(active: store.mode.isHistorical)
            .overlay(alignment: .topLeading) {
                if store.mode.isHistorical {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier("historical.overlay")
                }
            }
        }
    }

    private var runNotFoundState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.warning)

            Text("Run not found")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("The run was deleted or is no longer available.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            Button("Back to Runs") {
                onClose()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("liveRun.backToRuns")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("liveRun.runNotFound")
    }

    private var approvalBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)

            if let task = blockedApprovalTask {
                Text("Waiting for approval: \(task.label ?? task.nodeId)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Button("Approve") {
                    Task { await approve(task: task) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.success)
                .disabled(!canApprove)

                Button("Deny") {
                    pendingDenyTask = task
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .disabled(!canApprove)
            } else {
                Text("Waiting for approval")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.1))
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
        .accessibilityIdentifier("liveRun.approvalBanner")
    }

    private func actionBanner(_ message: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Dismiss") {
                actionMessage = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.1))
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
        .accessibilityIdentifier("liveRun.actionBanner")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)

            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button("Retry") {
                Task { await refreshRunSummary() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.warning.opacity(0.12))
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
        .accessibilityIdentifier("liveRun.errorBanner")
    }

    private func connectionBanner(_ error: DevToolsClientError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)

            Text(error.displayMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button("Retry") {
                store.connect(runId: runId)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("liveRun.connectionRetry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.warning.opacity(0.12))
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
        .accessibilityIdentifier("liveRun.connectionBanner")
    }

    private func connect() async {
        appearsAt = Date()
        AppLogger.ui.info("LiveRunView open", metadata: [
            "run_id": runId,
            "node_id": nodeId ?? "",
        ])

        store.connect(runId: runId)
        await refreshRunSummary()
        startPollingRunSummary()
        applyDeepLinkSelectionIfNeeded()
        if orchestratorVersion == nil {
            Task { @MainActor in
                orchestratorVersion = await smithers.getOrchestratorVersion()
            }
        }
    }

    private func teardown() {
        pollTask?.cancel()
        pollTask = nil

        store.disconnect()
        if store.connectionState != .disconnected || store.runId != nil {
            AppLogger.ui.warning("LiveRunView teardown anomaly", metadata: [
                "run_id": runId,
                "connection_state": String(describing: store.connectionState),
                "store_run_id": store.runId ?? "nil",
            ])
        }

        let durationMs = Int(Date().timeIntervalSince(appearsAt) * 1000)
        AppLogger.ui.info("LiveRunView close", metadata: [
            "run_id": runId,
            "duration_ms": String(durationMs),
        ])
    }

    private func startPollingRunSummary() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await refreshRunSummary()
            }
        }
    }

    private func refreshRunSummary() async {
        do {
            let inspection = try await smithers.inspectRun(runId)
            runSummary = inspection.run
            blockedApprovalTask = inspection.tasks.first(where: isApprovalBlockedTask)
            runLoadError = nil
            runNotFound = false
            if inspection.run.status != .unknown {
                store.setRunStatus(inspection.run.status)
            }
        } catch {
            let message = error.localizedDescription
            if isRunNotFoundError(error) {
                runNotFound = true
                store.disconnect()
            } else {
                runLoadError = message
            }
            AppLogger.error.error("LiveRunView refresh failed", metadata: [
                "run_id": runId,
                "error": message,
            ])
        }
    }

    private func applyDeepLinkSelectionIfNeeded() {
        guard pendingDeepLinkSelection else { return }
        guard let nodeId = nodeId?.trimmingCharacters(in: .whitespacesAndNewlines), !nodeId.isEmpty else {
            pendingDeepLinkSelection = false
            return
        }
        guard let tree = store.tree else { return }
        guard let target = findNode(forTaskNodeId: nodeId, in: tree) else { return }

        store.selectNode(target.id)
        pendingDeepLinkSelection = false
    }

    private func findNode(forTaskNodeId target: String, in node: DevToolsNode) -> DevToolsNode? {
        if let taskNodeId = node.task?.nodeId,
           taskNodeId == target || taskNodeId.hasPrefix(target + ":") {
            return node
        }

        for child in node.children {
            if let found = findNode(forTaskNodeId: target, in: child) {
                return found
            }
        }

        return nil
    }

    private func handleLayoutModeChange(_ newMode: LiveRunLayoutMode) {
        layoutMode = newMode
        AppLogger.ui.info("LiveRunView layout mode", metadata: [
            "run_id": runId,
            "mode": newMode.rawValue,
        ])
    }

    private func cancelRun() async {
        guard !cancelInFlight else { return }
        cancelInFlight = true
        defer { cancelInFlight = false }

        do {
            try await smithers.cancelRun(runId)
            setActionMessage("Run cancelled.", color: Theme.success)
            await refreshRunSummary()
        } catch {
            setActionMessage("Cancel error: \(error.localizedDescription)", color: Theme.danger)
            AppLogger.error.error("LiveRunView cancel failed", metadata: [
                "run_id": runId,
                "error": error.localizedDescription,
            ])
        }
    }

    private func approve(task: RunTask) async {
        guard !approvalActionInFlight else { return }
        approvalActionInFlight = true
        defer { approvalActionInFlight = false }

        do {
            try await smithers.approveNode(runId: runId, nodeId: task.nodeId, iteration: task.iteration)
            setActionMessage("Approved \(task.nodeId).", color: Theme.success)
            await refreshRunSummary()
        } catch {
            setActionMessage("Approve error: \(error.localizedDescription)", color: Theme.danger)
            AppLogger.error.error("LiveRunView approve failed", metadata: [
                "run_id": runId,
                "node_id": task.nodeId,
                "error": error.localizedDescription,
            ])
        }
    }

    private func deny(task: RunTask) async {
        guard !approvalActionInFlight else { return }
        approvalActionInFlight = true
        defer { approvalActionInFlight = false }

        do {
            try await smithers.denyNode(runId: runId, nodeId: task.nodeId, iteration: task.iteration)
            setActionMessage("Denied \(task.nodeId).", color: Theme.success)
            await refreshRunSummary()
        } catch {
            setActionMessage("Deny error: \(error.localizedDescription)", color: Theme.danger)
            AppLogger.error.error("LiveRunView deny failed", metadata: [
                "run_id": runId,
                "node_id": task.nodeId,
                "error": error.localizedDescription,
            ])
        }
    }

    private func startHijack() {
        guard !hijacking else { return }
        hijacking = true
        setActionMessage("Starting hijack session...", color: Theme.accent)

        Task { @MainActor in
            defer { hijacking = false }

            do {
                let session = try await smithers.hijackRun(runId)
                guard session.supportsResume else {
                    setActionMessage("This agent does not support resumable hijack sessions.", color: Theme.warning)
                    return
                }

                guard let invocation = session.launchInvocation() else {
                    setActionMessage("Hijack session is missing resume details.", color: Theme.danger)
                    return
                }

                let command = ([invocation.executable] + invocation.arguments)
                    .map(runInspectorShellQuote)
                    .joined(separator: " ")

                if let onOpenTerminalCommand {
                    onOpenTerminalCommand(command, invocation.workingDirectory, "Hijack \(shortRunID)")
                } else {
                    try await launchHijackInTerminal(command: command, workingDirectory: invocation.workingDirectory)
                }

                setActionMessage("Hijack session launched.", color: Theme.success)
            } catch {
                setActionMessage("Hijack error: \(error.localizedDescription)", color: Theme.danger)
                AppLogger.error.error("LiveRunView hijack failed", metadata: [
                    "run_id": runId,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func openLogsInTerminal() {
        guard let onOpenTerminalCommand else { return }
        let command = "smithers logs \(runInspectorShellQuote(runId))"
        onOpenTerminalCommand(command, FileManager.default.currentDirectoryPath, "Logs \(shortRunID)")
    }

    private func setActionMessage(_ message: String, color: Color) {
        actionMessage = message
        actionMessageColor = color
    }

    private func isRunNotFoundError(_ error: Error) -> Bool {
        if let clientError = error as? DevToolsClientError, case .runNotFound = clientError {
            return true
        }
        if let smithersError = error as? SmithersError, case .notFound = smithersError {
            return true
        }

        let normalized = error.localizedDescription.lowercased()
        return normalized.contains("run not found") || normalized.contains("resource not found")
    }

    private func isApprovalBlockedTask(_ task: RunTask) -> Bool {
        let normalized = task.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "blocked" || normalized == "waiting-approval" || normalized == "waitingapproval"
    }

    private func launchHijackInTerminal(command: String, workingDirectory: String) async throws {
        #if os(macOS)
        let shellCommand = "cd \(runInspectorShellQuote(workingDirectory)); \(command)"
        let script = """
        tell application "Terminal"
            activate
            do script \(appleScriptString(shellCommand))
        end tell
        """
        try await Self.runAppleScript(script)
        #else
        throw SmithersError.notAvailable("Hijack handoff is only available on macOS")
        #endif
    }

    #if os(macOS)
    private nonisolated static func runAppleScript(_ script: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let stderr = Pipe()
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SmithersError.cli(errorText?.isEmpty == false ? errorText! : "Failed to launch hijack terminal session")
            }
        }.value
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    #endif
}

private extension RunStatus {
    var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled:
            return true
        case .running, .waitingApproval, .unknown:
            return false
        }
    }
}
