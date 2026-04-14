import SwiftUI

struct LandingsView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var landings: [Landing] = []
    @State private var selectedId: String?
    @State private var diffText: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var stateFilter: String?
    @State private var detailTab: DetailTab = .info

    enum DetailTab: String, CaseIterable {
        case info = "Info"
        case diff = "Diff"
    }

    private var selectedLanding: Landing? {
        landings.first { $0.id == selectedId }
    }

    private var filteredLandings: [Landing] {
        if let f = stateFilter {
            return landings.filter { $0.state == f }
        }
        return landings
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Landings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()

                Menu {
                    Button("All") { stateFilter = nil }
                    Button("Draft") { stateFilter = "draft" }
                    Button("Ready") { stateFilter = "ready" }
                    Button("Landed") { stateFilter = "landed" }
                } label: {
                    HStack(spacing: 4) {
                        Text(stateFilter?.capitalized ?? "All")
                            .font(.system(size: 11))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                if isLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                }
                Button(action: { Task { await loadLandings() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .border(Theme.border, edges: [.bottom])

            if let error {
                errorView(error)
            } else {
                HSplitView {
                    landingList
                        .frame(minWidth: 260)
                    detailPane
                        .frame(minWidth: 350)
                }
            }
        }
        .background(Theme.surface1)
        .task { await loadLandings() }
    }

    // MARK: - List

    private var landingList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if filteredLandings.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No landings found")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(filteredLandings) { landing in
                        Button(action: { selectLanding(landing) }) {
                            HStack(spacing: 10) {
                                landingStateIcon(landing.state)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(landing.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        if let num = landing.number {
                                            Text("#\(num)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(Theme.textTertiary)
                                        }
                                        if let review = landing.reviewStatus {
                                            Text(review)
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundColor(reviewColor(review))
                                        }
                                    }
                                }

                                Spacer()

                                if let state = landing.state {
                                    Text(state.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(landingStateColor(state))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(landingStateColor(state).opacity(0.15))
                                        .cornerRadius(4)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(selectedId == landing.id ? Theme.sidebarSelected : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .background(Theme.surface2)
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let landing = selectedLanding {
                VStack(spacing: 0) {
                    // Tabs
                    HStack(spacing: 0) {
                        ForEach(DetailTab.allCases, id: \.self) { t in
                            Button(action: { detailTab = t }) {
                                Text(t.rawValue)
                                    .font(.system(size: 12, weight: detailTab == t ? .semibold : .regular))
                                    .foregroundColor(detailTab == t ? Theme.accent : Theme.textSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                if detailTab == t {
                                    Rectangle().fill(Theme.accent).frame(height: 2)
                                }
                            }
                        }
                        Spacer()

                        // Actions
                        if landing.state != "landed" {
                            Button(action: { Task { await approveLanding(landing) } }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark")
                                    Text("Approve")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.success)
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(Theme.success.opacity(0.12))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)

                            Button(action: { Task { await landLanding(landing) } }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.to.line")
                                    Text("Land")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.accent)
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(Theme.accent.opacity(0.12))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 12)
                        }
                    }
                    .border(Theme.border, edges: [.bottom])

                    switch detailTab {
                    case .info:
                        landingInfo(landing)
                    case .diff:
                        landingDiffView
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select a landing")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surface1)
    }

    private func landingInfo(_ landing: Landing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(landing.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                if let desc = landing.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }

                Divider().background(Theme.border)

                VStack(alignment: .leading, spacing: 6) {
                    if let num = landing.number { infoRow("Number", "#\(num)") }
                    if let state = landing.state { infoRow("State", state) }
                    if let branch = landing.targetBranch { infoRow("Target", branch) }
                    if let author = landing.author { infoRow("Author", author) }
                    if let review = landing.reviewStatus { infoRow("Review", review) }
                    if let created = landing.createdAt { infoRow("Created", created) }
                }
            }
            .padding(20)
        }
    }

    private var landingDiffView: some View {
        ScrollView {
            if let diff = diffText {
                Text(diff)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .background(Theme.base)
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private func landingStateIcon(_ state: String?) -> some View {
        let (icon, color): (String, Color) = {
            switch state {
            case "landed": return ("checkmark.circle.fill", Theme.success)
            case "ready": return ("circle.fill", Theme.accent)
            default: return ("circle.dashed", Theme.textTertiary)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundColor(color)
            .frame(width: 16)
    }

    private func landingStateColor(_ state: String) -> Color {
        switch state {
        case "landed": return Theme.success
        case "ready": return Theme.accent
        default: return Theme.textTertiary
        }
    }

    private func reviewColor(_ status: String) -> Color {
        switch status {
        case "approved": return Theme.success
        case "changes_requested": return Theme.danger
        default: return Theme.textTertiary
        }
    }

    private func selectLanding(_ landing: Landing) {
        selectedId = landing.id
        diffText = nil
        detailTab = .info
        if let num = landing.number {
            Task {
                do { diffText = try await smithers.landingDiff(number: num) } catch { diffText = "Failed to load diff" }
            }
        }
    }

    private func approveLanding(_ landing: Landing) async {
        guard let num = landing.number else { return }
        do {
            try await smithers.reviewLanding(number: num, action: "approve", body: nil)
            await loadLandings()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func landLanding(_ landing: Landing) async {
        guard let num = landing.number else { return }
        do {
            try await smithers.reviewLanding(number: num, action: "land", body: nil)
            await loadLandings()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadLandings() async {
        isLoading = true
        error = nil
        do {
            landings = try await smithers.listLandings(state: stateFilter)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadLandings() } }
                .buttonStyle(.plain).foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
