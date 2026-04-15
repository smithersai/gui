import SwiftUI

struct ScoresView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var scores: [ScoreRow] = []
    @State private var aggregates: [AggregateScore] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var tab: ScoreTab = .summary

    enum ScoreTab: String, CaseIterable {
        case summary = "Summary"
        case recent = "Recent"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Scores")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                }
                Button(action: { Task { await loadScores() } }) {
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
                ForEach(ScoreTab.allCases, id: \.self) { t in
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
                            Rectangle().fill(Theme.accent).frame(height: 2)
                        }
                    }
                }
                Spacer()
            }
            .border(Theme.border, edges: [.bottom])

            if let error {
                errorView(error)
            } else {
                switch tab {
                case .summary: summaryContent
                case .recent: recentContent
                }
            }
        }
        .background(Theme.surface1)
        .task { await loadScores() }
    }

    // MARK: - Summary Tab

    private var summaryContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if aggregates.isEmpty && !isLoading {
                    emptyView("No scorer data")
                } else {
                    // Table header
                    HStack(spacing: 0) {
                        tableHeader("Scorer", width: 140)
                        tableHeader("Count", width: 60)
                        tableHeader("Mean", width: 60)
                        tableHeader("Min", width: 60)
                        tableHeader("Max", width: 60)
                        tableHeader("P50", width: 60)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.surface2)
                    .border(Theme.border, edges: [.bottom])

                    ForEach(aggregates) { agg in
                        HStack(spacing: 0) {
                            Text(agg.scorerName)
                                .frame(width: 140, alignment: .leading)
                            Text("\(agg.count)")
                                .frame(width: 60, alignment: .trailing)
                            scoreCell(agg.mean, width: 60)
                            scoreCell(agg.min, width: 60)
                            scoreCell(agg.max, width: 60)
                            if let p50 = agg.p50 {
                                scoreCell(p50, width: 60)
                            } else {
                                Text("—")
                                    .frame(width: 60, alignment: .trailing)
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer()
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(20)
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
                                Text(score.scorerName ?? score.scorerId ?? "Unknown")
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
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private func tableHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Theme.textTertiary)
            .frame(width: width, alignment: title == "Scorer" ? .leading : .trailing)
    }

    private func scoreCell(_ value: Double, width: CGFloat) -> some View {
        Text(String(format: "%.2f", value))
            .foregroundColor(scoreColor(value))
            .frame(width: width, alignment: .trailing)
    }

    private func scoreIndicator(_ value: Double) -> some View {
        Circle()
            .fill(scoreColor(value))
            .frame(width: 8, height: 8)
    }

    private func scoreColor(_ value: Double) -> Color {
        if value >= 0.8 { return Theme.success }
        if value >= 0.5 { return Theme.warning }
        return Theme.danger
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt
    }()

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
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
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadScores() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadScores() async {
        isLoading = true
        error = nil
        do {
            let recentScores = try await smithers.listRecentScores()
            scores = recentScores
            aggregates = try await smithers.aggregateScores(from: recentScores)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
