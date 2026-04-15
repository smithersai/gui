import SwiftUI

struct LandingsView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var landings: [Landing] = []
    @State private var selectedId: String?
    @State private var selectedNumber: Int?
    @State private var detailLanding: Landing?
    @State private var diffText: String?
    @State private var checksText: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var stateFilter: String?
    @State private var loadGeneration = 0
    @State private var detailTab: DetailTab = .info
    @State private var actionError: String?

    @State private var showCreate = false
    @State private var newTitle = ""
    @State private var newBody = ""
    @State private var newTarget = ""
    @State private var isCreating = false

    @State private var reviewAction: ReviewAction?
    @State private var reviewBody = ""
    @State private var isSubmittingReview = false

    enum DetailTab: String, CaseIterable {
        case info = "Info"
        case diff = "Diff"
        case checks = "Checks"
    }

    enum ReviewAction: String, CaseIterable, Identifiable {
        case approve = "approve"
        case requestChanges = "request_changes"
        case comment = "comment"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .approve:
                return "Approve landing"
            case .requestChanges:
                return "Request changes"
            case .comment:
                return "Comment on landing"
            }
        }

        var submitLabel: String {
            switch self {
            case .approve:
                return "Approve"
            case .requestChanges:
                return "Request Changes"
            case .comment:
                return "Comment"
            }
        }

        var placeholder: String {
            switch self {
            case .approve:
                return "Optional review body"
            case .requestChanges:
                return "Explain what still needs to change"
            case .comment:
                return "Optional comment"
            }
        }

        var requiresBody: Bool {
            self == .requestChanges
        }
    }

    private struct LandingDiffChunk: Identifiable {
        let id: String
        let title: String?
        let diff: String
    }

    private static func normalizedLandingState(_ state: String?) -> String {
        let value = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "", "all":
            return "all"
        case "open", "ready":
            return "open"
        case "merged", "landed":
            return "merged"
        case "draft", "closed":
            return value
        case "other":
            return "other"
        default:
            return "other"
        }
    }

    private static func landingStateRequestFilter(_ state: String?) -> String? {
        switch normalizedLandingState(state) {
        case "all", "other":
            return nil
        default:
            return state
        }
    }

    private static func landingDiffChunks(from diff: String) -> [LandingDiffChunk] {
        diff.components(separatedBy: "\n\n------------------------------------------------------------------------\n")
            .enumerated()
            .compactMap { index, rawChunk in
                let trimmed = rawChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                var lines = trimmed.components(separatedBy: "\n")
                let title: String?
                if let first = lines.first,
                   first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Change ") {
                    title = first.trimmingCharacters(in: .whitespacesAndNewlines)
                    lines.removeFirst()
                    while let firstLine = lines.first,
                          firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.removeFirst()
                    }
                } else {
                    title = nil
                }

                return LandingDiffChunk(
                    id: "\(index):\(title ?? String(trimmed.prefix(32)))",
                    title: title,
                    diff: lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                )
            }
    }

    private var selectedLanding: Landing? {
        if let selectedNumber {
            if let detailLanding, detailLanding.number == selectedNumber {
                return detailLanding
            }
            if let landing = landings.first(where: { $0.number == selectedNumber }) {
                return landing
            }
        }

        guard let selectedId else {
            return nil
        }

        if let detailLanding, detailLanding.id == selectedId {
            return detailLanding
        }
        return landings.first { $0.id == selectedId }
    }

    private var filteredLandings: [Landing] {
        let normalizedFilter = Self.normalizedLandingState(stateFilter)
        guard normalizedFilter != "all" else {
            return landings
        }
        return landings.filter { Self.normalizedLandingState($0.state) == normalizedFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorView(error)
            } else {
                content
            }
        }
        .background(Theme.surface1)
        .task(id: stateFilter) { await loadLandings() }
        .sheet(item: $reviewAction) { action in
            reviewSheet(action)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Landings")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()

            Menu {
                Button("All") { stateFilter = nil }
                Button("Open") { stateFilter = "open" }
                Button("Draft") { stateFilter = "draft" }
                Button("Merged") { stateFilter = "merged" }
                Button("Closed") { stateFilter = "closed" }
                Button("Other") { stateFilter = "other" }
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

            Button(action: { showCreate.toggle() }) {
                Image(systemName: showCreate ? "xmark" : "plus")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.accent)
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
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let actionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.warning)
                    Text(actionError)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button(action: { self.actionError = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.warning.opacity(0.1))
            }

            HStack(spacing: 0) {
                landingList
                    .frame(width: 300)
                Divider().background(Theme.border)
                detailPane
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - List

    private var landingList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showCreate {
                    createForm
                }

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
                            .background(isSelected(landing) ? Theme.sidebarSelected : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .refreshable { await loadLandings() }
        .background(Theme.surface2)
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW LANDING")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)

            TextField("Title", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            TextEditor(text: $newBody)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 64)
                .padding(6)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            TextField("Target bookmark (optional)", text: $newTarget)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            HStack(spacing: 8) {
                Button(action: { Task { await createLanding() } }) {
                    HStack {
                        if isCreating {
                            ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                        }
                        Text("Create")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)

                Button("Cancel") {
                    showCreate = false
                    newTitle = ""
                    newBody = ""
                    newTarget = ""
                }
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Theme.base.opacity(0.5))
        .border(Theme.border, edges: [.bottom])
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let landing = selectedLanding {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(DetailTab.allCases, id: \.self) { tab in
                            Button(action: { selectDetailTab(tab, landing: landing) }) {
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: detailTab == tab ? .semibold : .regular))
                                    .foregroundColor(detailTab == tab ? Theme.accent : Theme.textSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                if detailTab == tab {
                                    Rectangle().fill(Theme.accent).frame(height: 2)
                                }
                            }
                        }
                        Spacer()

                        if !isTerminalLandingState(landing.state) {
                            Menu {
                                Button("Approve") { beginReview(.approve) }
                                Button("Request Changes") { beginReview(.requestChanges) }
                                Button("Comment") { beginReview(.comment) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "text.bubble")
                                    Text("Review")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.success)
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(Theme.success.opacity(0.12))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)

                            if canLandLanding(landing) {
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
                            }

                            Spacer().frame(width: 12)
                        }
                    }
                    .border(Theme.border, edges: [.bottom])

                    switch detailTab {
                    case .info:
                        landingInfo(landing)
                    case .diff:
                        landingDiffView
                    case .checks:
                        landingChecksView
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

                if let description = landing.description,
                   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }

                Divider().background(Theme.border)

                VStack(alignment: .leading, spacing: 6) {
                    if let number = landing.number { infoRow("Number", "#\(number)") }
                    if let state = landing.state { infoRow("State", state) }
                    if let branch = landing.targetBranch { infoRow("Target", branch) }
                    if let author = landing.author { infoRow("Author", author) }
                    if let review = landing.reviewStatus { infoRow("Review", review) }
                    if let created = landing.createdAt { infoRow("Created", formattedDate(created)) }
                }
            }
            .padding(20)
        }
    }

    private var landingDiffView: some View {
        ScrollView {
            if let diff = diffText {
                if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No diff available")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    Text(diff)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .background(Theme.base)
    }

    private var landingChecksView: some View {
        ScrollView {
            if let checks = checksText {
                if checks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No checks available")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    Text(checks)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .background(Theme.base)
    }

    private func reviewSheet(_ action: ReviewAction) -> some View {
        let trimmedBody = reviewBody.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 12) {
            Text(action.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            TextEditor(text: $reviewBody)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(8)
                .background(Theme.inputBg)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            Text(action.placeholder)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)

            if action.requiresBody {
                Text("A review body is required when requesting changes.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.warning)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    reviewAction = nil
                    reviewBody = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)

                Button(action: { Task { await submitReview(action) } }) {
                    HStack(spacing: 6) {
                        if isSubmittingReview {
                            ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                        }
                        Text(action.submitLabel)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isSubmittingReview || (action.requiresBody && trimmedBody.isEmpty))
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 280)
        .background(Theme.surface1)
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
        let normalizedState = Self.normalizedLandingState(state)
        let (icon, color): (String, Color) = {
            switch normalizedState {
            case "merged":
                return ("checkmark.circle.fill", Theme.success)
            case "closed":
                return ("xmark.circle.fill", Theme.textTertiary)
            case "open":
                return ("circle.fill", Theme.accent)
            case "draft":
                return ("circle.dashed", Theme.info)
            default:
                return ("circle.dashed", Theme.textTertiary)
            }
        }()

        return Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundColor(color)
            .frame(width: 16)
    }

    private func landingStateColor(_ state: String) -> Color {
        switch Self.normalizedLandingState(state) {
        case "merged":
            return Theme.success
        case "open":
            return Theme.accent
        case "draft":
            return Theme.info
        case "closed":
            return Theme.textTertiary
        default:
            return Theme.textTertiary
        }
    }

    private func formattedDate(_ iso: String) -> String {
        if let date = DateFormatters.parseISO8601InternetDateTime(iso) {
            return DateFormatters.localizedMediumDateShortTime.string(from: date)
        }
        return iso
    }

    private func reviewColor(_ status: String) -> Color {
        switch status {
        case "approved":
            return Theme.success
        case "changes_requested":
            return Theme.danger
        default:
            return Theme.textTertiary
        }
    }

    private func isTerminalLandingState(_ state: String?) -> Bool {
        let normalizedState = Self.normalizedLandingState(state)
        return normalizedState == "merged" || normalizedState == "closed"
    }

    private func canLandLanding(_ landing: Landing) -> Bool {
        Self.normalizedLandingState(landing.state) == "open"
    }

    private func isSelected(_ landing: Landing) -> Bool {
        if let selectedNumber, let number = landing.number {
            return selectedNumber == number
        }
        return selectedId == landing.id
    }

    private func beginReview(_ action: ReviewAction) {
        reviewBody = ""
        reviewAction = action
    }

    private func selectDetailTab(_ tab: DetailTab, landing: Landing) {
        detailTab = tab
        switch tab {
        case .diff:
            if diffText == nil, let number = landing.number {
                Task { await loadLandingDiff(number: number) }
            } else if landing.number == nil {
                diffText = "No diff available"
            }
        case .checks:
            guard let number = landing.number else {
                checksText = "No checks available"
                return
            }
            if checksText == nil {
                Task { await loadLandingChecks(number: number) }
            }
        case .info:
            break
        }
    }

    private func selectLanding(_ landing: Landing) {
        selectedId = landing.id
        selectedNumber = landing.number
        detailLanding = landing
        diffText = nil
        checksText = nil
        detailTab = .info

        guard let number = landing.number else {
            diffText = "No diff available"
            checksText = "No checks available"
            return
        }

        Task {
            await loadLandingDetailAndDiff(number: number)
        }
    }

    private func loadLandingDetailAndDiff(number: Int) async {
        do {
            let detail = try await smithers.getLanding(number: number)
            guard selectedNumber == number else { return }
            detailLanding = detail
        } catch {
            guard selectedNumber == number else { return }
            actionError = error.localizedDescription
        }

        await loadLandingDiff(number: number)
    }

    private func loadLandingDiff(number: Int) async {
        do {
            let diff = try await smithers.landingDiff(number: number)
            guard selectedNumber == number else { return }
            diffText = diff
        } catch {
            guard selectedNumber == number else { return }
            diffText = "Failed to load diff"
        }
    }

    private func loadLandingChecks(number: Int) async {
        do {
            let checks = try await smithers.landingChecks(number: number)
            guard selectedNumber == number else { return }
            checksText = checks
        } catch {
            guard selectedNumber == number else { return }
            checksText = "Failed to load checks"
        }
    }

    private func submitReview(_ action: ReviewAction) async {
        guard let number = selectedNumber else { return }
        let trimmedBody = reviewBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if action.requiresBody && trimmedBody.isEmpty {
            actionError = "A review body is required when requesting changes"
            return
        }

        isSubmittingReview = true
        defer { isSubmittingReview = false }

        do {
            try await smithers.reviewLanding(
                number: number,
                action: action.rawValue,
                body: trimmedBody.isEmpty ? nil : trimmedBody
            )
            reviewAction = nil
            reviewBody = ""
            await reloadAfterLandingMutation(selectNumber: number)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func landLanding(_ landing: Landing) async {
        guard let number = landing.number else { return }

        do {
            try await smithers.landLanding(number: number)
            await reloadAfterLandingMutation(selectNumber: number)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func createLanding() async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            actionError = "Landing title is required"
            return
        }

        isCreating = true
        defer { isCreating = false }

        do {
            let created = try await smithers.createLanding(
                title: title,
                body: newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newBody,
                target: newTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newTarget,
                stack: true
            )

            showCreate = false
            newTitle = ""
            newBody = ""
            newTarget = ""

            if stateFilter != "open" {
                stateFilter = "open"
            }

            await loadLandings()

            if let number = created.number,
               let landing = landings.first(where: { $0.number == number }) {
                selectLanding(landing)
            } else if let landing = landings.first(where: { $0.id == created.id }) {
                selectLanding(landing)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func reloadAfterLandingMutation(selectNumber: Int?) async {
        await loadLandings()

        guard let selectNumber,
              let landing = landings.first(where: { $0.number == selectNumber }) else {
            return
        }

        selectedId = landing.id
        selectedNumber = landing.number
        detailLanding = landing
        diffText = nil
        checksText = nil

        Task {
            await loadLandingDetailAndDiff(number: selectNumber)
            if detailTab == .checks {
                await loadLandingChecks(number: selectNumber)
            }
        }
    }

    private func loadLandings() async {
        loadGeneration += 1
        let generation = loadGeneration
        let capturedNumber = selectedNumber
        isLoading = true
        error = nil

        do {
            let loaded = try await smithers.listLandings(state: stateFilter)
            guard generation == loadGeneration else { return }
            _ = capturedNumber // Acknowledge the capture; selection guard is done via generation.
            landings = loaded
            synchronizeSelection(with: loaded)
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func synchronizeSelection(with loaded: [Landing]) {
        if let selectedNumber,
           let refreshed = loaded.first(where: { $0.number == selectedNumber }) {
            selectedId = refreshed.id
            if detailLanding?.number != selectedNumber {
                detailLanding = refreshed
            }
            return
        }

        if let selectedId,
           let refreshed = loaded.first(where: { $0.id == selectedId }) {
            selectedNumber = refreshed.number
            if detailLanding?.id != selectedId {
                detailLanding = refreshed
            }
            return
        }

        selectedId = nil
        selectedNumber = nil
        detailLanding = nil
        diffText = nil
        checksText = nil
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadLandings() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
