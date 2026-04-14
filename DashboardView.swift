import SwiftUI

struct DashboardView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var tab: DashboardTab = .overview
    @State private var runs: [RunSummary] = []
    @State private var workflows: [Workflow] = []
    @State private var approvals: [Approval] = []
    @State private var isLoading = true
    @State private var error: String?

    enum DashboardTab: String, CaseIterable {
        case overview = "Overview"
        case runs = "Runs"
        case workflows = "Workflows"
        case approvals = "Approvals"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Dashboard")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
                Button(action: { Task { await loadAll() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .border(Theme.border, edges: [.bottom])

            // Tabs
            HStack(spacing: 0) {
                ForEach(DashboardTab.allCases, id: \.self) { t in
                    Button(action: { tab = t }) {
                        Text(t.rawValue)
                            .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                            .foregroundColor(tab == t ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if tab == t {
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(height: 2)
                        }
                    }
                }
                Spacer()
            }
            .border(Theme.border, edges: [.bottom])

            // Content
            if let error {
                errorView(error)
            } else {
                switch tab {
                case .overview:
                    overviewContent
                case .runs:
                    runsContent
                case .workflows:
                    workflowsContent
                case .approvals:
                    approvalsContent
                }
            }
        }
        .background(Theme.surface1)
        .task { await loadAll() }
    }

    // MARK: - Overview Tab

    private var overviewContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Stats cards
                HStack(spacing: 12) {
                    StatCard(
                        title: "Active Runs",
                        value: "\(runs.filter { $0.status == .running }.count)",
                        icon: "play.circle.fill",
                        color: Theme.success
                    )
                    StatCard(
                        title: "Pending Approvals",
                        value: "\(approvals.filter { $0.status == "pending" }.count)",
                        icon: "checkmark.shield.fill",
                        color: Theme.warning
                    )
                    StatCard(
                        title: "Workflows",
                        value: "\(workflows.count)",
                        icon: "arrow.triangle.branch",
                        color: Theme.accent
                    )
                    StatCard(
                        title: "Failed Runs",
                        value: "\(runs.filter { $0.status == .failed }.count)",
                        icon: "xmark.circle.fill",
                        color: Theme.danger
                    )
                }

                // Recent runs
                if !runs.isEmpty {
                    SectionCard(title: "Recent Runs") {
                        ForEach(runs.prefix(5)) { run in
                            RunRow(run: run)
                            if run.id != runs.prefix(5).last?.id {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }

                // Pending approvals
                let pending = approvals.filter { $0.status == "pending" }
                if !pending.isEmpty {
                    SectionCard(title: "Pending Approvals") {
                        ForEach(pending.prefix(5)) { approval in
                            ApprovalRow(approval: approval)
                            if approval.id != pending.prefix(5).last?.id {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }

                // Workflows
                if !workflows.isEmpty {
                    SectionCard(title: "Workflows") {
                        ForEach(workflows.prefix(5)) { workflow in
                            WorkflowRow(workflow: workflow)
                            if workflow.id != workflows.prefix(5).last?.id {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Runs Tab

    private var runsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if runs.isEmpty && !isLoading {
                    emptySection("No runs found", icon: "play.circle")
                } else {
                    ForEach(runs) { run in
                        RunRow(run: run)
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Workflows Tab

    private var workflowsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if workflows.isEmpty && !isLoading {
                    emptySection("No workflows found", icon: "arrow.triangle.branch")
                } else {
                    ForEach(workflows) { workflow in
                        WorkflowRow(workflow: workflow)
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Approvals Tab

    private var approvalsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                let pending = approvals.filter { $0.status == "pending" }
                if pending.isEmpty && !isLoading {
                    emptySection("No pending approvals", icon: "checkmark.shield")
                } else {
                    ForEach(pending) { approval in
                        ApprovalRow(approval: approval)
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        error = nil
        do {
            async let r = smithers.listRuns()
            async let w = smithers.listWorkflows()
            async let a = smithers.listPendingApprovals()
            let (fetchedRuns, fetchedWorkflows, fetchedApprovals) = try await (r, w, a)
            runs = fetchedRuns
            workflows = fetchedWorkflows
            approvals = fetchedApprovals
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Helpers

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await loadAll() } }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptySection(_ message: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(Theme.textTertiary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Row Components

struct RunRow: View {
    let run: RunSummary

    var body: some View {
        HStack(spacing: 12) {
            StatusPill(status: run.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.workflowName ?? run.runId)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(String(run.runId.prefix(8)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                    if run.totalNodes > 0 {
                        Text("\(run.finishedNodes)/\(run.totalNodes) nodes")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }

            Spacer()

            if run.status == .running, run.totalNodes > 0 {
                ProgressBar(progress: run.progress)
                    .frame(width: 60)
            }

            Text(run.elapsedString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.vertical, 8)
    }
}

struct WorkflowRow: View {
    let workflow: Workflow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundColor(Theme.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if let path = workflow.relativePath {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let status = workflow.status {
                Text(status.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(workflowStatusColor(status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(workflowStatusColor(status).opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 8)
    }

    private func workflowStatusColor(_ status: WorkflowStatus) -> Color {
        switch status {
        case .active: return Theme.success
        case .hot: return Theme.warning
        case .draft: return Theme.textTertiary
        case .archived: return Theme.textTertiary
        }
    }
}

struct ApprovalRow: View {
    let approval: Approval

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: approval.status == "pending" ? "circle" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(approval.status == "pending" ? Theme.warning : Theme.success)

            VStack(alignment: .leading, spacing: 2) {
                Text(approval.gate ?? approval.nodeId)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("Run: \(String(approval.runId.prefix(8)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer()

            Text(approval.waitTime)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Shared UI Components

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Spacer()
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Theme.surface2)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

struct StatusPill: View {
    let status: RunStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.15))
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch status {
        case .running: return Theme.accent
        case .waitingApproval: return Theme.warning
        case .finished: return Theme.success
        case .failed: return Theme.danger
        case .cancelled: return Theme.textTertiary
        }
    }
}

struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.border)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.accent)
                    .frame(width: geo.size.width * max(0, min(1, progress)), height: 6)
            }
        }
        .frame(height: 6)
    }
}
