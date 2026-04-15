import SwiftUI

private enum VCSDataSource: CaseIterable, Hashable {
    case changes
    case landings
    case issues
    case tickets
    case jjhubWorkflows

    var label: String {
        switch self {
        case .changes: return "Changes"
        case .landings: return "Landings"
        case .issues: return "Issues"
        case .tickets: return "Tickets"
        case .jjhubWorkflows: return "Workflows"
        }
    }
}

struct VCSDashboardView: View {
    @ObservedObject var smithers: SmithersClient
    var onNavigate: ((NavDestination) -> Void)? = nil

    @State private var tab: VCSDashboardTab = .overview
    @State private var changes: [JJHubChange] = []
    @State private var landings: [Landing] = []
    @State private var issues: [SmithersIssue] = []
    @State private var tickets: [Ticket] = []
    @State private var jjhubWorkflows: [JJHubWorkflow] = []
    @State private var repoName: String?
    @State private var hasJJHubTransport = UITestSupport.isEnabled
    @State private var isLoading = true
    @State private var error: String?
    @State private var sourceErrors: [VCSDataSource: String] = [:]
    @State private var loadGeneration = 0

    enum VCSDashboardTab: String, CaseIterable {
        case overview = "Overview"
        case changes = "Changes"
        case landings = "Landings"
        case issues = "Issues"
        case tickets = "Tickets"
        case workflows = "Workflows"
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

    private var workingCopyChanges: [JJHubChange] {
        changes.filter { $0.isWorkingCopy == true }
    }

    private var committedChanges: [JJHubChange] {
        changes.filter { $0.isWorkingCopy != true }
    }

    private var activeWorkflows: [JJHubWorkflow] {
        jjhubWorkflows.filter { $0.isActive }
    }

    private var visibleTabs: [VCSDashboardTab] {
        if hasJJHubTransport {
            return VCSDashboardTab.allCases
        }
        return [.overview, .changes, .tickets]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                ForEach(visibleTabs, id: \.self) { t in
                    DashboardTabButton(label: t.rawValue, isActive: tab == t) {
                        withAnimation(.easeInOut(duration: 0.2)) { tab = t }
                    }
                    .accessibilityIdentifier("vcsDashboard.tab.\(t.rawValue)")
                }
                Spacer()
            }
            .border(Theme.border, edges: [.bottom])

            if let error {
                errorView(error)
            } else {
                Group {
                    switch tab {
                    case .overview:
                        overviewContent
                    case .changes:
                        changesContent
                    case .landings:
                        landingsContent
                    case .issues:
                        issuesContent
                    case .tickets:
                        ticketsContent
                    case .workflows:
                        workflowsContent
                    }
                }
                .transition(.opacity)
                .id(tab)
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("vcsDashboard.root")
        .task { await loadAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("VCS Dashboard")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    if let repo = repoName, !repo.isEmpty {
                        Text(repo)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                            .accessibilityIdentifier("vcsDashboard.repoName")
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if openLandingsCount > 0 {
                    HeaderIndicator(
                        text: "\(openLandingsCount) open landing\(openLandingsCount == 1 ? "" : "s")",
                        color: Theme.accent
                    )
                    .accessibilityIdentifier("vcsDashboard.indicator.openLandings")
                }
                if openIssuesCount > 0 {
                    HeaderIndicator(
                        text: "\(openIssuesCount) open issue\(openIssuesCount == 1 ? "" : "s")",
                        color: Theme.success
                    )
                    .accessibilityIdentifier("vcsDashboard.indicator.openIssues")
                }
            }

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
    }

    // MARK: - Overview Tab

    private var overviewContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !sourceErrors.isEmpty {
                    partialLoadErrorBanner
                }

                HStack(spacing: 12) {
                    StatCard(
                        title: "Changes",
                        value: statValue(.changes, changes.count),
                        icon: statIcon(.changes, fallback: "point.3.connected.trianglepath.dotted"),
                        color: statColor(.changes, fallback: Theme.accent)
                    )
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
                        title: "Tickets",
                        value: statValue(.tickets, tickets.count),
                        icon: statIcon(.tickets, fallback: "ticket"),
                        color: statColor(.tickets, fallback: Theme.warning)
                    )
                }

