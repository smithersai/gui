import SwiftUI

struct JJHubWorkflowsView: View {
    @ObservedObject var smithers: SmithersClient

    @State private var repo: JJHubRepo?
    @State private var workflows: [JJHubWorkflow] = []
    @State private var selectedWorkflowID: Int?
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var actionMessage: String?
    @State private var actionError: String?

    @State private var showRunPrompt = false
    @State private var refInput = ""
    @State private var promptError: String?
    @State private var isTriggering = false

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

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var selectedWorkflow: JJHubWorkflow? {
        guard let selectedWorkflowID else { return nil }
        return workflows.first { $0.id == selectedWorkflowID }
    }

    private var repoLabel: String? {
        if let fullName = repo?.fullName, !fullName.isEmpty {
            return fullName
        }
        if let owner = repo?.owner, let name = repo?.name, !owner.isEmpty, !name.isEmpty {
            return "\(owner)/\(name)"
        }
        if let name = repo?.name, !name.isEmpty {
            return name
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let loadError {
                errorView(loadError)
            } else {
                HStack(spacing: 0) {
                    workflowList
                        .frame(width: 330)
                        .accessibilityIdentifier("jjhubWorkflows.list")
                    Divider().background(Theme.border)
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("jjhubWorkflows.detail")
                }
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("jjhubWorkflows.root")
        .task { await loadData() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("JJHub Workflows")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                if let repoLabel {
                    Text(repoLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button(action: { Task { await loadData() } }) {
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

    // MARK: - List

    private var workflowList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if workflows.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No JJHub workflows found.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(workflows) { workflow in
                        Button(action: { selectWorkflow(workflow.id) }) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedWorkflowID == workflow.id ? "arrowtriangle.right.fill" : "circle.fill")
                                    .font(.system(size: selectedWorkflowID == workflow.id ? 10 : 6))
                                    .foregroundColor(selectedWorkflowID == workflow.id ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 14)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("#\(workflow.id) \(workflow.name)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)

                                    Text(pathLabel(workflow.path))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(1)

                                    Text(relativeMetadata(for: workflow))
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text(workflow.isActive ? "ACTIVE" : "INACTIVE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(workflowStatusColor(workflow.isActive))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(workflowStatusColor(workflow.isActive).opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .themedSidebarRowBackground(isSelected: selectedWorkflowID == workflow.id)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("jjhubWorkflows.row.\(workflow.id)")

                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .refreshable { await loadData() }
        .background(Theme.surface2)
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let workflow = selectedWorkflow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let actionMessage, !actionMessage.isEmpty {
                            Text(actionMessage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.success)
                                .accessibilityIdentifier("jjhubWorkflows.actionMessage")
                        }

                        if let actionError, !actionError.isEmpty {
                            Text(actionError)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.danger)
                                .accessibilityIdentifier("jjhubWorkflows.actionError")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(workflow.name)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(Theme.textPrimary)

                            Text(pathLabel(workflow.path))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .lineLimit(2)
                        }

                        Divider().background(Theme.border)

                        infoRow("ID", value: "\(workflow.id)")
                        infoRow("Status", value: workflow.isActive ? "active" : "inactive")
                        infoRow("Path", value: workflow.path)
                        infoRow("Created", value: absoluteTimestamp(workflow.createdAt))
                        infoRow("Updated", value: absoluteTimestamp(workflow.updatedAt))

                        Divider().background(Theme.border)

                        if showRunPrompt {
                            runPrompt(for: workflow)
                        } else {
                            Button(action: openRunPrompt) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Run Workflow")
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(Theme.accent)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("jjhubWorkflows.runButton")
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select a workflow")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surface1)
    }

    private func runPrompt(for workflow: JJHubWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run workflow")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Text("Choose the git ref to run against.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)

            infoRow("Workflow", value: workflow.name)

            TextField("Git ref", text: $refInput)
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
                .accessibilityIdentifier("jjhubWorkflows.refInput")

            HStack(spacing: 8) {
                Button(action: { Task { await triggerWorkflow() } }) {
                    HStack(spacing: 6) {
                        if isTriggering {
                            ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                        }
                        Text(isTriggering ? "Running..." : "Run")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(isTriggering ? Theme.accent.opacity(0.6) : Theme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isTriggering)
                .accessibilityIdentifier("jjhubWorkflows.runConfirmButton")

                Button(action: closeRunPrompt) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .themedPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .disabled(isTriggering)
                .accessibilityIdentifier("jjhubWorkflows.cancelButton")
            }

            if let promptError, !promptError.isEmpty {
                Text(promptError)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
            }
        }
        .accessibilityIdentifier("jjhubWorkflows.runPrompt")
    }

    // MARK: - Actions

    private func loadData() async {
        isLoading = true
        loadError = nil
        actionMessage = nil
        actionError = nil
        promptError = nil

        let previousSelection = selectedWorkflowID

        do {
            let loaded = try await smithers.listJJHubWorkflows(limit: 100)
            workflows = loaded
            if loaded.isEmpty {
                selectedWorkflowID = nil
                showRunPrompt = false
            } else if let previousSelection, loaded.contains(where: { $0.id == previousSelection }) {
                selectedWorkflowID = previousSelection
            } else {
                selectedWorkflowID = loaded.first?.id
                showRunPrompt = false
            }
        } catch {
            workflows = []
            selectedWorkflowID = nil
            showRunPrompt = false
            loadError = error.localizedDescription
        }

        repo = await loadRepoMetadata()
        isLoading = false
    }

    private func loadRepoMetadata() async -> JJHubRepo? {
        do {
            return try await smithers.getCurrentRepo()
        } catch {
            return nil
        }
    }

    private func selectWorkflow(_ workflowID: Int) {
        selectedWorkflowID = workflowID
        showRunPrompt = false
        promptError = nil
    }

    private func openRunPrompt() {
        let fallback = "main"
        let candidate = repo?.defaultBookmark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        refInput = candidate.isEmpty ? fallback : candidate
        promptError = nil
        actionMessage = nil
        actionError = nil
        showRunPrompt = true
    }

    private func closeRunPrompt() {
        showRunPrompt = false
        promptError = nil
        refInput = ""
    }

    private func triggerWorkflow() async {
        guard let workflow = selectedWorkflow else {
            promptError = "No workflow selected."
            return
        }

        isTriggering = true
        promptError = nil

        let trimmedRef = refInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let refToUse = trimmedRef.isEmpty ? "main" : trimmedRef

        do {
            let run = try await smithers.triggerJJHubWorkflow(workflowID: workflow.id, ref: refToUse)
            var message = "Triggered \(workflow.name) on \(refToUse)"
            if let runID = run.id, runID > 0 {
                message += " (run #\(runID))"
            }
            actionMessage = message
            actionError = nil
            closeRunPrompt()
        } catch {
            promptError = error.localizedDescription
        }

        isTriggering = false
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func workflowStatusColor(_ isActive: Bool) -> Color {
        isActive ? Theme.success : Theme.textTertiary
    }

    private func relativeMetadata(for workflow: JJHubWorkflow) -> String {
        let updated = relativeTimestamp(workflow.updatedAt)
        let created = relativeTimestamp(workflow.createdAt)
        return "updated \(updated) | created \(created)"
    }

    private func pathLabel(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-" : trimmed
    }

    private func relativeTimestamp(_ raw: String?) -> String {
        guard let date = parseDate(raw) else {
            if let raw, !raw.isEmpty { return raw }
            return "-"
        }

        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 24 * 3600 { return "\(seconds / 3600)h ago" }
        if seconds < 7 * 24 * 3600 { return "\(seconds / (24 * 3600))d ago" }
        if seconds < 365 * 24 * 3600 { return "\(seconds / (30 * 24 * 3600))mo ago" }
        return "\(seconds / (365 * 24 * 3600))y ago"
    }

    private func absoluteTimestamp(_ raw: String?) -> String {
        guard let date = parseDate(raw) else {
            if let raw, !raw.isEmpty { return raw }
            return "-"
        }
        return Self.absoluteFormatter.string(from: date)
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return Self.iso8601WithFractional.date(from: raw) ?? Self.iso8601Basic.date(from: raw)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .accessibilityIdentifier("jjhubWorkflows.loadErrorMessage")
            Button("Retry") { Task { await loadData() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("jjhubWorkflows.retryButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("jjhubWorkflows.loadError")
    }
}
