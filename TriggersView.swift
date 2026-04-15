import SwiftUI

struct TriggersView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var crons: [CronSchedule] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var actionError: String?

    @State private var showCreateForm = false
    @State private var newPattern = ""
    @State private var newWorkflowPath = ""
    @State private var createError: String?
    @State private var isCreating = false
    @State private var actionInFlight: Set<String> = []
    @State private var deleteTarget: CronSchedule?

    private var trimmedPattern: String {
        newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedWorkflowPath: String {
        newWorkflowPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var createValidationMessage: String? {
        if trimmedPattern.isEmpty && trimmedWorkflowPath.isEmpty {
            return "Cron pattern and workflow path are required."
        }
        if trimmedPattern.isEmpty {
            return "Cron pattern is required."
        }
        if trimmedWorkflowPath.isEmpty {
            return "Workflow path is required."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let loadError {
                errorView(loadError)
            } else {
                content
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("triggers.root")
        .task { await loadCrons() }
        .confirmationDialog(
            "Delete Trigger",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let cron = deleteTarget {
                    Task { await delete(cron) }
                }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            if let cron = deleteTarget {
                Text("Delete trigger \"\(cron.id)\"? This cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Triggers")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            Button(action: {
                showCreateForm.toggle()
                createError = nil
            }) {
                HStack(spacing: 4) {
                    Image(systemName: showCreateForm ? "xmark" : "plus")
                    Text(showCreateForm ? "Close" : "New")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.accent.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityIdentifier("triggers.newButton")

            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button(action: { Task { await loadCrons() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityIdentifier("triggers.refresh")
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showCreateForm {
                    createForm
                }

                if let actionError {
                    actionErrorBanner(actionError)
                }

                if isLoading && crons.isEmpty {
                    loadingState
                } else if crons.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(crons) { cron in
                            cronRow(cron)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .refreshable { await loadCrons() }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading triggers...")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 26))
                .foregroundColor(Theme.textTertiary)
            Text("No cron triggers found")
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
            Text("Create one to schedule workflows.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadCrons() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.danger)
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.danger)
            Spacer()
            Button("Dismiss") { actionError = nil }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.danger.opacity(0.12))
        .border(Theme.border, edges: [.bottom])
    }

    // MARK: - Create Form

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create Trigger")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Cron Pattern")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                TextField("e.g. 0 8 * * *", text: $newPattern)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .accessibilityIdentifier("triggers.create.pattern")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Workflow Path")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                TextField("e.g. .smithers/workflows/nightly.tsx", text: $newWorkflowPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Theme.inputBg)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .accessibilityIdentifier("triggers.create.workflowPath")
            }

            if let createValidationMessage {
                Text(createValidationMessage)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.warning)
            }

            if let createError {
                Text(createError)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
            }

            HStack(spacing: 8) {
                Button(action: { Task { await createCron() } }) {
                    HStack(spacing: 6) {
                        if isCreating {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        }
                        Text(isCreating ? "Creating..." : "Create")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(createValidationMessage != nil || isCreating)
                .accessibilityIdentifier("triggers.create.submit")

                Button("Cancel") {
                    resetCreateForm()
                    showCreateForm = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .accessibilityIdentifier("triggers.create.cancel")
            }
        }
        .padding(16)
        .background(Theme.base.opacity(0.55))
        .border(Theme.border, edges: [.bottom])
        .accessibilityIdentifier("triggers.create.form")
    }

    // MARK: - Rows

    private func cronRow(_ cron: CronSchedule) -> some View {
        let busy = actionInFlight.contains(cron.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(cron.id)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                statusBadge(cron, busy: busy)

                if busy {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Button(action: { Task { await toggle(cron) } }) {
                        Image(systemName: cron.enabled ? "pause.fill" : "play.fill")
                            .font(.system(size: 10))
                            .foregroundColor(cron.enabled ? Theme.warning : Theme.success)
                            .frame(width: 24, height: 24)
                            .background((cron.enabled ? Theme.warning : Theme.success).opacity(0.12))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trigger.toggle.\(cron.id)")

                    Button(action: { deleteTarget = cron }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.danger)
                            .frame(width: 24, height: 24)
                            .background(Theme.danger.opacity(0.12))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trigger.delete.\(cron.id)")
                }
            }

            Text(cron.pattern)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.accent)
                .textSelection(.enabled)

            Text(cron.workflowPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .textSelection(.enabled)

            HStack(spacing: 14) {
                metadataItem("Next", value: Self.formatTimestamp(cron.nextRunAtMs))
                metadataItem("Last", value: Self.formatTimestamp(cron.lastRunAtMs))
            }

            if let errorJson = cron.errorJson,
               !errorJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Error JSON")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.danger)
                    Text(errorJson)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(Theme.surface2)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("trigger.row.\(cron.id)")
    }

    private func statusBadge(_ cron: CronSchedule, busy: Bool) -> some View {
        let title: String
        let color: Color

        if busy {
            title = "UPDATING"
            color = Theme.textTertiary
        } else if cron.enabled {
            title = "ENABLED"
            color = Theme.success
        } else {
            title = "DISABLED"
            color = Theme.textTertiary
        }

        return Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .cornerRadius(5)
    }

    private func metadataItem(_ title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func formatTimestamp(_ ms: Int64?) -> String {
        guard let ms else { return "-" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return timestampFormatter.string(from: date)
    }

    // MARK: - Actions

    private func loadCrons() async {
        isLoading = true
        loadError = nil
        do {
            crons = try await smithers.listCrons()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func createCron() async {
        guard createValidationMessage == nil else { return }

        isCreating = true
        createError = nil
        actionError = nil

        do {
            let cron = try await smithers.createCron(pattern: trimmedPattern, workflowPath: trimmedWorkflowPath)
            crons.insert(cron, at: 0)
            resetCreateForm()
            showCreateForm = false
        } catch {
            createError = error.localizedDescription
        }

        isCreating = false
    }

    private func toggle(_ cron: CronSchedule) async {
        actionInFlight.insert(cron.id)
        defer { actionInFlight.remove(cron.id) }

        do {
            try await smithers.toggleCron(cronID: cron.id, enabled: !cron.enabled)
            if let index = crons.firstIndex(where: { $0.id == cron.id }) {
                let existing = crons[index]
                crons[index] = CronSchedule(
                    id: existing.id,
                    pattern: existing.pattern,
                    workflowPath: existing.workflowPath,
                    enabled: !existing.enabled,
                    createdAtMs: existing.createdAtMs,
                    lastRunAtMs: existing.lastRunAtMs,
                    nextRunAtMs: existing.nextRunAtMs,
                    errorJson: existing.errorJson
                )
            }
            actionError = nil
        } catch {
            actionError = "Toggle failed: \(error.localizedDescription)"
        }
    }

    private func delete(_ cron: CronSchedule) async {
        deleteTarget = nil
        actionInFlight.insert(cron.id)
        defer { actionInFlight.remove(cron.id) }

        do {
            try await smithers.deleteCron(cronID: cron.id)
            crons.removeAll { $0.id == cron.id }
            actionError = nil
        } catch {
            actionError = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func resetCreateForm() {
        newPattern = ""
        newWorkflowPath = ""
        createError = nil
    }
}
