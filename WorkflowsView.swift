import SwiftUI

struct WorkflowsView: View {
    @ObservedObject var smithers: SmithersClient
    @State private var workflows: [Workflow] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedWorkflow: Workflow?
    @State private var launchFields: [WorkflowLaunchField]?
    @State private var launchInputs: [String: String] = [:]
    @State private var showLaunchForm = false
    @State private var isLaunching = false
    @State private var launchError: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorView(error)
            } else {
                HSplitView {
                    workflowList
                        .frame(minWidth: 250)
                    detailPane
                        .frame(minWidth: 300)
                }
            }
        }
        .background(Theme.surface1)
        .task { await loadWorkflows() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Workflows")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            }
            Button(action: { Task { await loadWorkflows() } }) {
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

    // MARK: - Workflow List

    private var workflowList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if workflows.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 28))
                            .foregroundColor(Theme.textTertiary)
                        Text("No workflows found")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(workflows) { workflow in
                        Button(action: { selectWorkflow(workflow) }) {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 12))
                                    .foregroundColor(selectedWorkflow?.id == workflow.id ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workflow.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    if let path = workflow.relativePath {
                                        Text(path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                if let status = workflow.status {
                                    Text(status.rawValue.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(workflowStatusColor(status))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(workflowStatusColor(status).opacity(0.15))
                                        .cornerRadius(4)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(selectedWorkflow?.id == workflow.id ? Theme.sidebarSelected : Color.clear)
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

    // MARK: - Detail Pane

    private var detailPane: some View {
        Group {
            if let workflow = selectedWorkflow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Workflow info
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workflow.name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Theme.textPrimary)

                            if let path = workflow.relativePath {
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                            }

                            HStack(spacing: 12) {
                                if let status = workflow.status {
                                    Label(status.rawValue, systemImage: "circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(workflowStatusColor(status))
                                }
                                if let updated = workflow.updatedAt {
                                    Label(updated, systemImage: "clock")
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.textTertiary)
                                }
                            }
                        }

                        Divider().background(Theme.border)

                        // Launch fields / input schema
                        if let fields = launchFields, !fields.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("INPUT SCHEMA")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Theme.textTertiary)

                                ForEach(fields, id: \.key) { field in
                                    HStack(spacing: 8) {
                                        Text(field.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(Theme.textPrimary)
                                        Text(field.type ?? "string")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Theme.pillBg)
                                            .cornerRadius(3)
                                        Spacer()
                                        if let def = field.defaultValue {
                                            Text("default: \(def)")
                                                .font(.system(size: 10))
                                                .foregroundColor(Theme.textTertiary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }

                            Divider().background(Theme.border)
                        }

                        // Launch form
                        if showLaunchForm {
                            launchFormView
                        } else {
                            Button(action: { prepareLaunch() }) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Run Workflow")
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(Theme.accent)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }

                        if let launchError {
                            Text(launchError)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.danger)
                        }
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
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

    // MARK: - Launch Form

    private var launchFormView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LAUNCH INPUTS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)

            if let fields = launchFields {
                ForEach(fields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        TextField(
                            field.defaultValue ?? "Enter \(field.name)...",
                            text: Binding(
                                get: { launchInputs[field.key] ?? "" },
                                set: { launchInputs[field.key] = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Theme.inputBg)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: { Task { await launchWorkflow() } }) {
                    HStack {
                        if isLaunching {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        }
                        Text(isLaunching ? "Launching..." : "Launch")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(isLaunching ? Theme.accent.opacity(0.5) : Theme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isLaunching)

                Button(action: { showLaunchForm = false }) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Theme.pillBg)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func selectWorkflow(_ workflow: Workflow) {
        selectedWorkflow = workflow
        launchFields = nil
        showLaunchForm = false
        launchError = nil
        Task { await loadDAG(workflow.id) }
    }

    private func prepareLaunch() {
        launchInputs = [:]
        if let fields = launchFields {
            for field in fields {
                if let def = field.defaultValue {
                    launchInputs[field.key] = def
                }
            }
        }
        showLaunchForm = true
    }

    private func loadWorkflows() async {
        isLoading = true
        error = nil
        do {
            workflows = try await smithers.listWorkflows()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func loadDAG(_ workflowId: String) async {
        do {
            let dag = try await smithers.getWorkflowDAG(workflowId)
            launchFields = dag.fields ?? []
        } catch {
            launchFields = []
        }
    }

    private func launchWorkflow() async {
        guard let workflow = selectedWorkflow else { return }
        isLaunching = true
        launchError = nil
        do {
            _ = try await smithers.runWorkflow(workflow.id, inputs: launchInputs)
            showLaunchForm = false
            launchInputs = [:]
        } catch {
            launchError = error.localizedDescription
        }
        isLaunching = false
    }

    private func workflowStatusColor(_ status: WorkflowStatus) -> Color {
        switch status {
        case .active: return Theme.success
        case .hot: return Theme.warning
        case .draft: return Theme.textTertiary
        case .archived: return Theme.textTertiary
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Button("Retry") { Task { await loadWorkflows() } }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
