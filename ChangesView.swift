import SwiftUI

struct ChangesView: View {
    enum Mode: String, CaseIterable {
        case changes = "Changes"
        case status = "Status"
    }

    enum DetailTab: String, CaseIterable {
        case info = "Info"
        case diff = "Diff"
    }

    @ObservedObject var smithers: SmithersClient

    @State private var mode: Mode
    @State private var detailTab: DetailTab = .info

    @State private var repo: JJHubRepo?
    @State private var changes: [JJHubChange] = []
    @State private var selectedChangeID: String?

    @State private var detailCache: [String: JJHubChange] = [:]
    @State private var detailErrors: [String: String] = [:]
    @State private var detailLoading: Set<String> = []

    @State private var diffCache: [String: String] = [:]
    @State private var diffErrors: [String: String] = [:]
    @State private var diffLoading: Set<String> = []

    @State private var listLoading = true
    @State private var listError: String?

    @State private var statusLoading = false
    @State private var statusText = ""
    @State private var statusError: String?
    @State private var workingDiff = ""
    @State private var workingDiffError: String?

    @State private var actionMessage: String?
    @State private var actionError: String?
    @State private var bookmarkName = ""
    @State private var bookmarkToDelete = ""
    @State private var actionInFlight = false

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(smithers: SmithersClient, initialMode: Mode = .changes) {
        self.smithers = smithers
        _mode = State(initialValue: initialMode)
    }

    private var selectedChange: JJHubChange? {
        guard let selectedChangeID else { return nil }
        return changes.first { $0.changeID == selectedChangeID }
    }

    private var selectedDetail: JJHubChange? {
        guard let selectedChangeID else { return nil }
        return detailCache[selectedChangeID] ?? selectedChange
    }

    private var selectedBookmarks: [String] {
        selectedDetail?.bookmarks ?? []
    }

