import SwiftUI

struct WorkspacesView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var workspaces: [Workspace] = []
    @State private var snapshots: [WorkspaceSnapshot] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var tab: WSTab = .workspaces
    @State private var loadGeneration = 0
    @State private var showCreate = false
    @State private var newName = ""
    @State private var isCreating = false
    @State private var actionInFlight: Set<String> = []
    @State private var deleteTarget: String?
    @State private var deleteSnapshotTarget: String?

    enum WSTab: String, CaseIterable {
        case workspaces = "Workspaces"
        case snapshots = "Snapshots"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Tabs
            HStack(spacing: 0) {
                ForEach(WSTab.allCases, id: \.self) { t in
                    Button(action: {
                        tab = t
                        // Bug 1: Clear stale data from the other tab
                        if t == .workspaces {
                            snapshots = []
                        } else {
                            workspaces = []
                        }
                        Task { await loadData() }
                    }) {
                        Text(t.rawValue)
                            .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                            .foregroundColor(tab == t ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspaces.tab.\(t.rawValue)")
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
                case .workspaces: workspacesList
                case .snapshots: snapshotsList
                }
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("workspaces.root")
        .task { await loadData() }
        .confirmationDialog(
            "Delete Workspace",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deleteTarget {
                    Task { await performDeleteWS(id) }
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Are you sure you want to delete this workspace? This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete Snapshot",
            isPresented: Binding(
                get: { deleteSnapshotTarget != nil },
                set: { if !$0 { deleteSnapshotTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let snapshotId = deleteSnapshotTarget {
                    Task { await deleteSnapshot(snapshotId) }
                }
            }
            Button("Cancel", role: .cancel) { deleteSnapshotTarget = nil }
        } message: {
            Text("Are you sure you want to delete this snapshot? This action cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Workspaces")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()

            Button(action: { showCreate.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("New")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.accent.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspaces.newButton")

            if isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
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

    // MARK: - Workspaces List

    private var workspacesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showCreate {
                    createForm
                }

                if workspaces.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No workspaces")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(workspaces) { ws in
                        HStack(spacing: 12) {
                            wsStatusIcon(ws.status)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(ws.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                HStack(spacing: 8) {
                                    if let status = ws.status {
                                        Text(status)
                                            .font(.system(size: 10))
                                            .foregroundColor(wsStatusColor(status))
                                    }
                                    if let created = ws.createdAt {
                                        Text(created)
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                }
                            }

                            Spacer()

                            if actionInFlight.contains(ws.id) {
                                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                            } else {
                                HStack(spacing: 4) {
                                    if isRunningWorkspaceStatus(ws.status) {
                                        wsAction("pause.fill", color: Theme.warning) {
                                            Task { await suspendWS(ws.id) }
                                        }
                                    } else if isSuspendedWorkspaceStatus(ws.status) {
                                        wsAction("play.fill", color: Theme.success) {
                                            Task { await resumeWS(ws.id) }
                                        }
                                    } else if ws.status?.lowercased() == "stopped" {
                                        // Bug 2: Stopped workspaces now have Resume and Delete actions
                                        wsAction("play.fill", color: Theme.success) {
                                            Task { await resumeWS(ws.id) }
                                        }
                                    }
                                    wsAction("arrow.triangle.branch", color: Theme.accent) {
                                        Task { await forkWS(ws) }
                                    }
                                    wsAction("doc.on.doc", color: Theme.accent) {
                                        Task { await snapshotWS(ws) }
                                    }
                                    // Bug 3: Delete now goes through confirmation dialog
                                    wsAction("trash", color: Theme.danger) {
                                        deleteTarget = ws.id
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("workspace.row.\(ws.id)")
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadData() }
    }

    // MARK: - Snapshots List

    private var snapshotsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if snapshots.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "camera")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textTertiary)
                        Text("No snapshots")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(snapshots) { snap in
                        HStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.accent)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(snap.name ?? snap.id)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                HStack(spacing: 8) {
                                    Text("Workspace: \(String(snap.workspaceId.prefix(8)))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                    if let created = snap.createdAt {
                                        Text(created)
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                }
                            }

                            Spacer()

                            if actionInFlight.contains(snap.id) {
                                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                            } else {
                                HStack(spacing: 4) {
                                    Button(action: { Task { await createWSFromSnapshot(snap) } }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus.square.on.square")
                                            Text("Restore")
                                        }
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(Theme.accent)
                                        .padding(.horizontal, 8)
                                        .frame(height: 24)
                                        .background(Theme.accent.opacity(0.12))
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)

                                    if !snap.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Button(action: { Task { await openSnapshotWorkspace(snap) } }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrow.turn.down.right")
                                                Text("Workspace")
                                            }
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(Theme.textSecondary)
                                            .padding(.horizontal, 8)
                                            .frame(height: 24)
                                            .background(Theme.base.opacity(0.5))
                                            .cornerRadius(4)
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    wsAction("trash", color: Theme.danger) {
                                        deleteSnapshotTarget = snap.id
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("workspace.snapshot.\(snap.id)")
                        Divider().background(Theme.border)
                    }
                }
            }
            .padding(20)
        }
        .refreshable { await loadData() }
    }

    // MARK: - Create Form

    private var createForm: some View {
        HStack(spacing: 8) {
            TextField("Workspace name", text: $newName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("workspaces.create.name")

            Button(action: { Task { await createWS() } }) {
                HStack {
                    if isCreating { ProgressView().scaleEffect(0.4).frame(width: 10, height: 10) }
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
            .disabled(newName.isEmpty || isCreating)
            .accessibilityIdentifier("workspaces.create.submit")

            Button("Cancel") { showCreate = false; newName = "" }
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspaces.create.cancel")
        }
        .padding(16)
        .background(Theme.base.opacity(0.5))
        .border(Theme.border, edges: [.bottom])
        .accessibilityIdentifier("workspaces.create.form")
    }

    // MARK: - Helpers

    private func wsAction(_ icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.12))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func wsStatusIcon(_ status: String?) -> some View {
        let (icon, color): (String, Color) = {
            switch status?.lowercased() {
            case "active", "running": return ("circle.fill", Theme.success)
            case "suspended": return ("pause.circle.fill", Theme.warning)
            default: return ("stop.circle.fill", Theme.textTertiary)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundColor(color)
            .frame(width: 18)
    }

    private func wsStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "active", "running": return Theme.success
        case "suspended": return Theme.warning
        default: return Theme.textTertiary
        }
    }

    private func isRunningWorkspaceStatus(_ status: String?) -> Bool {
        switch status?.lowercased() {
        case "active", "running": return true
        default: return false
        }
    }

    private func isSuspendedWorkspaceStatus(_ status: String?) -> Bool {
        status?.lowercased() == "suspended"
    }

    private static func snapshotTimestamp() -> String {
        DateFormatters.compactYearMonthDayHourMinute.string(from: Date())
    }

    // MARK: - Actions

    private func loadData() async {
        loadGeneration += 1
        let generation = loadGeneration
        let capturedTab = tab
        isLoading = true
        error = nil
        do {
            if capturedTab == .workspaces {
                let fetched = try await smithers.listWorkspaces()
                guard generation == loadGeneration, tab == capturedTab else { return }
                workspaces = fetched
            } else {
                let fetched = try await smithers.listWorkspaceSnapshots()
                guard generation == loadGeneration, tab == capturedTab else { return }
                snapshots = fetched
            }
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func createWS() async {
        isCreating = true
        do {
            _ = try await smithers.createWorkspace(name: newName)
            newName = ""
            showCreate = false
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }

    private func performDeleteWS(_ id: String) async {
        actionInFlight.insert(id)
        do {
            try await smithers.deleteWorkspace(id)
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        actionInFlight.remove(id)
    }

    private func suspendWS(_ id: String) async {
        actionInFlight.insert(id)
        do {
            try await smithers.suspendWorkspace(id)
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        actionInFlight.remove(id)
    }

    private func resumeWS(_ id: String) async {
        actionInFlight.insert(id)
        do {
            try await smithers.resumeWorkspace(id)
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        actionInFlight.remove(id)
    }

    private func forkWS(_ ws: Workspace) async {
        actionInFlight.insert(ws.id)
        do {
            _ = try await smithers.forkWorkspace(ws.id)
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        actionInFlight.remove(ws.id)
    }

    private func snapshotWS(_ ws: Workspace) async {
        actionInFlight.insert(ws.id)
        do {
            let timestamp = Self.snapshotTimestamp()
            _ = try await smithers.createWorkspaceSnapshot(workspaceId: ws.id, name: "\(ws.name)-snapshot-\(timestamp)")
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        actionInFlight.remove(ws.id)
    }

    private func createWSFromSnapshot(_ snap: WorkspaceSnapshot) async {
        actionInFlight.insert(snap.id)
        do {
            _ = try await smithers.createWorkspace(name: "", snapshotId: snap.id)
            tab = .workspaces
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        actionInFlight.remove(snap.id)
    }

    private func openSnapshotWorkspace(_ snap: WorkspaceSnapshot) async {
        let workspaceId = snap.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceId.isEmpty else { return }

        actionInFlight.insert(snap.id)
        do {
            _ = try await smithers.viewWorkspace(workspaceId)
            tab = .workspaces
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        actionInFlight.remove(snap.id)
    }

    private func deleteSnapshot(_ snapshotId: String) async {
        actionInFlight.insert(snapshotId)
        do {
            try await smithers.deleteWorkspaceSnapshot(snapshotId)
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
        actionInFlight.remove(snapshotId)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadData() } }
                .buttonStyle(.plain).foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
