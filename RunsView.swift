import SwiftUI

struct RunsView: View {
    @ObservedObject var smithers: SmithersClient
    var onOpenLiveChat: ((RunSummary, String?) -> Void)? = nil
    var onOpenRunInspector: ((RunSummary) -> Void)? = nil
    var onOpenRunSnapshots: ((RunSummary) -> Void)? = nil
    var onOpenTerminalCommand: ((String, String, String) -> Void)? = nil

    @State private var runs: [RunSummary] = []
    @State private var expandedRunIds: Set<String> = []
    @State private var inspections: [String: RunInspection] = [:]
    @State private var inspectionErrors: [String: String] = [:]
    @State private var loadingInspectionRunIds: Set<String> = []
    @State private var isLoading = true
    @State private var error: String?

    @State private var actionMessage: String?
    @State private var actionMessageColor: Color = Theme.textTertiary
    @State private var streamMode: StreamMode?
    @State private var streamTask: Task<Void, Never>?
    @State private var pollingTask: Task<Void, Never>?
    @State private var hijackingRunId: String?
    @State private var pendingCancelRun: RunSummary?
    @State private var pendingDenyNode: PendingDenyNode?
    @State private var didShowPollingMessage = false

    // Filters
    @State private var statusFilter: RunStatus?
    @State private var workflowFilter: String?
    @State private var searchText = ""
    @State private var dateFilter: DateFilter = .all