    private var isLoading: Bool {
        mode == .changes ? listLoading : statusLoading
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if mode == .changes {
                if let listError {
                    errorView(listError) { await refresh(for: .changes) }
                } else {
                    HStack(spacing: 0) {
                        changesList
                            .frame(width: 320)
                        Divider().background(Theme.border)
                        detailPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                statusPane
            }
        }
        .background(Theme.surface1)
        .task { await initialLoad() }
        .onChange(of: mode) { _, newMode in
            Task { await refresh(for: newMode) }
        }
        .onChange(of: selectedChangeID) { _, _ in
            syncDeleteBookmarkSelection()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                if let repoLabel = repoLabel {
                    Text(repoLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            Spacer()

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { currentMode in
                    Text(currentMode.rawValue).tag(currentMode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button(action: { Task { await refresh(for: mode) } }) {
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

    private var repoLabel: String? {
        if let fullName = repo?.fullName, !fullName.isEmpty {
            return fullName
        }
        if let name = repo?.name, !name.isEmpty {
            return name
        }
        return nil
    }

    // MARK: - Changes Mode

    private var changesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if changes.isEmpty && !listLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No recent changes found.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(changes) { change in
                        Button(action: { selectChange(change) }) {
                            HStack(spacing: 10) {
                                Image(systemName: selectedChangeID == change.id ? "arrowtriangle.right.fill" : "circle.fill")
                                    .font(.system(size: selectedChangeID == change.id ? 10 : 6))
                                    .foregroundColor(selectedChangeID == change.id ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 14)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(shortChangeID(change.changeID))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.accent)
                                        if change.isWorkingCopy == true {
                                            Text("WC")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(Theme.warning)
                                        }
                                    }

                                    Text((change.description ?? "").isEmpty ? "(no description)" : (change.description ?? ""))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)

                                    if let bookmarks = change.bookmarks, !bookmarks.isEmpty {
                                        Text(bookmarks.prefix(2).joined(separator: ", "))
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .themedSidebarRowBackground(isSelected: selectedChangeID == change.id)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .refreshable { await refresh(for: .changes) }
        .background(Theme.surface2)
    }

    private var detailPane: some View {
        Group {
            if let selectedChangeID {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(DetailTab.allCases, id: \.self) { tab in
                            Button(action: { detailTab = tab }) {
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: detailTab == tab ? .semibold : .regular))
                                    .foregroundColor(detailTab == tab ? Theme.accent : Theme.textSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                if detailTab == tab {
                                    Rectangle()
                                        .fill(Theme.accent)
                                        .frame(height: 2)
                                }
                            }
                        }

                        Spacer()
                    }
                    .border(Theme.border, edges: [.bottom])

                    switch detailTab {
                    case .info:
                        changeInfoPane(for: selectedChangeID)
                    case .diff:
                        changeDiffPane(for: selectedChangeID)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select a change")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surface1)
    }

    private func changeInfoPane(for changeID: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let actionMessage {
                    Text(actionMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.success)
                }

                if let actionError {
                    Text(actionError)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.danger)
                }

                if let detailError = detailErrors[changeID] {
                    Text(detailError)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.danger)
                }

                if detailLoading.contains(changeID) && selectedDetail == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } else if let change = selectedDetail {
                    Text((change.description ?? "").isEmpty ? "(no description)" : (change.description ?? ""))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.textPrimary)

                    Divider().background(Theme.border)

                    infoRow("ID", value: change.changeID)
                    infoRow("Author", value: authorLabel(change.author))
                    infoRow("Date", value: relativeTimestamp(change.timestamp))
                    infoRow("Bookmarks", value: selectedBookmarks.isEmpty ? "-" : selectedBookmarks.joined(separator: ", "))

                    Divider().background(Theme.border)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bookmark Actions")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)

                        HStack(spacing: 8) {
                            TextField("Bookmark name", text: $bookmarkName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(Theme.inputBg)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Theme.border, lineWidth: 1)
                                )

                            Button(action: { Task { await createBookmark() } }) {
                                HStack(spacing: 4) {
                                    if actionInFlight {
                                        ProgressView().scaleEffect(0.45).frame(width: 10, height: 10)
                                    }
                                    Text("Create")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(Theme.accent)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .disabled(actionInFlight || bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if !selectedBookmarks.isEmpty {
                            HStack(spacing: 8) {
                                Picker("Bookmark", selection: $bookmarkToDelete) {
                                    ForEach(selectedBookmarks, id: \.self) { bookmark in
                                        Text(bookmark).tag(bookmark)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 220, alignment: .leading)

                                Button(action: { Task { await deleteBookmark() } }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "trash")
                                        Text("Delete")
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Theme.danger)
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(Theme.danger.opacity(0.12))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                                .disabled(actionInFlight || bookmarkToDelete.isEmpty)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func changeDiffPane(for changeID: String) -> some View {
        ScrollView {
            Group {
                if let diffError = diffErrors[changeID] {
                    Text(diffError)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else if diffLoading.contains(changeID) && diffCache[changeID] == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    let diff = diffCache[changeID] ?? ""
                    SyntaxHighlightedText(diff.isEmpty ? "(no changes)" : diff, font: .system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themedDiffBlock()
                        .padding(16)
                }
            }
        }
        .background(Theme.base)
    }

    // MARK: - Status Mode

    private var statusPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if statusLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.6)
                        Text("Loading status...")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                if let statusError {
                    Text("Error: \(statusError)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.danger)
                } else if !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Working Copy Status")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        Text(statusText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }

                Divider().background(Theme.border)

                if !workingDiff.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Uncommitted Changes")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        SyntaxHighlightedText(workingDiff, font: .system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themedDiffBlock()
                    }
                } else if let workingDiffError {
                    Text("Diff error: \(workingDiffError)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.danger)
                } else if !statusLoading {
                    Text("Clean working copy.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await refresh(for: .status) }
        .background(Theme.surface1)
    }

    // MARK: - Actions

    private func initialLoad() async {
        await refresh(for: mode)
    }

    private func refresh(for mode: Mode) async {
        await loadRepo()
        switch mode {
        case .changes:
            await loadChanges()
        case .status:
            await loadStatus()
        }
    }

    private func loadRepo() async {
        do {
            repo = try await smithers.getCurrentRepo()
        } catch {
            // Repo metadata is informative only; keep the rest of the view usable.
        }
    }

    private func loadChanges() async {
        listLoading = true
        listError = nil

        let previousSelection = selectedChangeID

        do {
            let loaded = try await smithers.listChanges(limit: 50)
            changes = loaded

            if loaded.isEmpty {
                selectedChangeID = nil
            } else if let previousSelection,
                      loaded.contains(where: { $0.changeID == previousSelection }) {
                selectedChangeID = previousSelection
            } else {
                selectedChangeID = loaded.first?.changeID
            }

            if let selectedChangeID {
                await loadSelectedDetailAndDiff(selectedChangeID)
            }
            syncDeleteBookmarkSelection()
        } catch {
            listError = error.localizedDescription
        }

        listLoading = false
    }

    private func loadStatus() async {
        statusLoading = true
        statusError = nil
        workingDiffError = nil
        statusText = ""
        workingDiff = ""

        do {
            statusText = try await smithers.status()
        } catch {
            statusError = error.localizedDescription
        }

        do {
            var diff = try await smithers.changeDiff("@")
            if diff.isEmpty {
                diff = try await smithers.changeDiff(nil)
            }
            workingDiff = diff
        } catch {
            workingDiffError = error.localizedDescription
        }

        statusLoading = false
    }

    private func selectChange(_ change: JJHubChange) {
        selectedChangeID = change.changeID
        actionMessage = nil
        actionError = nil
        detailTab = .info
        syncDeleteBookmarkSelection()
        Task { await loadSelectedDetailAndDiff(change.changeID) }
    }

    private func loadSelectedDetailAndDiff(_ changeID: String) async {
        async let detailTask: Void = loadDetailIfNeeded(changeID)
        async let diffTask: Void = loadDiffIfNeeded(changeID)
        _ = await (detailTask, diffTask)
    }

    private func loadDetailIfNeeded(_ changeID: String) async {
        guard detailCache[changeID] == nil, !detailLoading.contains(changeID) else { return }

        detailLoading.insert(changeID)
        defer { detailLoading.remove(changeID) }

        do {
            let detail = try await smithers.viewChange(changeID)
            detailCache[changeID] = detail
            detailErrors[changeID] = nil
        } catch {
            detailErrors[changeID] = error.localizedDescription
        }
    }

    private func loadDiffIfNeeded(_ changeID: String) async {
        guard diffCache[changeID] == nil, !diffLoading.contains(changeID) else { return }

        diffLoading.insert(changeID)
        defer { diffLoading.remove(changeID) }

        do {
            let diff = try await smithers.changeDiff(changeID)
            diffCache[changeID] = diff
            diffErrors[changeID] = nil
        } catch {
            diffErrors[changeID] = error.localizedDescription
        }
    }

    private func createBookmark() async {
        guard let selectedChangeID else { return }
        let name = bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        actionInFlight = true
        actionError = nil

        do {
            _ = try await smithers.createBookmark(name: name, changeID: selectedChangeID, remote: true)
            actionMessage = "Created bookmark '\(name)'"
            bookmarkName = ""
            await loadChanges()
        } catch {
            actionError = error.localizedDescription
        }

        actionInFlight = false
    }

    private func deleteBookmark() async {
        let name = bookmarkToDelete.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        actionInFlight = true
        actionError = nil

        do {
            try await smithers.deleteBookmark(name: name, remote: true)
            actionMessage = "Deleted bookmark '\(name)'"
            await loadChanges()
        } catch {
            actionError = error.localizedDescription
        }

        actionInFlight = false
    }

    private func syncDeleteBookmarkSelection() {
        let bookmarks = selectedBookmarks
        if let first = bookmarks.first {
            if !bookmarks.contains(bookmarkToDelete) {
                bookmarkToDelete = first
            }
        } else {
            bookmarkToDelete = ""
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func shortChangeID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func authorLabel(_ author: JJHubAuthor?) -> String {
        if let name = author?.name, !name.isEmpty {
            return name
        }
        if let email = author?.email, !email.isEmpty {
            return email
        }
        return "-"
    }

    private func relativeTimestamp(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "-" }
        let parsed = Self.iso8601WithFractional.date(from: raw) ?? Self.iso8601Basic.date(from: raw)
        guard let date = parsed else { return raw }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func errorView(_ message: String, retry: @escaping () async -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await retry() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
