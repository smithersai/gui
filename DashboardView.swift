import SwiftUI

private struct DashboardLoadResult<Value> {
    let value: Value
    let error: Error?
}

private enum DashboardDataSource: CaseIterable, Hashable {
    case runs
    case workflows
    case approvals
    case landings
    case issues
    case workspaces

    var label: String {
        switch self {
        case .runs:
            return "Runs"
        case .workflows:
            return "Workflows"
        case .approvals:
            return "Approvals"
        case .landings:
            return "Landings"
        case .issues:
            return "Issues"
        case .workspaces:
            return "Workspaces"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var smithers: SmithersClient
    var sessionSnapshots: [ChatSession] = []
    var onNavigate: ((NavDestination) -> Void)? = nil
    var onNewChat: (() -> Void)? = nil
    var onAutoPopulateActiveRuns: (([RunSummary]) -> Void)? = nil

    @State private var tab: DashboardTab = .overview
    @State private var runs: [RunSummary] = []
    @State private var workflows: [Workflow] = []
    @State private var approvals: [Approval] = []
    @State private var landings: [Landing] = []
    @State private var issues: [SmithersIssue] = []
    @State private var workspaces: [Workspace] = []
    @State private var repoName: String?
    @State private var hasJJHubTransport = UITestSupport.isEnabled
    @State private var hasSmithersProject = true
    @State private var isLoading = true
    @State private var isInitializingSmithers = false
    @State private var error: String?
    @State private var initializationError: String?
    @State private var sourceErrors: [DashboardDataSource: String] = [:]
    @State private var loadGeneration = 0

    enum DashboardTab: String, CaseIterable {
        case overview = "Overview"
        case runs = "Runs"
        case workflows = "Workflows"
        case approvals = "Approvals"
        case sessions = "Sessions"
        case landings = "Landings"
        case issues = "Issues"
        case workspaces = "Workspaces"
    }

    private var sortedRuns: [RunSummary] {
        runs.sortedByStartedAtDescending()
    }

    private var activeRuns: [RunSummary] {
        sortedRuns.filter { $0.status == .running || $0.status == .waitingApproval }
    }

    private var pendingApprovals: [Approval] {
        approvals.filterPendingApprovals()
    }

    private var pendingApprovalCount: Int {
        pendingApprovals.count
    }

    private var openLandingsCount: Int {
        landings.filter {
            let state = ($0.state ?? "").lowercased()
            return state == "open" || state == "ready"
        }.count
    }

    private var openIssuesCount: Int {
        issues.filter { ($0.state ?? "").lowercased() == "open" }.count
    }

    private var activeWorkspacesCount: Int {
        workspaces.filter {
            let status = ($0.status ?? "").lowercased()
            return status == "running" || status == "active"
        }.count
    }

    private var visibleTabs: [DashboardTab] {
        var tabs: [DashboardTab] = [.overview, .runs, .workflows, .approvals, .sessions]
        if hasJJHubTransport {
            tabs += [.landings, .issues, .workspaces]
        }
        return tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Tabs
            HStack(spacing: 0) {
                ForEach(visibleTabs, id: \.self) { t in
                    DashboardTabButton(label: t.rawValue, isActive: tab == t) {
                        withAnimation(.easeInOut(duration: 0.2)) { tab = t }
                    }
                    .accessibilityIdentifier("dashboard.tab.\(t.rawValue)")
                }
                Spacer()
            }
            .border(Theme.border, edges: [.bottom])

            // Content
            if let error {
                errorView(error)
            } else {
                Group {
                    switch tab {
                    case .overview:
                        overviewContent
                    case .runs:
                        runsContent
                    case .workflows:
                        workflowsContent
                    case .approvals:
                        approvalsContent
                    case .sessions:
                        sessionsContent
                    case .landings:
                        landingsContent
                    case .issues:
                        issuesContent
                    case .workspaces:
                        workspacesContent
                    }
                }
                .transition(.opacity)
                .id(tab)
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("dashboard.root")
        .task { await loadAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Dashboard")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    if let repo = repoName, !repo.isEmpty {
                        Text(repo)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                            .accessibilityIdentifier("dashboard.repoName")
                    }
                }
                if !hasSmithersProject {
                    Text("Smithers is not initialized in this repository")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.warning)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if !activeRuns.isEmpty {
                    HeaderIndicator(text: "● \(activeRuns.count) active", color: Theme.success)
                        .accessibilityIdentifier("dashboard.indicator.activeRuns")
                }
                if !pendingApprovals.isEmpty {
                    HeaderIndicator(
                        text: "⚠ \(pendingApprovalCount) pending approval\(pendingApprovalCount == 1 ? "" : "s")",
                        color: pendingApprovalCount >= 5 ? Theme.danger : Theme.warning
                    )
                    .accessibilityIdentifier("dashboard.indicator.pendingApprovals")
                }
                if hasJJHubTransport && openLandingsCount > 0 {
                    HeaderIndicator(
                        text: "⬆ \(openLandingsCount) landing\(openLandingsCount == 1 ? "" : "s")",
                        color: Theme.accent
                    )
                    .accessibilityIdentifier("dashboard.indicator.openLandings")
                }
            }

            if isLoading || isInitializingSmithers {
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
    }

    // MARK: - Overview Tab

    private var overviewContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let initializationError {
                    actionErrorBanner(initializationError)
                }
                if !sourceErrors.isEmpty {
                    partialLoadErrorBanner
                }

                quickActionsSection

                // Smithers stats
                HStack(spacing: 12) {
                    StatCard(
                        title: "Active Runs",
                        value: statValue(.runs, activeRuns.count),
                        icon: statIcon(.runs, fallback: "play.circle.fill"),
                        color: statColor(.runs, fallback: Theme.success)
                    )
                    StatCard(
                        title: "Pending Approvals",
                        value: statValue(.approvals, pendingApprovalCount),
                        icon: statIcon(.approvals, fallback: "checkmark.shield.fill"),
                        color: statColor(.approvals, fallback: Theme.warning)
                    )
                    StatCard(
                        title: "Workflows",
                        value: statValue(.workflows, workflows.count),
                        icon: statIcon(.workflows, fallback: "arrow.triangle.branch"),
                        color: statColor(.workflows, fallback: Theme.accent)
                    )
                    StatCard(
                        title: "Failed Runs",
                        value: statValue(.runs, runs.filter { $0.status == .failed }.count),
                        icon: statIcon(.runs, fallback: "xmark.circle.fill"),
                        color: statColor(.runs, fallback: Theme.danger)
                    )
                }

                // JJHub stats
                if hasJJHubTransport {
                    HStack(spacing: 12) {
                        StatCard(
                            title: "Open Landings",
                            value: statValue(.landings, openLandingsCount),
                            icon: statIcon(.landings, fallback: "arrow.down.to.line"),
                            color: statColor(.landings, fallback: Theme.accent)
                        )
                        StatCard(
                            title: "Open Issues",
                            value: statValue(.issues, openIssuesCount),
                            icon: statIcon(.issues, fallback: "exclamationmark.circle.fill"),
                            color: statColor(.issues, fallback: Theme.success)
                        )
                        StatCard(
                            title: "Active Workspaces",
                            value: statValue(.workspaces, activeWorkspacesCount),
                            icon: statIcon(.workspaces, fallback: "desktopcomputer"),
                            color: statColor(.workspaces, fallback: Theme.warning)
                        )
                    }
                }

                if !sortedRuns.isEmpty {
                    SectionCard(title: "Recent Runs") {
                        ForEach(sortedRuns.prefix(5)) { run in
                            RunRow(run: run)
                            if run.id != sortedRuns.prefix(5).last?.id {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }

                if !pendingApprovals.isEmpty {
                    SectionCard(title: "Pending Approvals") {
                        ForEach(pendingApprovals.prefix(5)) { approval in
                            ApprovalRow(approval: approval)
                            if approval.id != pendingApprovals.prefix(5).last?.id {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }

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

                if hasJJHubTransport {
                    SectionCard(title: "Codeplane At A Glance") {
                        DashboardMetricRow(
                            icon: "arrow.down.to.line",
                            title: "Landings",
                            detail: sourceDetail(.landings, "\(landings.count) total · \(openLandingsCount) open")
                        )
                        Divider().background(Theme.border)
                        DashboardMetricRow(
                            icon: "exclamationmark.circle",
                            title: "Issues",
                            detail: sourceDetail(.issues, "\(issues.count) total · \(openIssuesCount) open")
                        )
                        Divider().background(Theme.border)
                        DashboardMetricRow(
                            icon: "desktopcomputer",
                            title: "Workspaces",
                            detail: sourceDetail(.workspaces, "\(workspaces.count) total · \(activeWorkspacesCount) active")
                        )
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    // MARK: - Runs Tab

    private var runsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Runs view",
                    accessibilityID: "dashboard.route.runs"
                ) {
                    onNavigate?(.runs)
                }

                if sourceErrors[.runs] != nil && runs.isEmpty && !isLoading {
                    emptySection("Unable to load runs", icon: "exclamationmark.triangle")
                } else if sortedRuns.isEmpty && !isLoading {
                    emptySection("No runs found", icon: "play.circle")
                } else {
                    ForEach(sortedRuns) { run in
                        RunRow(run: run)
                        if run.id != sortedRuns.last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    // MARK: - Workflows Tab

    private var workflowsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Workflows view",
                    accessibilityID: "dashboard.route.workflows"
                ) {
                    onNavigate?(.workflows)
                }

                if sourceErrors[.workflows] != nil && workflows.isEmpty && !isLoading {
                    emptySection("Unable to load workflows", icon: "exclamationmark.triangle")
                } else if workflows.isEmpty && !isLoading {
                    emptySection("No workflows found", icon: "arrow.triangle.branch")
                } else {
                    ForEach(workflows) { workflow in
                        WorkflowRow(workflow: workflow)
                        if workflow.id != workflows.last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    // MARK: - Approvals Tab

    private var approvalsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Approvals view",
                    accessibilityID: "dashboard.route.approvals"
                ) {
                    onNavigate?(.approvals)
                }

                if sourceErrors[.approvals] != nil && approvals.isEmpty && !isLoading {
                    emptySection("Unable to load approvals", icon: "exclamationmark.triangle")
                } else if pendingApprovals.isEmpty && !isLoading {
                    emptySection("No pending approvals", icon: "checkmark.shield")
                } else {
                    ForEach(pendingApprovals) { approval in
                        ApprovalRow(approval: approval)
                        if approval.id != pendingApprovals.last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    // MARK: - Sessions Tab

    private var sessionsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open chat sessions",
                    accessibilityID: "dashboard.route.chat"
                ) {
                    onNavigate?(.chat)
                }

                if sessionSnapshots.isEmpty {
                    emptySection("No sessions yet", icon: "message")
                } else {
                    ForEach(sessionSnapshots.prefix(20), id: \.id) { session in
                        DashboardSessionRow(session: session)
                            .accessibilityIdentifier("dashboard.session.\(session.id)")
                        if session.id != sessionSnapshots.prefix(20).last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    // MARK: - JJHub Tabs

    private var landingsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Landings view",
                    accessibilityID: "dashboard.route.landings"
                ) {
                    onNavigate?(.landings)
                }

                if sourceErrors[.landings] != nil && landings.isEmpty && !isLoading {
                    emptySection("Unable to load landings", icon: "exclamationmark.triangle")
                } else if landings.isEmpty && !isLoading {
                    emptySection("No landings found", icon: "arrow.down.to.line")
                } else {
                    ForEach(landings.prefix(20)) { landing in
                        LandingSummaryRow(landing: landing)
                        if landing.id != landings.prefix(20).last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    private var issuesContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Issues view",
                    accessibilityID: "dashboard.route.issues"
                ) {
                    onNavigate?(.issues)
                }

                if sourceErrors[.issues] != nil && issues.isEmpty && !isLoading {
                    emptySection("Unable to load issues", icon: "exclamationmark.triangle")
                } else if issues.isEmpty && !isLoading {
                    emptySection("No issues found", icon: "exclamationmark.circle")
                } else {
                    ForEach(issues.prefix(20)) { issue in
                        IssueSummaryRow(issue: issue)
                        if issue.id != issues.prefix(20).last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    private var workspacesContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Workspaces view",
                    accessibilityID: "dashboard.route.workspaces"
                ) {
                    onNavigate?(.workspaces)
                }

                if sourceErrors[.workspaces] != nil && workspaces.isEmpty && !isLoading {
                    emptySection("Unable to load workspaces", icon: "exclamationmark.triangle")
                } else if workspaces.isEmpty && !isLoading {
                    emptySection("No workspaces found", icon: "desktopcomputer")
                } else {
                    ForEach(workspaces.prefix(20)) { workspace in
                        WorkspaceSummaryRow(workspace: workspace)
                        if workspace.id != workspaces.prefix(20).last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        sourceErrors = [:]
        var nextSourceErrors: [DashboardDataSource: String] = [:]

        hasSmithersProject = smithers.hasSmithersProject()
        if !hasSmithersProject {
            runs = []
            workflows = []
            approvals = []
        } else {
            async let runsResult = loadRuns()
            async let workflowsResult = loadWorkflows()
            async let approvalsResult = loadApprovals()

            let (loadedRuns, loadedWorkflows, loadedApprovals) = await (runsResult, workflowsResult, approvalsResult)
            guard generation == loadGeneration else { return }
            runs = loadedRuns.value
            workflows = loadedWorkflows.value
            approvals = loadedApprovals.value
            onAutoPopulateActiveRuns?(loadedRuns.value)
            recordSourceError(loadedRuns.error, source: .runs, into: &nextSourceErrors)
            recordSourceError(loadedWorkflows.error, source: .workflows, into: &nextSourceErrors)
            recordSourceError(loadedApprovals.error, source: .approvals, into: &nextSourceErrors)
            sourceErrors = nextSourceErrors

            let allSmithersFailed = loadedRuns.error != nil && loadedWorkflows.error != nil && loadedApprovals.error != nil
            if allSmithersFailed, let firstError = loadedRuns.error ?? loadedWorkflows.error ?? loadedApprovals.error {
                error = firstError.localizedDescription
            }
        }

        do {
            let repo = try await smithers.getCurrentRepo()
            guard generation == loadGeneration else { return }
            repoName = repo.fullName ?? repo.name
            hasJJHubTransport = true

            async let landingsResult = loadLandings()
            async let issuesResult = loadIssues()
            async let workspacesResult = loadWorkspaces()
            let (loadedLandings, loadedIssues, loadedWorkspaces) = await (landingsResult, issuesResult, workspacesResult)
            guard generation == loadGeneration else { return }
            landings = loadedLandings.value
            issues = loadedIssues.value
            workspaces = loadedWorkspaces.value
            recordSourceError(loadedLandings.error, source: .landings, into: &nextSourceErrors)
            recordSourceError(loadedIssues.error, source: .issues, into: &nextSourceErrors)
            recordSourceError(loadedWorkspaces.error, source: .workspaces, into: &nextSourceErrors)
            sourceErrors = nextSourceErrors
        } catch {
            guard generation == loadGeneration else { return }
            hasJJHubTransport = false
            repoName = nil
            landings = []
            issues = []
            workspaces = []
        }

        if !visibleTabs.contains(tab) {
            tab = .overview
        }
        isLoading = false
    }

    // MARK: - Helpers

    private var quickActionsSection: some View {
        SectionCard(title: "Quick Actions") {
            VStack(spacing: 8) {
                if !hasSmithersProject {
                    dashboardActionButton(
                        icon: "sparkles",
                        title: "Initialize Smithers",
                        subtitle: "Create project scaffolding in .smithers/",
                        accessibilityID: "dashboard.action.initializeSmithers",
                        enabled: !isInitializingSmithers
                    ) {
                        Task { await initializeSmithersFromDashboard() }
                    }
                }

                dashboardActionButton(
                    icon: "bolt.fill",
                    title: "Run Workflow",
                    subtitle: "Jump to workflows and launch one",
                    accessibilityID: "dashboard.action.runWorkflow"
                ) {
                    onNavigate?(.workflows)
                }

                dashboardActionButton(
                    icon: "message.fill",
                    title: "New Chat",
                    subtitle: "Start a fresh AI session",
                    accessibilityID: "dashboard.action.newChat"
                ) {
                    if let onNewChat {
                        onNewChat()
                    } else {
                        onNavigate?(.chat)
                    }
                }

                dashboardActionButton(
                    icon: "folder.fill",
                    title: "Browse Sessions",
                    subtitle: "Open chat history and run tabs",
                    accessibilityID: "dashboard.action.browseSessions"
                ) {
                    tab = .sessions
                }
            }
        }
    }

    private var partialLoadErrorBanner: some View {
        let failedSources = DashboardDataSource.allCases
            .filter { sourceErrors[$0] != nil }
            .map(\.label)
            .joined(separator: ", ")

        return actionErrorBanner("Unable to load: \(failedSources). Affected stats are unavailable.")
    }

    private func statValue(_ source: DashboardDataSource, _ value: Int) -> String {
        sourceErrors[source] == nil ? "\(value)" : "—"
    }

    private func statIcon(_ source: DashboardDataSource, fallback: String) -> String {
        sourceErrors[source] == nil ? fallback : "exclamationmark.triangle.fill"
    }

    private func statColor(_ source: DashboardDataSource, fallback: Color) -> Color {
        sourceErrors[source] == nil ? fallback : Theme.warning
    }

    private func sourceDetail(_ source: DashboardDataSource, _ detail: String) -> String {
        sourceErrors[source] == nil ? detail : "Unavailable"
    }

    private func dashboardActionButton(
        icon: String,
        title: String,
        subtitle: String,
        accessibilityID: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        DashboardActionRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            enabled: enabled,
            action: action
        )
        .accessibilityIdentifier(accessibilityID)
    }

    private func tabRouteButton(title: String, accessibilityID: String, action: @escaping () -> Void) -> some View {
        TabRouteButton(title: title, action: action)
            .accessibilityIdentifier(accessibilityID)
    }

    private func actionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.1))
        .cornerRadius(8)
    }

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

    private func loadRuns() async -> DashboardLoadResult<[RunSummary]> {
        do {
            let loadedRuns = try await smithers.listRuns()
            return DashboardLoadResult(value: loadedRuns.sortedByStartedAtDescending(), error: nil)
        } catch {
            return DashboardLoadResult(value: [], error: error)
        }
    }

    private func loadWorkflows() async -> DashboardLoadResult<[Workflow]> {
        do {
            return DashboardLoadResult(value: try await smithers.listWorkflows(), error: nil)
        } catch {
            return DashboardLoadResult(value: [], error: error)
        }
    }

    private func loadApprovals() async -> DashboardLoadResult<[Approval]> {
        do {
            return DashboardLoadResult(value: try await smithers.listPendingApprovals(), error: nil)
        } catch {
            return DashboardLoadResult(value: [], error: error)
        }
    }

    private func loadLandings() async -> DashboardLoadResult<[Landing]> {
        do {
            return DashboardLoadResult(value: try await smithers.listLandings(), error: nil)
        } catch {
            return DashboardLoadResult(value: [], error: error)
        }
    }

    private func loadIssues() async -> DashboardLoadResult<[SmithersIssue]> {
        do {
            return DashboardLoadResult(value: try await smithers.listIssues(state: "open"), error: nil)
        } catch {
            return DashboardLoadResult(value: [], error: error)
        }
    }

    private func loadWorkspaces() async -> DashboardLoadResult<[Workspace]> {
        do {
            return DashboardLoadResult(value: try await smithers.listWorkspaces(), error: nil)
        } catch {
            return DashboardLoadResult(value: [], error: error)
        }
    }

    private func recordSourceError(
        _ error: Error?,
        source: DashboardDataSource,
        into sourceErrors: inout [DashboardDataSource: String]
    ) {
        if let error {
            sourceErrors[source] = error.localizedDescription
        }
    }

    private func initializeSmithersFromDashboard() async {
        isInitializingSmithers = true
        initializationError = nil
        do {
            try await smithers.initializeSmithers()
            await loadAll()
        } catch {
            initializationError = error.localizedDescription
        }
        isInitializingSmithers = false
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

// MARK: - Dashboard Helpers

struct DashboardTabButton: View {
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? Theme.accent : (isHovered ? Theme.textPrimary : Theme.textSecondary))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(isHovered && !isActive ? Color.white.opacity(0.03) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Theme.accent : .clear)
                .frame(height: 2)
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isActive)
        .onHover { isHovered = $0 }
    }
}

struct HeaderIndicator: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .cornerRadius(999)
    }
}

struct TabRouteButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if isHovered {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundColor(Theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isHovered ? Theme.accent.opacity(0.18) : Theme.accent.opacity(0.12))
            .cornerRadius(6)
            .padding(.bottom, 10)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct DashboardActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let enabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(enabled ? Theme.accent : Theme.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(enabled ? Theme.textPrimary : Theme.textTertiary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()

                if isHovered && enabled {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && enabled ? Color.white.opacity(0.03) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct DashboardMetricRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Theme.accent)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Summary Rows

struct LandingSummaryRow: View {
    let landing: Landing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: landingIcon)
                .font(.system(size: 12))
                .foregroundColor(landingColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(landing.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let number = landing.number {
                        Text("#\(number)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                    if let state = landing.state {
                        Text(state.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(landingColor)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .themedRowHover()
    }

    private var normalizedState: String {
        (landing.state ?? "").lowercased()
    }

    private var landingIcon: String {
        switch normalizedState {
        case "open", "ready": return "arrow.up"
        case "draft": return "circle.dashed"
        case "merged", "landed": return "checkmark"
        default: return "circle"
        }
    }

    private var landingColor: Color {
        switch normalizedState {
        case "open", "ready": return Theme.accent
        case "draft": return Theme.warning
        case "merged", "landed": return Theme.success
        default: return Theme.textTertiary
        }
    }
}

struct IssueSummaryRow: View {
    let issue: SmithersIssue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: issueIcon)
                .font(.system(size: 12))
                .foregroundColor(issueColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let number = issue.number {
                        Text("#\(number)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                    if let count = issue.commentCount, count > 0 {
                        Text("\(count) comments")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .themedRowHover()
    }

    private var isOpen: Bool {
        (issue.state ?? "").lowercased() == "open"
    }

    private var issueIcon: String {
        isOpen ? "circle" : "checkmark.circle.fill"
    }

    private var issueColor: Color {
        isOpen ? Theme.success : Theme.textTertiary
    }
}

struct WorkspaceSummaryRow: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 12))
                .foregroundColor(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let status = workspace.status {
                        Text(status.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(statusColor)
                    }
                    if let createdAt = workspace.createdAt {
                        Text(createdAt)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .themedRowHover()
    }

    private var statusColor: Color {
        switch (workspace.status ?? "").lowercased() {
        case "running", "active": return Theme.success
        case "suspended": return Theme.warning
        default: return Theme.textTertiary
        }
    }
}

struct DashboardSessionRow: View {
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(session.timestamp)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .themedRowHover()
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
                        Text(nodeProgressText)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }

            Spacer()

            if run.totalNodes > 0 && (run.status == .running || run.status == .waitingApproval) {
                ProgressBar(progress: run.progress, failedProgress: run.failedProgress)
                    .frame(width: 60)
            }

            RunElapsedText(run: run)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.vertical, 8)
        .themedRowHover()
    }

    private var nodeProgressText: String {
        if run.failedNodes > 0 {
            return "\(run.finishedNodes) succeeded, \(run.failedNodes) failed / \(run.totalNodes) nodes"
        }
        return "\(run.completedNodes)/\(run.totalNodes) nodes"
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
        .themedRowHover()
    }

    private func workflowStatusColor(_ status: WorkflowStatus) -> Color {
        switch status {
        case .active: return Theme.success
        case .hot: return Theme.warning
        case .draft: return Theme.textTertiary
        case .archived, .unknown: return Theme.textTertiary
        }
    }
}

struct ApprovalRow: View {
    let approval: Approval

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: approval.isPending ? "circle" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(approval.isPending ? Theme.warning : Theme.success)

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
        .themedRowHover()
    }
}

// MARK: - Shared UI Components

struct RunElapsedText: View {
    let run: RunSummary

    var body: some View {
        if run.status == .running || run.status == .waitingApproval {
            TimelineView(.periodic(from: Date(), by: 1)) { _ in
                Text(run.elapsedString)
            }
        } else {
            Text(run.elapsedString)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    @State private var isHovered = false

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
                .stroke(isHovered ? color.opacity(0.35) : Theme.border, lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(color: isHovered ? color.opacity(0.10) : .clear, radius: 8, y: 2)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("dashboard.stat.\(title.replacingOccurrences(of: " ", with: ""))")
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
        case .cancelled, .unknown: return Theme.textTertiary
        }
    }
}

struct ProgressBar: View {
    let progress: Double
    let failedProgress: Double

    init(progress: Double, failedProgress: Double = 0) {
        self.progress = progress
        self.failedProgress = failedProgress
    }

    var body: some View {
        GeometryReader { geo in
            let completed = max(0, min(1, progress))
            let failed = min(max(0, failedProgress), completed)
            let successfulWidth = geo.size.width * (completed - failed)
            let failedWidth = geo.size.width * failed

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.border)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.success)
                    .frame(width: successfulWidth, height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.danger)
                    .frame(width: failedWidth, height: 6)
                    .offset(x: successfulWidth)
            }
        }
        .frame(height: 6)
    }
}
