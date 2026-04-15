import SwiftUI

struct IssuesView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var issues: [SmithersIssue] = []
    @State private var selectedId: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var stateFilter: String? = "open"
    @State private var showCreate = false
    @State private var newTitle = ""
    @State private var newBody = ""
    @State private var isCreating = false
    @State private var detailLoadingIds: Set<String> = []
    @State private var loadGeneration = 0

    private var selectedIssue: SmithersIssue? {
        issues.first { $0.id == selectedId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorBanner(error)
            }

            HStack(spacing: 0) {
                issueList
                    .frame(width: 300)
                Divider().background(Theme.border)
                detailPane
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("issues.root")
        .task(id: stateFilter) { await loadIssues() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Issues")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()

            // State filter
            HStack(spacing: 0) {
                stateButton("Open", state: "open")
                stateButton("Closed", state: "closed")
                stateButton("All", state: nil)
            }
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            Button(action: { showCreate.toggle() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("issues.createButton")

            if isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            }
            Button(action: { Task { await loadIssues() } }) {
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

    private func stateButton(_ label: String, state: String?) -> some View {
        Button(action: { stateFilter = state }) {
            Text(label)
                .font(.system(size: 11, weight: stateFilter == state ? .semibold : .regular))
                .foregroundColor(stateFilter == state ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .themedPill(fill: stateFilter == state ? Theme.pillActive : Color.clear, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("issues.filter.\(label)")
    }

    // MARK: - Issue List

    private var issueList: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Create form
                if showCreate {
                    createForm
                }

                if issues.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No issues found")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(issues) { issue in
                        Button(action: {
                            selectedId = issue.id
                            Task { await loadIssueDetail(issue) }
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: issue.state == "open" ? "circle" : "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(issue.state == "open" ? Theme.success : Theme.textTertiary)
                                    .frame(width: 16)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        if let num = issue.number {
                                            Text("#\(num)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(Theme.textTertiary)
                                        }
                                        if let labels = issue.labels {
                                            ForEach(Array(labels.prefix(3).enumerated()), id: \.offset) { _, label in
                                                Text(label)
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundColor(Theme.accent)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Theme.accent.opacity(0.12))
                                                    .cornerRadius(3)
                                            }
                                        }
                                        Spacer()
                                        if let comments = issue.commentCount, comments > 0 {
                                            HStack(spacing: 2) {
                                                Image(systemName: "bubble.right")
                                                    .font(.system(size: 9))
                                                Text("\(comments)")
                                                    .font(.system(size: 10))
                                            }
                                            .foregroundColor(Theme.textTertiary)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .themedSidebarRowBackground(isSelected: selectedId == issue.id)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("issue.row.\(issue.id)")
                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .refreshable { await loadIssues() }
        .background(Theme.surface2)
    }

    // MARK: - Create Form

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW ISSUE")
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
                .accessibilityIdentifier("issues.create.title")

            TextEditor(text: $newBody)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 60)
                .padding(6)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("issues.create.body")

            HStack(spacing: 8) {
                Button(action: { Task { await createIssue() } }) {
                    HStack {
                        if isCreating { ProgressView().scaleEffect(0.4).frame(width: 10, height: 10) }
                        Text("Create")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                .accessibilityIdentifier("issues.create.submit")

                Button("Cancel") { showCreate = false; newTitle = ""; newBody = "" }
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("issues.create.cancel")
            }
        }
        .padding(16)
        .background(Theme.base.opacity(0.5))
        .border(Theme.border, edges: [.bottom])
        .accessibilityIdentifier("issues.create.form")
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        Group {
            if let issue = selectedIssue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(issue.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if detailLoadingIds.contains(issue.id) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 16, height: 16)
                            }
                            if issue.state == "open" {
                                Button(action: { Task { await closeIssue(issue) } }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle")
                                        Text("Close")
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .themedPill(cornerRadius: 6)
                                }
                                .buttonStyle(.plain)
                            } else if issue.state == "closed" {
                                Button(action: { Task { await reopenIssue(issue) } }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.uturn.left.circle")
                                        Text("Reopen")
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Theme.success)
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .themedPill(cornerRadius: 6)
                                }
                                .buttonStyle(.plain)
                                .disabled(true)
                            }
                        }

                        HStack(spacing: 8) {
                            if let num = issue.number {
                                Text("#\(num)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Text(issue.state ?? "unknown")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(issue.state == "open" ? Theme.success : Theme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((issue.state == "open" ? Theme.success : Theme.textTertiary).opacity(0.12))
                                .cornerRadius(4)

                            if let labels = issue.labels {
                                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                                    Text(label)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(Theme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.accent.opacity(0.12))
                                        .cornerRadius(4)
                                }
                            }
                        }

                        if let assignees = issue.assignees, !assignees.isEmpty {
                            HStack(spacing: 4) {
                                Text("Assignees:")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                                Text(assignees.joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textPrimary)
                            }
                        }

                        Divider().background(Theme.border)

                        if let body = issue.body, !body.isEmpty {
                            Text(body)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select an issue")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("issues.detail.placeholder")
            }
        }
        .background(Theme.surface1)
    }

    // MARK: - Actions

    private func loadIssues(selectIssueNumber preferredIssueNumber: Int? = nil) async {
        loadGeneration += 1
        let generation = loadGeneration
        let requestedState = stateFilter
        isLoading = true
        error = nil
        let previousSelectedId = selectedId
        let previousSelectedNumber = issues.first(where: { $0.id == previousSelectedId })?.number
        do {
            let refreshedIssues = try await smithers.listIssues(state: requestedState)
            guard generation == loadGeneration, requestedState == stateFilter else { return }
            issues = refreshedIssues

            if let previousSelectedId, refreshedIssues.contains(where: { $0.id == previousSelectedId }) {
                selectedId = previousSelectedId
            } else if let selectedNumber = preferredIssueNumber ?? previousSelectedNumber,
                      let matched = refreshedIssues.first(where: { $0.number == selectedNumber }) {
                selectedId = matched.id
            } else if preferredIssueNumber != nil || refreshedIssues.isEmpty {
                selectedId = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
        }
        guard generation == loadGeneration else { return }
        isLoading = false
    }

    private func createIssue() async {
        isCreating = true
        error = nil
        do {
            let created = try await smithers.createIssue(title: newTitle, body: newBody.isEmpty ? nil : newBody)
            newTitle = ""
            newBody = ""
            showCreate = false
            selectedId = created.id
            await loadIssues(selectIssueNumber: created.number)
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }

    private func reopenIssue(_ issue: SmithersIssue) async {
        guard let num = issue.number else {
            self.error = "Cannot reopen issue: missing issue number"
            return
        }
        // TODO: Call smithers.reopenIssue when backend support is available
        self.error = "Reopen is not yet implemented for issue #\(num)"
    }

    private func closeIssue(_ issue: SmithersIssue) async {
        guard let num = issue.number else {
            self.error = "Cannot close issue: missing issue number"
            return
        }
        error = nil
        do {
            try await smithers.closeIssue(number: num, comment: nil)
            await loadIssues(selectIssueNumber: num)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadIssueDetail(_ issue: SmithersIssue) async {
        guard let number = issue.number, !detailLoadingIds.contains(issue.id) else { return }
        detailLoadingIds.insert(issue.id)
        defer { detailLoadingIds.remove(issue.id) }

        do {
            let detail = try await smithers.getIssue(number: number)
            guard let index = issues.firstIndex(where: { $0.id == issue.id || $0.number == number }) else {
                return
            }
            issues[index] = detail
            if selectedId == issue.id {
                selectedId = detail.id
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            Spacer()
            Button("Retry") { Task { await loadIssues() } }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.accent)
            Button(action: { error = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.1))
        .border(Theme.border, edges: [.bottom])
    }
}
