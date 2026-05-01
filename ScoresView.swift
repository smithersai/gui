import SwiftUI

struct ScoresView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var runs: [RunSummary] = []
    @State private var selectedRunId: String?
    @State private var scores: [ScoreRow] = []
    @State private var aggregates: [AggregateScore] = []
    @State private var tokenMetrics: TokenMetrics?
    @State private var latencyMetrics: LatencyMetrics?
    @State private var costReport: CostReport?
    @State private var isLoading = true
    @State private var metricsLoading = false
    @State private var error: String?
    @State private var metricsError: String?
    @State private var tab: ScoreTab = .summary
    @State private var loadGeneration = 0
    @State private var metricsGeneration = 0

    init(smithers: SmithersClient, initialRunId: String? = nil) {
        self.smithers = smithers
        _selectedRunId = State(initialValue: initialRunId)
    }

    enum ScoreTab: String, CaseIterable {
        case summary = "Summary"
        case metrics = "Metrics"
        case recent = "Recent"
    }

    static func normalizedRunId(_ runId: String?) -> String? {
        guard let runId = runId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runId.isEmpty else {
            return nil
        }
        return runId
    }

    static func resolveActiveRunId(selectedRunId: String?, runs: [RunSummary]) -> String? {
        if let selectedRunId = normalizedRunId(selectedRunId),
           runs.contains(where: { $0.runId == selectedRunId }) {
            return selectedRunId
        }
        return runs.first?.runId
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Scores")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                runSelector
                if isLoading || metricsLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                }
                Button(action: { Task { await loadRunContextAndScores() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("scores.refreshButton")
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .border(Theme.border, edges: [.bottom])

            // Tabs
            HStack(spacing: 0) {
                ForEach(ScoreTab.allCases, id: \.self) { t in
                    DashboardTabButton(label: t.rawValue, isActive: tab == t) {
                        withAnimation(.easeInOut(duration: 0.2)) { tab = t }
                    }
                    .accessibilityIdentifier("scores.tab.\(t.rawValue.lowercased())")
                }
                Spacer()
            }
            .border(Theme.border, edges: [.bottom])

            if let error {
                errorView(error)
            } else if selectedRunId == nil && !isLoading {
                emptyView("No runs available")
            } else {
                Group {
                    switch tab {
                    case .summary: summaryContent
                    case .metrics: metricsContent
                    case .recent: recentContent
                    }
                }
                .transition(.opacity)
                .id(tab)
            }
        }
        .background(Theme.surface1)
        .task { await loadRunContextAndScores() }
        .refreshable { await loadRunContextAndScores() }
    }

    // MARK: - Summary Tab

    private var summaryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryMetricsPanel

                VStack(alignment: .leading, spacing: 10) {
                    if aggregates.isEmpty && !isLoading {
                        emptyView("No scorer data")
                    } else {
                        Text("Per-scorer statistics")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textTertiary)
                        ForEach(aggregates) { agg in
                            scorerAggregateCard(agg)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var summaryMetricsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summaryTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
                summaryMetricTile(title: "Evaluations", value: "\(scores.count)")
                summaryMetricTile(title: "Mean score", value: String(format: "%.2f", meanScore))
                summaryMetricTile(title: "Tokens", value: summaryTokenValue)
                summaryMetricTile(title: "Avg duration", value: summaryDurationValue)
                summaryMetricTile(title: "Cache hit rate", value: summaryCacheHitRate)
                summaryMetricTile(title: "Est. cost", value: summaryCostValue)
            }

            if metricsLoading {
                Text("Loading token, latency, and cost metrics…")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            } else if let metricsError {
                Text("Metrics unavailable: \(metricsError)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.warning)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func summaryMetricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func scorerAggregateCard(_ aggregate: AggregateScore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(aggregate.scorerName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(aggregate.count) eval\(aggregate.count == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }

            HStack(spacing: 10) {
                aggregateMetricCell(label: "Mean", value: aggregate.mean)
                aggregateMetricCell(label: "Min", value: aggregate.min)
                aggregateMetricCell(label: "Max", value: aggregate.max)
                aggregateMetricCell(label: "P50", value: aggregate.p50)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .themedCardHover(cornerRadius: 8)
    }

    private func aggregateMetricCell(label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
            if let value {
                Text(String(format: "%.2f", value))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(scoreColor(value))
            } else {
                Text("—")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Metrics Tab

    private var metricsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if metricsLoading {
                    Text("Loading metrics…")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                if let metricsError {
                    Text("Error loading metrics: \(metricsError)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.warning)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface2)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                }

                metricsTokenSection
                metricsLatencySection
                metricsCostSection
                metricsSummarySection
            }
            .padding(20)
        }
    }

    private var metricsTokenSection: some View {
        metricsSection(title: "Token Usage") {
            if let tokenMetrics {
                detailRow(label: "Total", value: formatTokenCount(tokenMetrics.totalTokens))
                detailRow(label: "Input", value: formatTokenCount(tokenMetrics.totalInputTokens))
                detailRow(label: "Output", value: formatTokenCount(tokenMetrics.totalOutputTokens))
                if tokenMetrics.cacheReadTokens > 0 || tokenMetrics.cacheWriteTokens > 0 {
                    detailRow(label: "Cache read", value: formatTokenCount(tokenMetrics.cacheReadTokens))
                    detailRow(label: "Cache write", value: formatTokenCount(tokenMetrics.cacheWriteTokens))
                    if let hitRate = tokenMetrics.cacheHitRate {
                        detailRow(label: "Cache hit %", value: String(format: "%.1f%%", hitRate * 100))
                    }
                }

                if !tokenMetrics.byPeriod.isEmpty {
                    Divider().background(Theme.border)
                        .padding(.vertical, 6)
                    tokenByPeriodTable(tokenMetrics.byPeriod)
                }
            } else {
                emptyDetailText("No token data available.")
            }
        }
    }

    private var metricsLatencySection: some View {
        metricsSection(title: "Latency") {
            if let latencyMetrics, latencyMetrics.count > 0 {
                detailRow(label: "Count", value: "\(latencyMetrics.count) nodes")
                detailRow(label: "Mean", value: formatDurationMs(latencyMetrics.meanMs))
                detailRow(label: "Min", value: formatDurationMs(latencyMetrics.minMs))
                detailRow(label: "P50", value: formatDurationMs(latencyMetrics.p50Ms))
                detailRow(label: "P95", value: formatDurationMs(latencyMetrics.p95Ms))
                detailRow(label: "Max", value: formatDurationMs(latencyMetrics.maxMs))
            } else {
                emptyDetailText("No latency data available.")
            }
        }
    }

    private var metricsCostSection: some View {
        metricsSection(title: "Cost Tracking") {
            if let costReport {
                detailRow(label: "Total", value: String(format: "$%.6f USD", costReport.totalCostUSD))
                detailRow(label: "Input", value: String(format: "$%.6f USD", costReport.inputCostUSD))
                detailRow(label: "Output", value: String(format: "$%.6f USD", costReport.outputCostUSD))
                if costReport.runCount > 0 {
                    detailRow(label: "Runs", value: "\(costReport.runCount)")
                    detailRow(label: "Per run", value: String(format: "$%.6f USD", costReport.totalCostUSD / Double(costReport.runCount)))
                }

                if !costReport.byPeriod.isEmpty {
                    Divider().background(Theme.border)
                        .padding(.vertical, 6)
                    costByPeriodTable(costReport.byPeriod)
                }
            } else {
                emptyDetailText("No cost data available.")
            }
        }
    }

    private var metricsSummarySection: some View {
        metricsSection(title: "Summaries") {
            if let summary = periodCostSummary {
                detailRow(label: "Daily cost (today)", value: String(format: "$%.6f USD", summary.dailyCost))
                detailRow(label: "Weekly cost (7d)", value: String(format: "$%.6f USD (%d runs)", summary.weeklyCost, summary.weeklyRuns))
            } else if let costReport {
                detailRow(label: "Aggregate total", value: String(format: "$%.6f USD (%d runs)", costReport.totalCostUSD, costReport.runCount))
                emptyDetailText("Per-period breakdown not available.")
            } else {
                emptyDetailText("No summary data available.")
            }
        }
    }

    private func metricsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private func emptyDetailText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundColor(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokenByPeriodTable(_ periods: [TokenPeriodBatch]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Period")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Input")
                    .frame(width: 90, alignment: .trailing)
                Text("Output")
                    .frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Theme.textTertiary)
            .padding(.bottom, 4)

            ForEach(Array(periods.enumerated()), id: \.offset) { _, period in
                HStack {
                    Text(truncate(period.label, limit: 30))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(formatTokenCount(period.inputTokens))
                        .frame(width: 90, alignment: .trailing)
                    Text(formatTokenCount(period.outputTokens))
                        .frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .padding(.vertical, 2)
            }
        }
    }

    private func costByPeriodTable(_ periods: [CostPeriodBatch]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Period")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Total")
                    .frame(width: 120, alignment: .trailing)
                Text("Runs")
                    .frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Theme.textTertiary)
            .padding(.bottom, 4)

            ForEach(Array(periods.enumerated()), id: \.offset) { _, period in
                HStack {
                    Text(truncate(period.label, limit: 20))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "$%.6f", period.totalCostUSD))
                        .frame(width: 120, alignment: .trailing)
                    Text("\(period.runCount)")
                        .frame(width: 60, alignment: .trailing)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Recent Tab

    private var recentContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if scores.isEmpty && !isLoading {
                    emptyView("No recent evaluations")
                } else {
                    ForEach(scores) { score in
                        HStack(spacing: 12) {
                            scoreIndicator(score.score)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(score.scorerDisplayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                if let reason = score.reason {
                                    Text(reason)
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.2f", score.score))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(scoreColor(score.score))
                                Text(formatDate(score.scoredAt))
                                    .font(.system(size: 9))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .themedRowHover()
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private var selectedRun: RunSummary? {
        guard let selectedRunId else { return nil }
        return runs.first { $0.runId == selectedRunId }
    }

    private var selectedRunLabel: String {
        if let selectedRun {
            return runDisplayName(selectedRun)
        }
        if let selectedRunId, !selectedRunId.isEmpty {
            return "Run \(shortRunId(selectedRunId))"
        }
        return runs.isEmpty ? "No runs" : "Select run"
    }

    private var summaryTitle: String {
        selectedRunId == nil ? "Summary" : "Run Summary"
    }

    private var meanScore: Double {
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0) { $0 + $1.score } / Double(scores.count)
    }

    private var summaryTokenValue: String {
        guard let tokenMetrics else { return "—" }
        return formatTokenCount(tokenMetrics.totalTokens)
    }

    private var summaryDurationValue: String {
        guard let latencyMetrics, latencyMetrics.count > 0 else { return "—" }
        return formatDurationMs(latencyMetrics.meanMs)
    }

    private var periodCostSummary: (dailyCost: Double, weeklyCost: Double, weeklyRuns: Int)? {
        guard let costReport, !costReport.byPeriod.isEmpty else { return nil }

        let todayLabel = DateFormatters.yearMonthDay.string(from: Date())
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        var dailyCost = 0.0
        var weeklyCost = 0.0
        var weeklyRuns = 0

        for period in costReport.byPeriod {
            if period.label == todayLabel {
                dailyCost += period.totalCostUSD
            }
            if let periodDate = DateFormatters.yearMonthDay.date(from: period.label), periodDate >= weekAgo {
                weeklyCost += period.totalCostUSD
                weeklyRuns += period.runCount
            }
        }
        return (dailyCost: dailyCost, weeklyCost: weeklyCost, weeklyRuns: weeklyRuns)
    }

    private var summaryCacheHitRate: String {
        guard let tokenMetrics, let hitRate = tokenMetrics.cacheHitRate else { return "—" }
        return String(format: "%.1f%%", hitRate * 100)
    }

    private var summaryCostValue: String {
        guard let costReport else { return "—" }
        return String(format: "$%.4f", costReport.totalCostUSD)
    }

    private var runSelector: some View {
        Menu {
            if runs.isEmpty {
                Button("No runs available") {}
                    .disabled(true)
            } else {
                ForEach(runs) { run in
                    Button(action: { Task { await selectRun(run.runId) } }) {
                        HStack {
                            Text(runMenuTitle(run))
                            if selectedRunId == run.runId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedRunLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .font(.system(size: 11))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: 220, minHeight: 28)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(runs.isEmpty && selectedRunId == nil)
        .accessibilityIdentifier("scores.runPicker")
    }

    private func shortRunId(_ runId: String) -> String {
        String(runId.prefix(8))
    }

    private func runDisplayName(_ run: RunSummary) -> String {
        if let name = run.workflowName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Run \(shortRunId(run.runId))"
    }

    private func runMenuTitle(_ run: RunSummary) -> String {
        "\(runDisplayName(run)) - \(run.status.label) - \(shortRunId(run.runId))"
    }

    private func scoreIndicator(_ value: Double) -> some View {
        Circle()
            .fill(scoreColor(value))
            .frame(width: 8, height: 8)
    }

    private func scoreColor(_ value: Double) -> Color {
        ScoreColorScale.color(for: value)
    }

    private func formatDate(_ date: Date) -> String {
        DateFormatters.localizedShortDateShortTime.string(from: date)
    }

    private func formatTokenCount(_ value: Int64) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.2fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    private func formatDurationMs(_ ms: Double) -> String {
        switch ms {
        case 60_000...:
            return String(format: "%.1fm", ms / 60_000)
        case 1_000...:
            return String(format: "%.2fs", ms / 1_000)
        default:
            return String(format: "%.0fms", ms)
        }
    }

    private func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit, limit > 3 else { return value }
        return String(value.prefix(limit - 3)) + "..."
    }

    private func emptyView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .font(.system(size: 24))
                .foregroundColor(Theme.textTertiary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityIdentifier("scores.emptyState")
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadRunContextAndScores() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("scores.retryButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadRunContextAndScores() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        var metricsRunId = Self.normalizedRunId(selectedRunId)
        do {
            let loadedRuns = try await smithers.listRuns()
            guard generation == loadGeneration else { return }
            runs = loadedRuns

            let runId = selectedRunId(afterLoading: loadedRuns)
            selectedRunId = runId
            metricsRunId = runId
            if let runId {
                let recentScores = try await smithers.listRecentScores(runId: runId)
                guard generation == loadGeneration else { return }
                scores = recentScores
                aggregates = try await smithers.aggregateScores(from: recentScores)
            } else {
                scores = []
                aggregates = []
            }
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
            scores = []
            aggregates = []
        }
        isLoading = false

        await loadMetrics(for: metricsRunId)
    }

    private func loadMetrics(for runId: String?) async {
        metricsGeneration += 1
        let generation = metricsGeneration
        let filters = metricsFilter(for: runId)
        metricsLoading = true
        metricsError = nil
        tokenMetrics = nil
        latencyMetrics = nil
        costReport = nil
        defer {
            if generation == metricsGeneration {
                metricsLoading = false
            }
        }

        do {
            async let tokenTask = smithers.getTokenUsageMetrics(filters: filters)
            async let latencyTask = smithers.getLatencyMetrics(filters: filters)
            async let costTask = smithers.getCostTracking(filters: filters)
            let (loadedTokenMetrics, loadedLatencyMetrics, loadedCostReport) = try await (tokenTask, latencyTask, costTask)
            guard generation == metricsGeneration else { return }
            tokenMetrics = loadedTokenMetrics
            latencyMetrics = loadedLatencyMetrics
            costReport = loadedCostReport
        } catch {
            guard generation == metricsGeneration else { return }
            metricsError = error.localizedDescription
        }
    }

    private func metricsFilter(for runId: String?) -> MetricsFilter {
        MetricsFilter(runId: Self.normalizedRunId(runId))
    }

    private func selectedRunId(afterLoading loadedRuns: [RunSummary]) -> String? {
        Self.resolveActiveRunId(selectedRunId: selectedRunId, runs: loadedRuns)
    }

    private func selectRun(_ runId: String) async {
        guard let runId = Self.normalizedRunId(runId) else { return }
        guard selectedRunId != runId else { return }
        selectedRunId = runId
        await loadScores(for: runId)
        guard selectedRunId == runId else { return }
        await loadMetrics(for: runId)
    }

    private func loadScores(for runId: String) async {
        guard let runId = Self.normalizedRunId(runId) else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        scores = []
        aggregates = []
        do {
            let recentScores = try await smithers.listRecentScores(runId: runId)
            guard generation == loadGeneration else { return }
            scores = recentScores
            aggregates = try await smithers.aggregateScores(from: recentScores)
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
