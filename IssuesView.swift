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

    private var selectedIssue: SmithersIssue? {
        issues.first { $0.id == selectedId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorView(error)
            } else {
                HStack(spacing: 0) {
                    issueList
                        .frame(width: 300)
                    Divider().background(Theme.border)
                    detailPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.surface1)
        .task { await loadIssues() }
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
        Button(action: { stateFilter = state; Task { await loadIssues() } }) {
            Text(label)
                .font(.system(size: 11, weight: stateFilter == state ? .semibold : .regular))
                .foregroundColor(stateFilter == state ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(stateFilter == state ? Theme.pillActive : Color.clear)
        }
        .buttonStyle(.plain)
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
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No issues found")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(issues) { issue in
                        Button(action: { selectedId = issue.id }) {
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
                                            ForEach(labels.prefix(3), id: \.self) { label in
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
                            .background(selectedId == issue.id ? Theme.sidebarSelected : Color.clear)
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

            TextEditor(text: $newBody)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 60)
                .padding(6)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            HStack(spacing: 8) {
                Button(action: { Task { await createIssue() } }) {
                    HStack {
                        if isCreating { ProgressView().scaleEffect(0.4).frame(width: 10, height: 10) }
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
                .disabled(newTitle.isEmpty || isCreating)

                Button("Cancel") { showCreate = false; newTitle = ""; newBody = "" }
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Theme.base.opacity(0.5))
        .border(Theme.border, edges: [.bottom])
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
                                    .background(Theme.pillBg)
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
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
                                ForEach(labels, id: \.self) { label in
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
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select an issue")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surface1)
    }

    // MARK: - Actions

    private func loadIssues() async {
        isLoading = true
        error = nil
        do {
            issues = try await smithers.listIssues(state: stateFilter)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func createIssue() async {
        isCreating = true
        do {
            _ = try await smithers.createIssue(title: newTitle, body: newBody.isEmpty ? nil : newBody)
            newTitle = ""
            newBody = ""
            showCreate = false
            await loadIssues()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }

    private func closeIssue(_ issue: SmithersIssue) async {
        guard let num = issue.number else { return }
        do {
            try await smithers.closeIssue(number: num, comment: nil)
            await loadIssues()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadIssues() } }
                .buttonStyle(.plain).foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