    enum DateFilter: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case week = "This Week"
        case month = "This Month"
    }

    private enum StreamMode {
        case live
        case polling

        var label: String {
            switch self {
            case .live:
                return "● Live"
            case .polling:
                return "○ Polling"
            }
        }

        var color: Color {
            switch self {
            case .live:
                return Theme.success
            case .polling:
                return Theme.textTertiary
            }
        }
    }

    private struct RunStreamEvent: Decodable {
        let type: String
        let runId: String
        let nodeId: String?
        let iteration: Int?
        let attempt: Int?
        let status: String?
        let timestampMs: Int64?
        let seq: Int?
    }

    private struct RunStreamEnvelope: Decodable {
        let event: RunStreamEvent?
        let data: RunStreamEvent?
    }

    private struct PendingDenyNode: Identifiable {
        let runId: String
        let nodeId: String
        let iteration: Int?

        var id: String { "\(runId):\(nodeId):\(iteration.map(String.init) ?? "nil")" }
        var iterationSuffix: String {
            guard let iteration else { return "" }
            return " iter \(iteration)"
        }
    }

    private var workflowChoices: [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for run in runs {
            guard let name = run.workflowName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                continue
            }
            let key = name.lowercased()
            if seen.insert(key).inserted {
                names.append(name)
            }
        }

        if let workflowFilter,
           !workflowFilter.isEmpty,
           !names.contains(where: { $0.caseInsensitiveCompare(workflowFilter) == .orderedSame }) {
            names.insert(workflowFilter, at: 0)
        }

        return names
    }

    private var filteredRuns: [RunSummary] {
        var result = runs
        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }
        if let workflowFilter, !workflowFilter.isEmpty {
            result = result.filter {
                ($0.workflowName ?? "").localizedCaseInsensitiveContains(workflowFilter)
            }
        }
        if !searchText.isEmpty {
            result = result.filter {
                ($0.workflowName ?? "Unnamed workflow").localizedCaseInsensitiveContains(searchText) ||
                $0.runId.localizedCaseInsensitiveContains(searchText)
            }
        }
        if dateFilter != .all, let cutoff = dateFilterCutoff {
            result = result.filter { ($0.startedAt ?? .distantPast) >= cutoff }
        }
        return result
    }

    private var dateFilterCutoff: Date? {
        let cal = Calendar.current
        switch dateFilter {
        case .all: return nil
        case .today: return cal.startOfDay(for: Date())
        case .week: return cal.date(byAdding: .day, value: -7, to: Date())
        case .month: return cal.date(byAdding: .month, value: -1, to: Date())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            if let actionMessage {
                actionBanner(message: actionMessage, color: actionMessageColor)
            }
            runsList
        }
        .background(Theme.surface1)
        .task {
            await initializeRunsView()
        }
        .onDisappear {
            stopLiveUpdates()
        }
        .confirmationDialog(
            "Cancel Run",
            isPresented: Binding(
                get: { pendingCancelRun != nil },
                set: { if !$0 { pendingCancelRun = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel Run", role: .destructive) {
                if let run = pendingCancelRun {
                    pendingCancelRun = nil
                    Task { await cancelRun(run.runId) }
                }
            }
            .accessibilityIdentifier("runs.confirmCancelButton")

            Button("Keep Running", role: .cancel) {
                pendingCancelRun = nil
            }
            .accessibilityIdentifier("runs.dismissCancelButton")
        } message: {
            if let run = pendingCancelRun {
                Text("Cancel run \(String(run.runId.prefix(8)))? This run is still active and will stop immediately.")
            } else {
                Text("Cancel this run? It will stop immediately.")
            }
        }
        .confirmationDialog(
            "Deny Approval",
            isPresented: Binding(
                get: { pendingDenyNode != nil },
                set: { if !$0 { pendingDenyNode = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Deny Approval", role: .destructive) {
                if let pendingDenyNode {
                    self.pendingDenyNode = nil
                    Task {
                        await denyNode(
                            runId: pendingDenyNode.runId,
                            nodeId: pendingDenyNode.nodeId,
                            iteration: pendingDenyNode.iteration
                        )
                    }
                }
            }
            .accessibilityIdentifier("runs.confirmDenyButton")

            Button("Cancel", role: .cancel) {
                pendingDenyNode = nil
            }
            .accessibilityIdentifier("runs.cancelDenyButton")
        } message: {
            if let pendingDenyNode {
                Text("Deny approval for \(pendingDenyNode.nodeId)\(pendingDenyNode.iterationSuffix) on run \(String(pendingDenyNode.runId.prefix(8)))? This will fail the waiting gate.")
            } else {
                Text("Deny this approval? This will fail the waiting gate.")
            }
        }
        .accessibilityIdentifier("runs.root")
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Runs")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            if let streamMode {
                Text(streamMode.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(streamMode.color)
                    .padding(.leading, 8)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button(action: { Task { await loadRuns(showLoading: true, clearError: true) } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runs.refresh")
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                TextField("Search runs...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("runs.filter.search")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .frame(maxWidth: 200)

            Menu {
                Button("All Statuses") { statusFilter = nil }
                Divider()
                ForEach(RunStatus.allCases, id: \.self) { status in
                    Button(status.label) { statusFilter = status }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(statusFilter?.label ?? "All Statuses")
                        .font(.system(size: 11))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runs.filter.status")

            Menu {
                Button("All Workflows") { workflowFilter = nil }
                if !workflowChoices.isEmpty {
                    Divider()
                    ForEach(workflowChoices, id: \.self) { workflow in
                        Button(workflow) { workflowFilter = workflow }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(workflowFilter ?? "All Workflows")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runs.filter.workflow")

            Menu {
                ForEach(DateFilter.allCases, id: \.self) { df in
                    Button(df.rawValue) { dateFilter = df }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(dateFilter.rawValue)
                        .font(.system(size: 11))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runs.filter.date")

            if statusFilter != nil || workflowFilter != nil || dateFilter != .all || !searchText.isEmpty {
                Button(action: {
                    statusFilter = nil
                    workflowFilter = nil
                    dateFilter = .all
                    searchText = ""
                }) {
                    Text("Clear")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("runs.filter.clear")
            }

            Spacer()

            Text("\(filteredRuns.count) run\(filteredRuns.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .border(Theme.border, edges: [.bottom])
    }

    private func actionBanner(message: String, color: Color) -> some View {
        HStack {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.surface2)
        .border(Theme.border, edges: [.bottom])
        .accessibilityIdentifier("runs.actionMessage")
    }

    // MARK: - Runs List

    private var runsList: some View {
        Group {
            if let error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.warning)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                    Button("Retry") { Task { await loadRuns(showLoading: true, clearError: true) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.accent)
                        .accessibilityIdentifier("runs.retry")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRuns.isEmpty && !isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("No runs found")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        let active = filteredRuns.filter { $0.status == .running || $0.status == .waitingApproval }
                        let completed = filteredRuns.filter { $0.status == .finished }
                        let failed = filteredRuns.filter { $0.status == .failed }
                        let cancelled = filteredRuns.filter { $0.status == .cancelled }

                        if !active.isEmpty {
                            runSection("ACTIVE", runs: active)
                        }
                        if !completed.isEmpty {
                            runSection("COMPLETED", runs: completed)
                        }
                        if !failed.isEmpty {
                            runSection("FAILED", runs: failed)
                        }
                        if !cancelled.isEmpty {
                            runSection("CANCELLED", runs: cancelled)
                        }
                    }
                    .padding(20)
                }
                .refreshable { await loadRuns() }
            }
        }
    }

    private func runSection(_ title: String, runs: [RunSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)
                .padding(.bottom, 8)
                .padding(.top, 12)

            VStack(spacing: 0) {
                ForEach(runs) { run in
                    VStack(spacing: 0) {
                        expandableRunRow(run)
                        if expandedRunIds.contains(run.id) {
                            runDetail(run)
                        }
                        Divider().background(Theme.border)
                    }
                }
            }
            .background(Theme.surface2)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func expandableRunRow(_ run: RunSummary) -> some View {
        HStack(spacing: 8) {
            Button(action: { toggleExpand(run) }) {
                HStack(spacing: 12) {
                    Image(systemName: expandedRunIds.contains(run.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: 12)

                    StatusPill(status: run.status)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.workflowName ?? "Unnamed workflow")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Text(String(run.runId.prefix(8)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }

                    Spacer()

                    if shouldShowProgress(for: run) {
                        ProgressBar(progress: run.progress, failedProgress: run.failedProgress)
                            .frame(width: 80)
                        Text("\(Int((run.progress * 100).rounded()))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 32, alignment: .trailing)
                    }

                    RunElapsedText(run: run)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runs.row.\(runInspectorSafeID(run.runId))")
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if onOpenLiveChat != nil {
                    rowActionButton(
                        icon: "message",
                        color: Theme.accent,
                        help: "Open live chat",
                        accessibilityID: "runs.chat.\(runInspectorSafeID(run.runId))"
                    ) {
                        onOpenLiveChat?(run, nil)
                    }
                }

                if onOpenRunInspector != nil {
                    rowActionButton(
                        icon: "sidebar.right",
                        color: Theme.info,
                        help: "Inspect run",
                        accessibilityID: "runs.inspect.\(runInspectorSafeID(run.runId))"
                    ) {
                        onOpenRunInspector?(run)
                    }
                }

                if onOpenRunSnapshots != nil {
                    rowActionButton(
                        icon: "clock.arrow.circlepath",
                        color: Theme.info,
                        help: "Open snapshots",
                        accessibilityID: "runs.snapshots.\(runInspectorSafeID(run.runId))"
                    ) {
                        onOpenRunSnapshots?(run)
                    }
                }

                if onOpenTerminalCommand != nil {
                    rowActionButton(
                        icon: hijackingRunId == run.runId ? "hourglass" : "arrow.trianglehead.branch",
                        color: Theme.warning,
                        help: "Hijack run",
                        accessibilityID: "runs.hijack.\(runInspectorSafeID(run.runId))"
                    ) {
                        startHijack(for: run)
                    }
                    .disabled(hijackingRunId != nil)
                    .opacity(hijackingRunId == nil ? 1 : 0.55)
                }
            }
            .padding(.trailing, 14)
        }
    }

    // MARK: - Run Detail (expanded)

    private func runDetail(_ run: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if onOpenRunInspector != nil {
                    actionButton("Inspect", icon: "sidebar.right", color: Theme.info) {
                        onOpenRunInspector?(run)
                    }
                }
                if onOpenRunSnapshots != nil {
                    actionButton("Snapshots", icon: "clock.arrow.circlepath", color: Theme.info) {
                        onOpenRunSnapshots?(run)
                    }
                }
                actionButton("Live Chat", icon: "message", color: Theme.accent) {
                    onOpenLiveChat?(run, nil)
                }
                if onOpenTerminalCommand != nil {
                    actionButton(hijackingRunId == run.runId ? "Hijacking..." : "Hijack", icon: "arrow.trianglehead.branch", color: Theme.warning) {
                        startHijack(for: run)
                    }
                    .disabled(hijackingRunId != nil)
                    .opacity(hijackingRunId == nil ? 1 : 0.55)
                }
                if run.status == .waitingApproval {
                    if let inspection = inspections[run.runId],
                       let blockedNode = inspection.tasks.first(where: isApprovalBlockedTask) {
                        actionButton("Approve", icon: "checkmark", color: Theme.success) {
                            Task { await approveNode(runId: run.runId, nodeId: blockedNode.nodeId, iteration: blockedNode.iteration) }
                        }
                        actionButton("Deny", icon: "xmark", color: Theme.danger) {
                            requestDenyNode(runId: run.runId, nodeId: blockedNode.nodeId, iteration: blockedNode.iteration)
                        }
                    } else {
                        if inspectionErrors[run.runId] != nil {
                            actionButton("Retry Nodes", icon: "arrow.clockwise", color: Theme.warning) {
                                Task { await loadInspection(run.runId) }
                            }
                        }
                        actionButton("Approve", icon: "checkmark", color: Theme.success) {}
                            .disabled(true)
                            .opacity(0.5)
                        actionButton("Deny", icon: "xmark", color: Theme.danger) {}
                            .disabled(true)
                            .opacity(0.5)
                    }
                }
                if !run.status.isTerminal {
                    actionButton("Cancel", icon: "stop.fill", color: Theme.danger) {
                        requestCancel(for: run)
                    }
                }
                Spacer()
            }

            if let inspection = inspections[run.runId] {
                VStack(alignment: .leading, spacing: 0) {
                    Text("NODES")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.bottom, 6)

                    ForEach(inspection.tasks) { task in
                        HStack(spacing: 8) {
                            nodeStateIcon(task.state)
                            Text(task.label ?? task.nodeId)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if let iter = task.iteration, iter > 0 {
                                Text("iter \(iter)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Text(task.state)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(nodeStateColor(task.state))
                            Button(action: {
                                onOpenLiveChat?(run, task.nodeId)
                            }) {
                                Image(systemName: "message")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.accent)
                                    .frame(width: 18, height: 18)
                                    .background(Theme.accent.opacity(0.14))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("runs.nodeChat.\(task.nodeId)")
                        }
                        .padding(.vertical, 4)
                        if task.id != inspection.tasks.last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            } else if let inspectionError = inspectionErrors[run.runId] {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.warning)
                    Text("Unable to load nodes: \(inspectionError)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") {
                        Task { await loadInspection(run.runId) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.accent)
                    .accessibilityIdentifier("runs.retryInspection.\(runInspectorSafeID(run.runId))")
                }
                .padding(.vertical, 4)
            } else if loadingInspectionRunIds.contains(run.runId) {
                HStack {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Loading nodes...")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Nodes are not loaded.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                    Button("Load Nodes") {
                        Task { await loadInspection(run.runId) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.accent)
                    .accessibilityIdentifier("runs.loadInspection.\(runInspectorSafeID(run.runId))")
                }
            }

            if let errorJson = run.errorJson {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ERROR")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.danger)
                    Text(errorJson)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.danger.opacity(0.8))
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.08))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.leading, 24)
        .background(Theme.base.opacity(0.3))
    }

    private func actionButton(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func rowActionButton(
        icon: String,
        color: Color,
        help: String,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.14))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(accessibilityID)
    }

    private func shouldShowProgress(for run: RunSummary) -> Bool {
        run.totalNodes > 0 && (run.status == .running || run.status == .waitingApproval)
    }

    private func isApprovalBlockedTask(_ task: RunTask) -> Bool {
        task.state == "blocked" || task.state == "waiting-approval"
    }

    private func nodeStateIcon(_ state: String) -> some View {
        let (icon, color): (String, Color) = {
            switch state {
            case "running": return ("circle.fill", Theme.accent)
            case "finished": return ("checkmark.circle.fill", Theme.success)
            case "failed": return ("xmark.circle.fill", Theme.danger)
            case "skipped": return ("minus.circle.fill", Theme.textTertiary)
            case "blocked", "waiting-approval": return ("pause.circle.fill", Theme.warning)
            default: return ("circle", Theme.textTertiary)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 10))
            .foregroundColor(color)
            .frame(width: 14)
    }

    private func nodeStateColor(_ state: String) -> Color {
        switch state {
        case "running": return Theme.accent
        case "finished": return Theme.success
        case "failed": return Theme.danger
        case "skipped": return Theme.textTertiary
        case "blocked", "waiting-approval": return Theme.warning
        default: return Theme.textTertiary
        }
    }

    // MARK: - Actions

    @MainActor
    private func initializeRunsView() async {
        await loadRuns(showLoading: true, clearError: true)
        startLiveUpdates()
    }

    @MainActor
    private func toggleExpand(_ run: RunSummary) {
        if expandedRunIds.contains(run.id) {
            expandedRunIds.remove(run.id)
        } else {
            expandedRunIds.insert(run.id)
            if inspections[run.id] == nil {
                Task { await loadInspection(run.runId) }
            }
        }
    }

    @MainActor
    private func setActionMessage(_ message: String, color: Color, level: GUINotificationLevel) {
        actionMessage = message
        actionMessageColor = color
        AppNotifications.shared.post(title: "Runs", message: message, level: level)
    }

    @MainActor
    private func requestCancel(for run: RunSummary) {
        guard !run.status.isTerminal else { return }
        pendingCancelRun = run
    }

    @MainActor
    private func requestDenyNode(runId: String, nodeId: String, iteration: Int?) {
        pendingDenyNode = PendingDenyNode(runId: runId, nodeId: nodeId, iteration: iteration)
    }

    @MainActor
    private func loadRuns(showLoading: Bool = true, clearError: Bool = true) async {
        if showLoading {
            isLoading = true
        }
        if clearError {
            error = nil
        }

        do {
            runs = try await smithers.listRuns()
            synchronizeCachedState()
        } catch {
            if runs.isEmpty || clearError {
                self.error = error.localizedDescription
            } else {
                setActionMessage("Refresh error: \(error.localizedDescription)", color: Theme.warning, level: .warning)
            }
        }

        if showLoading {
            isLoading = false
        }
    }

    @MainActor
    private func synchronizeCachedState() {
        let runIDs = Set(runs.map(\.runId))
        expandedRunIds = expandedRunIds.intersection(runIDs)
        inspections = inspections.filter { runIDs.contains($0.key) }
        inspectionErrors = inspectionErrors.filter { runIDs.contains($0.key) }
        loadingInspectionRunIds = loadingInspectionRunIds.intersection(runIDs)
    }

    @MainActor
    private func updateRunStatus(runId: String, status: RunStatus) {
        guard let idx = runs.firstIndex(where: { $0.runId == runId }) else { return }
        runs[idx] = runWithStatus(runs[idx], status: status, timestampMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    private func runWithStatus(_ run: RunSummary, status: RunStatus, timestampMs: Int64?) -> RunSummary {
        let startedAtMs = run.startedAtMs ?? timestampMs
        let finishedAtMs: Int64?

        if status.isTerminal {
            finishedAtMs = run.finishedAtMs ?? timestampMs
        } else {
            finishedAtMs = nil
        }

        return RunSummary(
            runId: run.runId,
            workflowName: run.workflowName,
            workflowPath: run.workflowPath,
            status: status,
            startedAtMs: startedAtMs,
            finishedAtMs: finishedAtMs,
            summary: run.summary,
            errorJson: run.errorJson
        )
    }

    @MainActor
    private func loadInspection(_ runId: String) async {
        guard !loadingInspectionRunIds.contains(runId) else { return }
        loadingInspectionRunIds.insert(runId)
        inspectionErrors[runId] = nil
        defer {
            loadingInspectionRunIds.remove(runId)
        }

        do {
            let inspection = try await smithers.inspectRun(runId)
            inspections[runId] = inspection
        } catch {
            inspectionErrors[runId] = error.localizedDescription
        }
    }

    @MainActor
    private func refreshExpandedInspections() async {
        for runId in expandedRunIds {
            await loadInspection(runId)
        }
    }

    @MainActor
    private func approveNode(runId: String, nodeId: String, iteration: Int?) async {
        do {
            try await smithers.approveNode(runId: runId, nodeId: nodeId, iteration: iteration)
            setActionMessage("Approved run \(String(runId.prefix(8)))", color: Theme.success, level: .approval)
            updateRunStatus(runId: runId, status: .running)
            await refreshExpandedInspections()
            await loadRuns(showLoading: false, clearError: false)
        } catch {
            setActionMessage("Approve error: \(error.localizedDescription)", color: Theme.danger, level: .error)
        }
    }

    @MainActor
    private func denyNode(runId: String, nodeId: String, iteration: Int?) async {
        do {
            try await smithers.denyNode(runId: runId, nodeId: nodeId, iteration: iteration)
            setActionMessage("Denied run \(String(runId.prefix(8)))", color: Theme.success, level: .approval)
            updateRunStatus(runId: runId, status: .failed)
            await refreshExpandedInspections()
            await loadRuns(showLoading: false, clearError: false)
        } catch {
            setActionMessage("Deny error: \(error.localizedDescription)", color: Theme.danger, level: .error)
        }
    }

    @MainActor
    private func cancelRun(_ runId: String) async {
        do {
            try await smithers.cancelRun(runId)
            setActionMessage("Cancelled run \(String(runId.prefix(8)))", color: Theme.success, level: .runUpdate)
            updateRunStatus(runId: runId, status: .cancelled)
            await loadRuns(showLoading: false, clearError: false)
        } catch {
            setActionMessage("Cancel error: \(error.localizedDescription)", color: Theme.danger, level: .error)
        }
    }

    @MainActor
    private func startHijack(for run: RunSummary) {
        guard hijackingRunId == nil else { return }
        guard let onOpenTerminalCommand else {
            setActionMessage("Terminal command hook is unavailable.", color: Theme.warning, level: .warning)
            return
        }

        hijackingRunId = run.runId
        setActionMessage("Starting hijack session...", color: Theme.accent, level: .info)

        Task { @MainActor in
            defer { hijackingRunId = nil }

            do {
                let session = try await smithers.hijackRun(run.runId)
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

                setActionMessage("Hijack ready for run \(String(run.runId.prefix(8))).", color: Theme.success, level: .success)
                onOpenTerminalCommand(command, invocation.workingDirectory, "Hijack \(String(run.runId.prefix(8)))")
            } catch {
                setActionMessage("Hijack error: \(error.localizedDescription)", color: Theme.danger, level: .error)
            }
        }
    }

    // MARK: - Live updates / polling fallback

    @MainActor
    private func startLiveUpdates() {
        stopLiveUpdates()

        streamTask = Task {
            while !Task.isCancelled {
                var receivedEvents = false

                for await event in smithers.streamRunEvents("all-runs") {
                    if Task.isCancelled { return }
                    receivedEvents = true

                    await MainActor.run {
                        streamMode = .live
                        stopPollingFallback()
                        didShowPollingMessage = false
                        handleRunStreamEvent(event)
                    }
                }

                if Task.isCancelled {
                    return
                }

                if receivedEvents {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                await MainActor.run {
                    startPollingFallback()
                }
                return
            }
        }
    }

    @MainActor
    private func stopLiveUpdates() {
        streamTask?.cancel()
        streamTask = nil
        stopPollingFallback()
    }

    @MainActor
    private func startPollingFallback() {
        guard pollingTask == nil else { return }

        streamMode = .polling
        if !didShowPollingMessage {
            setActionMessage("Live stream unavailable. Polling every 5 seconds.", color: Theme.warning, level: .warning)
            didShowPollingMessage = true
        }

        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                await loadRuns(showLoading: false, clearError: false)
            }
        }
    }

    @MainActor
    private func stopPollingFallback() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @MainActor
    private func handleRunStreamEvent(_ event: SSEEvent) {
        guard let runEvent = decodeRunStreamEvent(event) else { return }
        let insertedRunId = applyRunEvent(runEvent)

        if let insertedRunId {
            Task { await enrichInsertedRun(insertedRunId) }
        } else if expandedRunIds.contains(runEvent.runId), runEvent.type.caseInsensitiveCompare("NodeWaitingApproval") == .orderedSame {
            Task { await loadInspection(runEvent.runId) }
        }
    }

    private func decodeRunStreamEvent(_ event: SSEEvent) -> RunStreamEvent? {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8) else {
            return nil
        }

        if let direct = try? JSONDecoder().decode(RunStreamEvent.self, from: data), !direct.runId.isEmpty {
            return direct
        }

        if let wrapped = try? JSONDecoder().decode(RunStreamEnvelope.self, from: data),
           let nested = wrapped.event ?? wrapped.data,
           !nested.runId.isEmpty {
            return nested
        }

        return nil
    }

    @MainActor
    private func applyRunEvent(_ event: RunStreamEvent) -> String? {
        guard !event.runId.isEmpty else { return nil }

        let type = event.type.lowercased()
        let index = runs.firstIndex(where: { $0.runId == event.runId })

        switch type {
        case "runstatuschanged", "runfinished", "runfailed", "runcancelled", "runstarted":
            guard let status = runStatus(from: event) else { return nil }

            if let index {
                guard shouldApplyStatusTransition(from: runs[index].status, to: status) else { return nil }
                runs[index] = runWithStatus(runs[index], status: status, timestampMs: event.timestampMs)
            } else {
                let stub = RunSummary(
                    runId: event.runId,
                    workflowName: nil,
                    workflowPath: nil,
                    status: status,
                    startedAtMs: event.timestampMs,
                    finishedAtMs: status.isTerminal ? event.timestampMs : nil,
                    summary: nil,
                    errorJson: nil
                )
                runs.insert(stub, at: 0)
                return event.runId
            }

        case "nodewaitingapproval":
            guard let index else { return nil }
            guard shouldApplyStatusTransition(from: runs[index].status, to: .waitingApproval) else { return nil }
            runs[index] = runWithStatus(runs[index], status: .waitingApproval, timestampMs: event.timestampMs)

        default:
            break
        }

        return nil
    }

    private func shouldApplyStatusTransition(from current: RunStatus, to next: RunStatus) -> Bool {
        !current.isTerminal || next.isTerminal
    }

    private func runStatus(from event: RunStreamEvent) -> RunStatus? {
        if let raw = event.status {
            let status = RunStatus.normalized(raw)
            if status != .unknown {
                return status
            }
        }

        switch event.type.lowercased() {
        case "runstarted":
            return .running
        case "runfinished":
            return .finished
        case "runfailed":
            return .failed
        case "runcancelled":
            return .cancelled
        default:
            return event.status == nil ? nil : .unknown
        }
    }

    @MainActor
    private func enrichInsertedRun(_ runId: String) async {
        do {
            let inspection = try await smithers.inspectRun(runId)
            if let index = runs.firstIndex(where: { $0.runId == runId }) {
                runs[index] = inspection.run
            }
            inspections[runId] = inspection
        } catch {
            await loadRuns(showLoading: false, clearError: false)
        }
    }
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