                if !committedChanges.isEmpty {
                    SectionCard(title: "Recent Changes") {
                        ForEach(committedChanges.prefix(5)) { change in
                            VCSChangeRow(change: change)
                            if change.id != committedChanges.prefix(5).last?.id {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }

                if !landings.isEmpty {
                    SectionCard(title: "Recent Landings") {
                        ForEach(landings.prefix(5)) { landing in
                            LandingSummaryRow(landing: landing)
                            if landing.id != landings.prefix(5).last?.id {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }

                if !issues.isEmpty {
                    SectionCard(title: "Open Issues") {
                        let openIssues = issues.filter { ($0.state ?? "").lowercased() == "open" }
                        ForEach(openIssues.prefix(5)) { issue in
                            IssueSummaryRow(issue: issue)
                            if issue.id != openIssues.prefix(5).last?.id {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }

                if hasJJHubTransport {
                    SectionCard(title: "VCS At A Glance") {
                        DashboardMetricRow(
                            icon: "point.3.connected.trianglepath.dotted",
                            title: "Changes",
                            detail: sourceDetail(.changes, "\(changes.count) total · \(workingCopyChanges.count) working copy")
                        )
                        Divider().background(Theme.border)
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
                            icon: "point.3.filled.connected.trianglepath.dotted",
                            title: "JJHub Workflows",
                            detail: sourceDetail(.jjhubWorkflows, "\(jjhubWorkflows.count) total · \(activeWorkflows.count) active")
                        )
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    // MARK: - Changes Tab

    private var changesContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Changes view",
                    accessibilityID: "vcsDashboard.route.changes"
                ) {
                    onNavigate?(.changes)
                }

                if sourceErrors[.changes] != nil && changes.isEmpty && !isLoading {
                    emptySection("Unable to load changes", icon: "exclamationmark.triangle")
                } else if changes.isEmpty && !isLoading {
                    emptySection("No changes found", icon: "point.3.connected.trianglepath.dotted")
                } else {
                    ForEach(changes) { change in
                        VCSChangeRow(change: change)
                        if change.id != changes.last?.id {
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadAll() }
    }

    // MARK: - Landings Tab

    private var landingsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Landings view",
                    accessibilityID: "vcsDashboard.route.landings"
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

    // MARK: - Issues Tab

    private var issuesContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Issues view",
                    accessibilityID: "vcsDashboard.route.issues"
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

    // MARK: - Tickets Tab

    private var ticketsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                tabRouteButton(
                    title: "Open full Tickets view",
                    accessibilityID: "vcsDashboard.route.tickets"
                ) {
                    onNavigate?(.tickets)
                }

                if sourceErrors[.tickets] != nil && tickets.isEmpty && !isLoading {
                    emptySection("Unable to load tickets", icon: "exclamationmark.triangle")
                } else if tickets.isEmpty && !isLoading {
                    emptySection("No tickets found", icon: "ticket")
                } else {
                    ForEach(tickets.prefix(20)) { ticket in
                        VCSTicketRow(ticket: ticket)
                        if ticket.id != tickets.prefix(20).last?.id {
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
                    title: "Open full JJHub Workflows view",
                    accessibilityID: "vcsDashboard.route.jjhubWorkflows"
                ) {
                    onNavigate?(.jjhubWorkflows)
                }

                if sourceErrors[.jjhubWorkflows] != nil && jjhubWorkflows.isEmpty && !isLoading {
                    emptySection("Unable to load workflows", icon: "exclamationmark.triangle")
                } else if jjhubWorkflows.isEmpty && !isLoading {
                    emptySection("No JJHub workflows found", icon: "point.3.filled.connected.trianglepath.dotted")
                } else {
                    ForEach(jjhubWorkflows) { workflow in
                        VCSWorkflowRow(workflow: workflow)
                        if workflow.id != jjhubWorkflows.last?.id {
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
        var nextSourceErrors: [VCSDataSource: String] = [:]

        // Always load changes and tickets (local smithers data)
        async let changesResult = loadChanges()
        async let ticketsResult = loadTickets()

        let (loadedChanges, loadedTickets) = await (changesResult, ticketsResult)
        guard generation == loadGeneration else { return }
        changes = loadedChanges.value
        tickets = loadedTickets.value
        recordSourceError(loadedChanges.error, source: .changes, into: &nextSourceErrors)
        recordSourceError(loadedTickets.error, source: .tickets, into: &nextSourceErrors)

        // Try JJHub transport
        do {
            let repo = try await smithers.getCurrentRepo()
            guard generation == loadGeneration else { return }
            repoName = repo.fullName ?? repo.name
            hasJJHubTransport = true

            async let landingsResult = loadLandings()
            async let issuesResult = loadIssues()
            async let workflowsResult = loadJJHubWorkflows()

            let (loadedLandings, loadedIssues, loadedWorkflows) = await (landingsResult, issuesResult, workflowsResult)
            guard generation == loadGeneration else { return }
            landings = loadedLandings.value
            issues = loadedIssues.value
            jjhubWorkflows = loadedWorkflows.value
            recordSourceError(loadedLandings.error, source: .landings, into: &nextSourceErrors)
            recordSourceError(loadedIssues.error, source: .issues, into: &nextSourceErrors)
            recordSourceError(loadedWorkflows.error, source: .jjhubWorkflows, into: &nextSourceErrors)
        } catch {
            guard generation == loadGeneration else { return }
            hasJJHubTransport = false
            repoName = nil
            landings = []
            issues = []
            jjhubWorkflows = []
        }

        sourceErrors = nextSourceErrors
        if !visibleTabs.contains(tab) {
            tab = .overview
        }
        isLoading = false
    }

    // MARK: - Helpers

    private var partialLoadErrorBanner: some View {
        let failedSources = VCSDataSource.allCases
            .filter { sourceErrors[$0] != nil }
            .map(\.label)
            .joined(separator: ", ")

        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(Theme.warning)
            Text("Unable to load: \(failedSources). Affected stats are unavailable.")
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

    private func statValue(_ source: VCSDataSource, _ value: Int) -> String {
        sourceErrors[source] == nil ? "\(value)" : "—"
    }

    private func statIcon(_ source: VCSDataSource, fallback: String) -> String {
        sourceErrors[source] == nil ? fallback : "exclamationmark.triangle.fill"
    }

    private func statColor(_ source: VCSDataSource, fallback: Color) -> Color {
        sourceErrors[source] == nil ? fallback : Theme.warning
    }

    private func sourceDetail(_ source: VCSDataSource, _ detail: String) -> String {
        sourceErrors[source] == nil ? detail : "Unavailable"
    }

    private func tabRouteButton(title: String, accessibilityID: String, action: @escaping () -> Void) -> some View {
        TabRouteButton(title: title, action: action)
            .accessibilityIdentifier(accessibilityID)
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

    // MARK: - Data Loaders

    private func loadChanges() async -> DashboardLoadResult<[JJHubChange]> {
        do {
            return DashboardLoadResult(value: try await smithers.listChanges(), error: nil)
        } catch {
            return DashboardLoadResult(value: [], error: error)
        }
    }

    private func loadTickets() async -> DashboardLoadResult<[Ticket]> {
        do {
            return DashboardLoadResult(value: try await smithers.listTickets(), error: nil)
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

    private func loadJJHubWorkflows() async -> DashboardLoadResult<[JJHubWorkflow]> {
        do {
            return DashboardLoadResult(value: try await smithers.listJJHubWorkflows(), error: nil)
        } catch {
            return DashboardLoadResult(value: [], error: error)
        }
    }

    private func recordSourceError(
        _ error: Error?,
        source: VCSDataSource,
        into sourceErrors: inout [VCSDataSource: String]
    ) {
        if let error {
            sourceErrors[source] = error.localizedDescription
        }
    }
}

// MARK: - VCS Summary Rows

struct VCSChangeRow: View {
    let change: JJHubChange

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: change.isWorkingCopy == true ? "pencil.circle.fill" : "circle.fill")
                .font(.system(size: 10))
                .foregroundColor(change.isWorkingCopy == true ? Theme.warning : Theme.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(change.description ?? change.changeID)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(String(change.changeID.prefix(12)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                    if let author = change.author {
                        Text(author.name ?? author.email ?? "")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                    if let bookmarks = change.bookmarks, !bookmarks.isEmpty {
                        Text(bookmarks.joined(separator: ", "))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.accent)
                    }
                }
            }

            Spacer()

            if change.isWorkingCopy == true {
                Text("WC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.warning.opacity(0.12))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 8)
        .themedRowHover()
    }
}

struct VCSTicketRow: View {
    let ticket: Ticket

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ticketIcon)
                .font(.system(size: 12))
                .foregroundColor(ticketColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(ticket.id)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if let content = ticket.content, !content.isEmpty {
                    Text(content)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let status = ticket.status {
                Text(status)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ticketColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ticketColor.opacity(0.12))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 8)
        .themedRowHover()
    }

    private var normalizedStatus: String {
        (ticket.status ?? "").lowercased()
    }

    private var ticketIcon: String {
        switch normalizedStatus {
        case "open", "active": return "ticket"
        case "closed", "done", "resolved": return "checkmark.circle.fill"
        default: return "ticket"
        }
    }

    private var ticketColor: Color {
        switch normalizedStatus {
        case "open", "active": return Theme.accent
        case "closed", "done", "resolved": return Theme.textTertiary
        default: return Theme.warning
        }
    }
}

struct VCSWorkflowRow: View {
    let workflow: JJHubWorkflow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workflow.isActive ? "bolt.circle.fill" : "bolt.circle")
                .font(.system(size: 12))
                .foregroundColor(workflow.isActive ? Theme.success : Theme.textTertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(workflow.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(workflow.isActive ? "Active" : "Inactive")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(workflow.isActive ? Theme.success : Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((workflow.isActive ? Theme.success : Theme.textTertiary).opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.vertical, 8)
        .themedRowHover()
    }
}
