import SwiftUI

struct RunsView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var runs: [RunSummary] = []
    @State private var expandedRunId: String?
    @State private var inspections: [String: RunInspection] = [:]
    @State private var isLoading = true
    @State private var error: String?

    // Filters
    @State private var statusFilter: RunStatus?
    @State private var searchText = ""
    @State private var dateFilter: DateFilter = .all

    enum DateFilter: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case week = "This Week"
        case month = "This Month"
    }

    private var filteredRuns: [RunSummary] {
        var result = runs
        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }
        if !searchText.isEmpty {
            result = result.filter {
                ($0.workflowName ?? "").localizedCaseInsensitiveContains(searchText) ||
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
            runsList
        }
        .background(Theme.surface1)
        .task { await loadRuns() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Runs")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
            Button(action: { Task { await loadRuns() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                TextField("Search runs...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .frame(maxWidth: 200)

            // Status filter
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

            // Date filter
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

            if statusFilter != nil || dateFilter != .all || !searchText.isEmpty {
                Button(action: { statusFilter = nil; dateFilter = .all; searchText = "" }) {
                    Text("Clear")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Count
            Text("\(filteredRuns.count) runs")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .border(Theme.border, edges: [.bottom])
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
                    Button("Retry") { Task { await loadRuns() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.accent)
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
                // Group runs by status category
                ScrollView {
                    VStack(spacing: 0) {
                        let active = filteredRuns.filter { $0.status == .running || $0.status == .waitingApproval }
                        let completed = filteredRuns.filter { $0.status == .finished }
                        let failed = filteredRuns.filter { $0.status == .failed || $0.status == .cancelled }

                        if !active.isEmpty {
                            runSection("ACTIVE", runs: active)
                        }
                        if !completed.isEmpty {
                            runSection("COMPLETED", runs: completed)
                        }
                        if !failed.isEmpty {
                            runSection("FAILED", runs: failed)
                        }
                    }
                    .padding(20)
                }
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
                        if expandedRunId == run.id {
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
        Button(action: { toggleExpand(run) }) {
            HStack(spacing: 12) {
                Image(systemName: expandedRunId == run.id ? "chevron.down" : "chevron.right")
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

                if run.status == .running && run.totalNodes > 0 {
                    ProgressBar(progress: run.progress)
                        .frame(width: 80)
                    Text("\(Int(run.progress * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: 32, alignment: .trailing)
                }

                Text(run.elapsedString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Run Detail (expanded)

    private func runDetail(_ run: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Action buttons
            HStack(spacing: 8) {
                if run.status == .waitingApproval {
                    actionButton("Approve", icon: "checkmark", color: Theme.success) {
                        // Will need nodeId from inspection
                    }
                    actionButton("Deny", icon: "xmark", color: Theme.danger) {
                        // Will need nodeId from inspection
                    }
                }
                if run.status == .running || run.status == .waitingApproval {
                    actionButton("Cancel", icon: "stop.fill", color: Theme.danger) {
                        Task { await cancelRun(run.runId) }
                    }
                }
                Spacer()
            }

            // Node tasks
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
                        }
                        .padding(.vertical, 4)
                        if task.id != inspection.tasks.last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            } else {
                HStack {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Loading nodes...")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            // Error info
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
        .padding(.leading, 24) // indent under chevron
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

    private func nodeStateIcon(_ state: String) -> some View {
        let (icon, color): (String, Color) = {
            switch state {
            case "running": return ("circle.fill", Theme.accent)
            case "finished": return ("checkmark.circle.fill", Theme.success)
            case "failed": return ("xmark.circle.fill", Theme.danger)
            case "skipped": return ("minus.circle.fill", Theme.textTertiary)
            case "blocked": return ("pause.circle.fill", Theme.warning)
            default: return ("circle", Theme.textTertiary) // pending
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
        case "blocked": return Theme.warning
        default: return Theme.textTertiary
        }
    }

    // MARK: - Actions

    private func toggleExpand(_ run: RunSummary) {
        if expandedRunId == run.id {
            expandedRunId = nil
        } else {
            expandedRunId = run.id
            if inspections[run.id] == nil {
                Task { await loadInspection(run.runId) }
            }
        }
    }

    private func loadRuns() async {
        isLoading = true
        error = nil
        do {
            runs = try await smithers.listRuns()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func loadInspection(_ runId: String) async {
        do {
            let inspection = try await smithers.inspectRun(runId)
            inspections[runId] = inspection
        } catch {
            // Silently fail — row will show the error
        }
    }

    private func cancelRun(_ runId: String) async {
        do {
            try await smithers.cancelRun(runId)
            await loadRuns()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
