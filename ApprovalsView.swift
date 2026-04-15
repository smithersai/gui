import SwiftUI

struct ApprovalsView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var approvals: [Approval] = []
    @State private var decisions: [ApprovalDecision] = []
    @State private var selectedId: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showHistory = false
    @State private var loadGeneration = 0
    @State private var actionInFlight: Set<String> = [] // approval ids being acted on
    @State private var pendingDenyApproval: Approval?

    private var selectedApproval: Approval? {
        visibleApprovals.first { $0.id == selectedId }
    }

    private var selectedDecision: ApprovalDecision? {
        guard showHistory else { return nil }
        return decisions.first { $0.id == selectedId }
    }

    private var visibleApprovals: [Approval] {
        showHistory ? approvals : approvals.filterPendingApprovals()
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorView(error)
            } else {
                HStack(spacing: 0) {
                    listPane
                        .frame(width: 300)
                    Divider().background(Theme.border)
                    detailPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("approvals.root")
        .task { await loadApprovals() }
        .confirmationDialog(
            "Deny Approval",
            isPresented: Binding(
                get: { pendingDenyApproval != nil },
                set: { if !$0 { pendingDenyApproval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Deny Approval", role: .destructive) {
                if let approval = pendingDenyApproval {
                    pendingDenyApproval = nil
                    Task { await deny(approval) }
                }
            }
            .accessibilityIdentifier("approval.confirmDenyButton")

            Button("Cancel", role: .cancel) {
                pendingDenyApproval = nil
            }
            .accessibilityIdentifier("approval.cancelDenyButton")
        } message: {
            if let approval = pendingDenyApproval {
                Text("Deny approval for \(approval.gate ?? approval.nodeId) on run \(String(approval.runId.prefix(8)))? This will fail the waiting gate.")
            } else {
                Text("Deny this approval? This will fail the waiting gate.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Approvals")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            // Toggle pending / history
            Button(action: { showHistory.toggle(); Task { await loadApprovals() } }) {
                HStack(spacing: 4) {
                    Image(systemName: showHistory ? "tray" : "clock.arrow.circlepath")
                        .font(.system(size: 11))
                    Text(showHistory ? "Pending" : "History")
                        .font(.system(size: 11))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.inputBg)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("approvals.historyToggle")

            if isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            }
            Button(action: { Task { await loadApprovals() } }) {
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

    // MARK: - List Pane

    private var listPane: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showHistory {
                    if decisions.isEmpty && !isLoading {
                        emptyView("No recent decisions")
                    } else {
                        ForEach(decisions) { decision in
                            Button(action: { selectedId = decision.id }) {
                                HStack(spacing: 10) {
                                    Image(systemName: decision.action == "approved" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(decision.action == "approved" ? Theme.success : Theme.danger)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(decision.gate ?? decision.nodeId)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(Theme.textPrimary)
                                            .lineLimit(1)
                                        Text("Run: \(String(decision.runId.prefix(8)))")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                    }

                                    Spacer()

                                    Text(decision.action.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(decision.action == "approved" ? Theme.success : Theme.danger)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .themedSidebarRowBackground(isSelected: selectedId == decision.id)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("approval.history.row.\(decision.id)")
                            Divider().background(Theme.border)
                        }
                    }
                } else {
                    if visibleApprovals.isEmpty && !isLoading {
                        emptyView("No pending approvals")
                    } else {
                        ForEach(visibleApprovals) { approval in
                            Button(action: { selectedId = approval.id }) {
                                HStack(spacing: 10) {
                                    if actionInFlight.contains(approval.id) {
                                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                                    } else {
                                        Circle()
                                            .stroke(Theme.warning, lineWidth: 1.5)
                                            .frame(width: 14, height: 14)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(approval.gate ?? approval.nodeId)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(Theme.textPrimary)
                                            .lineLimit(1)
                                        Text("Run: \(String(approval.runId.prefix(8)))")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(approval.waitTime)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(waitTimeColor(approval))

                                        if approval.isSyntheticFallback {
                                            Text("SYNTHETIC")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundColor(Theme.warning)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .themedSidebarRowBackground(isSelected: selectedId == approval.id)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("approval.row.\(approval.id)")
                            Divider().background(Theme.border)
                        }
                    }
                }
            }
        }
        .refreshable { await loadApprovals() }
        .background(Theme.surface2)
        .accessibilityIdentifier(showHistory ? "approvals.historyList" : "approvals.pendingList")
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        Group {
            if let approval = selectedApproval {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Title
                        Text(approval.gate ?? approval.nodeId)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.textPrimary)

                        // Metadata
                        VStack(alignment: .leading, spacing: 8) {
                            metadataRow("Run ID", value: approval.runId)
                            metadataRow("Node ID", value: approval.nodeId)
                            if let wp = approval.workflowPath {
                                metadataRow("Workflow", value: wp)
                            }
                            metadataRow("Requested", value: formatDate(approval.requestedDate))
                            metadataRow("Status", value: approval.status.uppercased())
                            metadataRow("Wait Time", value: approval.waitTime)
                            if let source = approval.source, !source.isEmpty {
                                metadataRow("Source", value: source.uppercased())
                            }
                            if let resolvedAt = approval.resolvedAt {
                                metadataRow("Resolved", value: formatDate(Date(timeIntervalSince1970: Double(resolvedAt) / 1000)))
                            }
                            if let resolvedBy = approval.resolvedBy, !resolvedBy.isEmpty {
                                metadataRow("Resolved By", value: resolvedBy)
                            }
                            if let decision = selectedDecision, let note = decision.note, !note.isEmpty {
                                metadataRow("Note", value: note)
                            }
                            if let decision = selectedDecision, let reason = decision.reason, !reason.isEmpty {
                                metadataRow("Reason", value: reason)
                            }
                        }

                        if approval.isSyntheticFallback {
                            Text("This approval was derived from run inspection because no native approval transport was available.")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.warning)
                        }

                        Divider().background(Theme.border)

                        // Payload
                        if let payload = approval.payload, !payload.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("CONTEXT / PAYLOAD")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Theme.textTertiary)

                                Text(prettyJSON(payload))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.base)
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                            }
                        }

                        Divider().background(Theme.border)

                        // Actions
                        if approval.isPending {
                            HStack(spacing: 12) {
                                Button(action: { Task { await approve(approval) } }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark")
                                        Text("Approve")
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .padding(.horizontal, 20)
                                    .frame(height: 36)
                                    .background(Theme.success)
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .disabled(actionInFlight.contains(approval.id))
                                .accessibilityIdentifier("approval.approveButton")

                                Button(action: { pendingDenyApproval = approval }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark")
                                        Text("Deny")
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .padding(.horizontal, 20)
                                    .frame(height: 36)
                                    .background(Theme.danger)
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .disabled(actionInFlight.contains(approval.id))
                                .accessibilityIdentifier("approval.denyButton")
                            }
                        }
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select an approval")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("approvals.detail.placeholder")
            }
        }
        .background(Theme.surface1)
    }

    // MARK: - Helpers

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func waitTimeColor(_ approval: Approval) -> Color {
        let seconds = Int(Date().timeIntervalSince(approval.requestedDate))
        if seconds < 300 { return Theme.textTertiary }
        if seconds < 1800 { return Theme.warning }
        return Theme.danger
    }

    private func formatDate(_ date: Date) -> String {
        DateFormatters.localizedShortDateMediumTime.string(from: date)
    }

    private func prettyJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return str
    }

    private func emptyView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
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
            Button("Retry") { Task { await loadApprovals() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func loadApprovals() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        do {
            if showHistory {
                let fetched = try await smithers.listRecentDecisions()
                guard generation == loadGeneration else { return }
                decisions = fetched
                approvals = decisions.map(decisionAsApproval)
            } else {
                let fetched = try await smithers.listPendingApprovals()
                guard generation == loadGeneration else { return }
                approvals = fetched
                decisions = []
            }
            syncSelection()
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
            AppNotifications.shared.post(
                title: "Approvals refresh failed",
                message: error.localizedDescription,
                level: .warning
            )
        }
        isLoading = false
    }

    private func approve(_ approval: Approval) async {
        actionInFlight.insert(approval.id)
        do {
            try await smithers.approveNode(runId: approval.runId, nodeId: approval.nodeId)
            AppNotifications.shared.post(
                title: "Approval granted",
                message: "\(approval.gate ?? approval.nodeId) (\(String(approval.runId.prefix(8))))",
                level: .approval
            )
            await loadApprovals()
            selectedId = nil
        } catch {
            self.error = error.localizedDescription
            AppNotifications.shared.post(
                title: "Approval failed",
                message: error.localizedDescription,
                level: .error
            )
        }
        actionInFlight.remove(approval.id)
    }

    private func deny(_ approval: Approval) async {
        actionInFlight.insert(approval.id)
        do {
            try await smithers.denyNode(runId: approval.runId, nodeId: approval.nodeId)
            AppNotifications.shared.post(
                title: "Approval denied",
                message: "\(approval.gate ?? approval.nodeId) (\(String(approval.runId.prefix(8))))",
                level: .approval
            )
            await loadApprovals()
            selectedId = nil
        } catch {
            self.error = error.localizedDescription
            AppNotifications.shared.post(
                title: "Deny failed",
                message: error.localizedDescription,
                level: .error
            )
        }
        actionInFlight.remove(approval.id)
    }

    private func decisionAsApproval(_ decision: ApprovalDecision) -> Approval {
        Approval(
            id: decision.id,
            runId: decision.runId,
            nodeId: decision.nodeId,
            workflowPath: decision.workflowPath,
            gate: decision.gate,
            status: decision.action,
            payload: decision.payload,
            requestedAt: decision.requestedAt ?? decision.resolvedAt ?? Int64(Date().timeIntervalSince1970 * 1000),
            resolvedAt: decision.resolvedAt,
            resolvedBy: decision.resolvedBy,
            source: decision.source
        )
    }

    private func syncSelection() {
        let candidates = visibleApprovals
        guard !candidates.isEmpty else {
            selectedId = nil
            return
        }

        if let selectedId, candidates.contains(where: { $0.id == selectedId }) {
            return
        }
        self.selectedId = candidates[0].id
    }
}
