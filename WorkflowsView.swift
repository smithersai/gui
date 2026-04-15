import SwiftUI

struct WorkflowsView: View {
    @ObservedObject var smithers: SmithersClient
    var onNavigate: ((NavDestination) -> Void)?
    var onRunStarted: ((String, String?) -> Void)? = nil
    @State private var workflows: [Workflow] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedWorkflow: Workflow?
    @State private var launchFields: [WorkflowLaunchField]?
    @State private var workflowDAG: WorkflowDAG?
    @State private var isLoadingDAG = false
    @State private var dagLoadError: String?
    @State private var showDAGDetails = false
    @State private var launchInputs: [String: String] = [:]
    @State private var launchValidationErrors: [String: String] = [:]
    @State private var isLaunching = false
    @State private var showRunConfirmation = false
    @State private var doctorIssues: [WorkflowDoctorIssue] = []
    @State private var isRunningDoctor = false
    @State private var lastRunStatusByWorkflowID: [String: RunStatus] = [:]
    @State private var runErrorByWorkflowID: [String: String] = [:]

    // Editor state
    @State private var tab: DetailTab = .source
    @State private var workflowSource: String = ""
    @State private var originalWorkflowSource: String = ""
    @State private var importedFiles: [ImportedFile] = []
    @State private var selectedFileIndex: Int? = nil
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showUnsavedAlert = false
    @State private var pendingWorkflow: Workflow?

    // Runs state
    @State private var workflowRuns: [RunSummary] = []
    @State private var isLoadingRuns = false

    enum DetailTab: String, CaseIterable {
        case source = "Workflow"
        case imports = "Imports"
        case runs = "Runs"
        case launch = "Launch"
    }

    struct ImportedFile: Identifiable {
        let id: String  // relative path
        let name: String
        let kind: Kind
        var source: String
        var originalSource: String

        var hasChanges: Bool { source != originalSource }

        enum Kind: String {
            case component = "Component"
            case prompt = "Prompt"
        }
    }

    private enum WorkflowLaunchInputKind {
        case string
        case number
        case boolean
        case object
        case array
        case json

        init(_ rawType: String?) {
            let normalized = rawType?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            switch normalized {
            case "number", "integer", "int", "float", "double":
                self = .number
            case "boolean", "bool":
                self = .boolean
            case "object":
                self = .object
            case "array", "list":
                self = .array
            case "json":
                self = .json
            default:
                self = .string
            }
        }

        var label: String {
            switch self {
            case .string: return "string"
            case .number: return "number"
            case .boolean: return "boolean"
            case .object: return "object"
            case .array: return "array"
            case .json: return "json"
            }
        }

        var expectedDescription: String {
            switch self {
            case .object: return "a JSON object"
            case .array: return "a JSON array"
            case .json: return "valid JSON"
            case .number: return "a number"
            case .boolean: return "a boolean"
            case .string: return "text"
            }
        }
    }

    private enum WorkflowLaunchInputError: LocalizedError {
        case missingRequired(field: String)
        case invalidNumber(field: String, value: String)
        case invalidJSON(field: String, expected: String)

        var errorDescription: String? {
            switch self {
            case .missingRequired(let field):
                return "\(field) is required."
            case .invalidNumber(let field, let value):
                return "\(field) must be a number. \"\(value)\" is not valid."
            case .invalidJSON(let field, let expected):
                return "\(field) must be \(expected)."
            }
        }
    }

    private var hasAnyChanges: Bool {
        workflowSource != originalWorkflowSource ||
        importedFiles.contains(where: { $0.hasChanges })
    }

    private var changedFileCount: Int {
        (workflowSource != originalWorkflowSource ? 1 : 0) +
        importedFiles.filter({ $0.hasChanges }).count
    }

    private var selectedRunStatus: RunStatus? {
        guard let workflowID = selectedWorkflow?.id else { return nil }
        return lastRunStatusByWorkflowID[workflowID]
    }

    private var selectedRunError: String? {
        guard let workflowID = selectedWorkflow?.id else { return nil }
        return runErrorByWorkflowID[workflowID]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error {
                errorView(error)
            } else {
                HStack(spacing: 0) {
                    workflowList
                        .frame(width: 280)
                        .accessibilityIdentifier("workflows.list")
                    Divider().background(Theme.border)
                    detailPane
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("workflows.detail")
                }
            }
        }
        .background(Theme.surface1)
        .accessibilityIdentifier("workflows.root")
        .task { await loadWorkflows() }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Discard", role: .destructive) {
                if let w = pendingWorkflow {
                    pendingWorkflow = nil
                    saveError = nil
                    applySelection(w)
                }
            }
            Button("Cancel", role: .cancel) { pendingWorkflow = nil }
        } message: {
            Text("You have unsaved changes to \(changedFileCount) file(s). Discard them?")
        }
        .confirmationDialog(
            "Run Workflow",
            isPresented: $showRunConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run") { Task { await launchWorkflow() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let workflow = selectedWorkflow {
                if let dagLoadError {
                    Text("Run \"\(workflow.name)\" anyway? Launch-field analysis failed: \(dagLoadError)")
                } else {
                    Text("Run \"\(workflow.name)\" with no input form?")
                }
            } else {
                Text("Run selected workflow?")
            }
        }
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
                                    if let path = workflow.filePath {
                                        Text(path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    if let status = workflow.status {
                                        Text(status.rawValue.uppercased())
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(workflowStatusColor(status))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(workflowStatusColor(status).opacity(0.15))
                                            .cornerRadius(4)
                                    }
                                    if let runStatus = lastRunStatusByWorkflowID[workflow.id] {
                                        Text("LAST \(runStatusBadgeLabel(runStatus))")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(runStatusColor(runStatus))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(runStatusColor(runStatus).opacity(0.15))
                                            .cornerRadius(4)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .themedSidebarRowBackground(isSelected: selectedWorkflow?.id == workflow.id)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workflow.row.\(workflow.id)")
                        Divider().background(Theme.border)
                    }
                }
            }
        }
        .refreshable { await loadWorkflows() }
        .background(Theme.surface2)
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        Group {
            if let workflow = selectedWorkflow {
                VStack(spacing: 0) {
                    // Workflow header bar
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                            if let path = workflow.filePath {
                                Text(path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if let status = workflow.status {
                                Label(status.rawValue, systemImage: "circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(workflowStatusColor(status))
                            }
                            if let runStatus = selectedRunStatus {
                                Label("last: \(runStatusBadgeLabel(runStatus))", systemImage: runStatusIcon(runStatus))
                                    .font(.system(size: 10))
                                    .foregroundColor(runStatusColor(runStatus))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .border(Theme.border, edges: [.bottom])

                    // Tab bar + save
                    HStack(spacing: 0) {
                        ForEach(DetailTab.allCases, id: \.self) { t in
                            Button(action: { tab = t }) {
                                HStack(spacing: 4) {
                                    Text(t.rawValue)
                                        .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                                        .foregroundColor(tab == t ? Theme.accent : Theme.textSecondary)
                                    if t == .imports && !importedFiles.isEmpty {
                                        Text("\(importedFiles.count)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(Theme.textTertiary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .themedPill(cornerRadius: 8)
                                    }
                                    if t == .runs && !workflowRuns.isEmpty {
                                        Text("\(workflowRuns.count)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(Theme.textTertiary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .themedPill(cornerRadius: 8)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workflows.tab.\(t.rawValue.lowercased())")
                            .overlay(alignment: .bottom) {
                                if tab == t {
                                    Rectangle().fill(Theme.accent).frame(height: 2)
                                }
                            }
                        }
                        Spacer()

                        if let saveError {
                            Text(saveError)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.danger)
                                .lineLimit(1)
                                .padding(.trailing, 4)
                        }

                        if hasAnyChanges {
                            Text("\(changedFileCount) unsaved")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.warning)
                                .padding(.trailing, 6)

                            Button(action: { isSaving = true; Task { await saveAll() } }) {
                                HStack(spacing: 4) {
                                    if isSaving {
                                        ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                                    }
                                    Text("Save All")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .background(Theme.accent)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)
                            .padding(.trailing, 12)
                            .accessibilityIdentifier("workflows.saveAllButton")
                        }
                    }
                    .border(Theme.border, edges: [.bottom])

                    // Tab content
                    switch tab {
                    case .source:
                        workflowSourceEditor
                    case .imports:
                        importsPane
                    case .runs:
                        runsPane
                    case .launch:
                        launchPane
                    }
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
                .accessibilityIdentifier("workflows.detail.placeholder")
            }
        }
        .background(Theme.surface1)
    }

    // MARK: - Workflow Source Editor

    private var workflowSourceEditor: some View {
        VStack(spacing: 0) {
            // Modified indicator
            if workflowSource != originalWorkflowSource {
                HStack {
                    Circle().fill(Theme.warning).frame(width: 6, height: 6)
                    Text("Modified")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.warning)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Theme.warning.opacity(0.08))
            }

            SyntaxHighlightedTextEditor(
                text: $workflowSource,
                language: SourceCodeLanguage(fileName: selectedWorkflow?.filePath ?? "workflow.tsx"),
                accessibilityIdentifier: "workflows.sourceEditor"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.base)
            .padding(1)
        }
    }

    // MARK: - Imports Pane

    private var importsPane: some View {
        HStack(spacing: 0) {
            // File list sidebar
            VStack(spacing: 0) {
                if importedFiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.textTertiary)
                        Text("No imports found")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            // Group by kind
                            let components = importedFiles.enumerated().filter { $0.element.kind == .component }
                            let prompts = importedFiles.enumerated().filter { $0.element.kind == .prompt }

                            if !components.isEmpty {
                                sectionHeader("COMPONENTS")
                                ForEach(components, id: \.offset) { idx, file in
                                    importFileRow(file, index: idx)
                                }
                            }
                            if !prompts.isEmpty {
                                sectionHeader("PROMPTS")
                                ForEach(prompts, id: \.offset) { idx, file in
                                    importFileRow(file, index: idx)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 200)
            .background(Theme.surface2)

            Divider().background(Theme.border)

            // Editor for selected import
            if let idx = selectedFileIndex, idx < importedFiles.count {
                VStack(spacing: 0) {
                    // File info bar
                    HStack(spacing: 8) {
                        Image(systemName: importedFiles[idx].kind == .component ? "puzzlepiece" : "doc.text")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.accent)
                        Text(importedFiles[idx].id)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text(importedFiles[idx].kind.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .themedPill(cornerRadius: 4)
                        if importedFiles[idx].hasChanges {
                            Circle().fill(Theme.warning).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surface2)
                    .border(Theme.border, edges: [.bottom])

                    SyntaxHighlightedTextEditor(
                        text: $importedFiles[idx].source,
                        language: SourceCodeLanguage(fileName: importedFiles[idx].id),
                        accessibilityIdentifier: "workflows.importEditor.\(importedFiles[idx].name)"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.base)
                    .padding(1)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select an imported file to edit")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface1.opacity(0.5))
    }

    private func importFileRow(_ file: ImportedFile, index: Int) -> some View {
        VStack(spacing: 0) {
            Button(action: { selectedFileIndex = index }) {
                HStack(spacing: 8) {
                    Image(systemName: file.kind == .component ? "puzzlepiece" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(selectedFileIndex == index ? Theme.accent : Theme.textTertiary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Text(file.id)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if file.hasChanges {
                        Circle().fill(Theme.warning).frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .themedSidebarRowBackground(isSelected: selectedFileIndex == index)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().background(Theme.border).padding(.leading, 36)
        }
    }

    // MARK: - Launch Pane

    private var launchPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                workflowDoctorSection

                Divider().background(Theme.border)

                workflowGraphSection

                Divider().background(Theme.border)

                launchInputsSection

                let launchDisabled = isLaunching || (isLoadingDAG && workflowDAG == nil) || !launchValidationErrors.isEmpty
                HStack(spacing: 8) {
                    Button(action: { Task { await handleRunTapped() } }) {
                        HStack {
                            if isLaunching {
                                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            }
                            Image(systemName: "play.fill")
                            Text(isLaunching ? "Launching..." : "Run Workflow")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(launchDisabled ? Theme.accent.opacity(0.5) : Theme.accent)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(launchDisabled)
                    .accessibilityIdentifier("workflows.runButton")
                }

                if let selectedRunStatus {
                    Label("Last run: \(runStatusBadgeLabel(selectedRunStatus))", systemImage: runStatusIcon(selectedRunStatus))
                        .font(.system(size: 11))
                        .foregroundColor(runStatusColor(selectedRunStatus))
                }

                if let selectedRunError {
                    Text("Run failed: \(selectedRunError)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.danger)
                        .accessibilityIdentifier("workflows.launchError")
                }
            }
            .padding(20)
        }
    }

    private var workflowDoctorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("WORKFLOW DOCTOR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Button(action: { Task { await runDoctorDiagnostics() } }) {
                    HStack(spacing: 5) {
                        if isRunningDoctor {
                            ProgressView().scaleEffect(0.45).frame(width: 10, height: 10)
                        }
                        Image(systemName: "stethoscope")
                        Text(isRunningDoctor ? "Running..." : "Run Doctor")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.accent.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isRunningDoctor || selectedWorkflow == nil)
                .accessibilityIdentifier("workflows.doctorButton")
            }

            if doctorIssues.isEmpty {
                Text("Run diagnostics to verify workflow launch readiness.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(doctorIssues) { issue in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: doctorIssueIcon(issue.severity))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(doctorIssueColor(issue.severity))
                                .frame(width: 14, alignment: .center)
                            Text(issue.message)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                            Spacer(minLength: 0)
                        }
                    }

                    if doctorIssues.contains(where: { $0.severity != "ok" }) {
                        Text("Issues found. Review warnings and errors above.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.warning)
                    } else {
                        Text("All checks passed.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.success)
                    }
                }
                .padding(10)
                .background(Theme.surface2)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("workflows.doctorResults")
            }
        }
    }

    private var workflowGraphSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("WORKFLOW DAG")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textTertiary)
                Spacer()

                Button(showDAGDetails ? "Hide Details" : "Show Details") {
                    showDAGDetails.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("workflows.dag.toggleDetails")
            }

            if let workflowDAG {
                workflowGraphContent(workflowDAG)
            } else if isLoadingDAG {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text("Loading graph...")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                .accessibilityIdentifier("workflows.graph.loading")
            } else {
                Text(dagLoadError ?? "Graph unavailable")
                    .font(.system(size: 11))
                    .foregroundColor(dagLoadError == nil ? Theme.textTertiary : Theme.warning)
                    .accessibilityIdentifier("workflows.graph.unavailable")
            }
        }
        .accessibilityIdentifier("workflows.graph")
    }

    @ViewBuilder
    private func workflowGraphContent(_ dag: WorkflowDAG) -> some View {
        let nodes = dag.nodes
        let edges = dag.edges
        let fields = dag.launchFields

        HStack(spacing: 8) {
            Text((dag.mode ?? "inferred").uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(dag.isFallbackMode ? Theme.warning : Theme.success)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((dag.isFallbackMode ? Theme.warning : Theme.success).opacity(0.15))
                .cornerRadius(4)

            if let entryTask = dag.resolvedEntryTaskID, !entryTask.isEmpty {
                Label("entry \(entryTask)", systemImage: "person.crop.square")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }

        if let message = dag.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
        }

        if !nodes.isEmpty {
            HStack(spacing: 8) {
                Label("\(nodes.count) nodes", systemImage: "circle.grid.cross")
                Label("\(edges.count) edges", systemImage: "arrow.right")
            }
            .font(.system(size: 10))
            .foregroundColor(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(nodes) { task in
                    workflowGraphNodeRow(task, outgoing: edges.filter { $0.from == task.nodeId })
                }
            }
        } else if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input pipeline")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)

                HStack(alignment: .center, spacing: 6) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        Text(field.key)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Theme.surface2)
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))

                        if index < fields.count - 1 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    if let entryTask = dag.resolvedEntryTaskID, !entryTask.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textTertiary)
                        Text(entryTask)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.accent)
                    }
                }
            }
            .accessibilityIdentifier("workflows.graph.pipeline")
        } else {
            Text("No graph nodes or input fields found")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .accessibilityIdentifier("workflows.graph.empty")
        }

        if showDAGDetails, !fields.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("SCHEMA DETAILS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textTertiary)

                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    HStack(spacing: 8) {
                        Text(field.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text(field.type ?? "string")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                        Text("key: \(field.key)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                        Spacer()
                        if let def = field.defaultValue, !def.isEmpty {
                            Text("default: \(def)")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func workflowGraphNodeRow(_ task: WorkflowDAGTask, outgoing: [WorkflowDAGEdge]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.accent)
                    .frame(width: 14)

                Text(task.nodeId)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                if let table = task.outputTableName {
                    Text(table)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .themedPill(cornerRadius: 3)
                }

                Spacer()

                if task.needsApproval == true {
                    Text("approval")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.warning)
                }
            }

            if !outgoing.isEmpty {
                Text("-> \(outgoing.map(\.to).joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, 22)
                    .accessibilityIdentifier("workflows.graph.edges.\(task.nodeId)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface2)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("workflows.graph.node.\(task.nodeId)")
    }

    private var launchInputsSection: some View {
        let fields = launchFields ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("LAUNCH INPUTS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)

            if isLoadingDAG && workflowDAG == nil {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text("Loading launch fields...")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            } else if fields.isEmpty {
                Text("No dynamic input fields were detected. Running this workflow will require confirmation.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            } else {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(field.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                            Text(WorkflowLaunchInputKind(field.type).label)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .themedPill(cornerRadius: 4)
                            if field.required {
                                Text("required")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Theme.warning)
                            }
                        }
                        launchInputControl(for: field)
                        if let validationError = launchValidationErrors[field.key] {
                            Text(validationError)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.danger)
                                .accessibilityIdentifier("workflows.launchFieldError.\(field.key)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func launchInputControl(for field: WorkflowLaunchField) -> some View {
        switch WorkflowLaunchInputKind(field.type) {
        case .boolean:
            Toggle(
                isOn: Binding(
                    get: { booleanLaunchInputValue(for: field) },
                    set: {
                        launchInputs[field.key] = $0 ? "true" : "false"
                        refreshLaunchValidationErrors()
                    }
                )
            ) {
                Text(booleanLaunchInputValue(for: field) ? "true" : "false")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .accessibilityIdentifier("workflows.launchField.\(field.key)")
        case .object, .array, .json:
            ZStack(alignment: .topLeading) {
                if launchTextBinding(for: field).wrappedValue.isEmpty {
                    Text(jsonPlaceholder(for: field))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                }
                TextEditor(text: launchTextBinding(for: field))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(4)
            }
            .frame(minHeight: 86)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .accessibilityIdentifier("workflows.launchField.\(field.key)")
        case .number:
            TextField(
                field.defaultValue ?? "Enter \(field.name)...",
                text: launchTextBinding(for: field)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .accessibilityIdentifier("workflows.launchField.\(field.key)")
        case .string:
            TextField(
                field.defaultValue ?? "Enter \(field.name)...",
                text: launchTextBinding(for: field)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .accessibilityIdentifier("workflows.launchField.\(field.key)")
        }
    }

    private func launchTextBinding(for field: WorkflowLaunchField) -> Binding<String> {
        Binding(
            get: { launchInputs[field.key] ?? "" },
            set: {
                launchInputs[field.key] = $0
                refreshLaunchValidationErrors()
            }
        )
    }

    private func booleanLaunchInputValue(for field: WorkflowLaunchField) -> Bool {
        let rawValue = rawLaunchInputValue(for: field)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch rawValue {
        case "true", "1", "yes", "on":
            return true
        default:
            return false
        }
    }

    private func rawLaunchInputValue(for field: WorkflowLaunchField) -> String? {
        if let value = launchInputs[field.key] {
            return value
        }
        return field.defaultValue
    }

    private func jsonPlaceholder(for field: WorkflowLaunchField) -> String {
        switch WorkflowLaunchInputKind(field.type) {
        case .array:
            return "[]"
        case .object:
            return "{}"
        case .json:
            return "JSON value"
        case .string, .number, .boolean:
            return field.defaultValue ?? "Enter \(field.name)..."
        }
    }

    // MARK: - Runs Pane

    private var runsPane: some View {
        VStack(spacing: 0) {
            if isLoadingRuns {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading runs...")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workflowRuns.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)
                    Text("No runs yet")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                    Text("Launch this workflow from the Launch tab")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Runs header
                HStack {
                    Text("\(workflowRuns.count) run\(workflowRuns.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button(action: { Task { await loadWorkflowRuns() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .border(Theme.border, edges: [.bottom])

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(workflowRuns) { run in
                            Button(action: { onNavigate?(.runInspect(runId: run.runId, workflowName: run.workflowName)) }) {
                                HStack(spacing: 10) {
                                    // Status icon
                                    Circle()
                                        .fill(runStatusColor(run.status))
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(run.runId.prefix(12) + "...")
                                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                .foregroundColor(Theme.textPrimary)
                                                .lineLimit(1)

                                            Text(run.status.label)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(runStatusColor(run.status))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(runStatusColor(run.status).opacity(0.15))
                                                .cornerRadius(4)
                                        }

                                        HStack(spacing: 8) {
                                            if let started = run.startedAt {
                                                Label(Self.relativeTime(started), systemImage: "clock")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Theme.textTertiary)
                                            }
                                            if !run.elapsedString.isEmpty {
                                                Text(run.elapsedString)
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Theme.textTertiary)
                                            }
                                            if let summary = run.summary {
                                                let total = summary["total"] ?? 0
                                                let finished = summary["finished"] ?? 0
                                                if total > 0 {
                                                    Text("\(finished)/\(total) tasks")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(Theme.textTertiary)
                                                }
                                            }
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workflows.run.\(run.runId)")
                            Divider().background(Theme.border)
                        }
                    }
                }
                .refreshable { await loadWorkflowRuns() }
            }
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    // MARK: - Actions

    private func selectWorkflow(_ workflow: Workflow) {
        if hasAnyChanges {
            pendingWorkflow = workflow
            showUnsavedAlert = true
            return
        }
        applySelection(workflow)
    }

    private func applySelection(_ workflow: Workflow) {
        selectedWorkflow = workflow
        launchFields = nil
        workflowDAG = nil
        isLoadingDAG = true
        dagLoadError = nil
        showDAGDetails = false
        launchInputs = [:]
        launchValidationErrors = [:]
        showRunConfirmation = false
        doctorIssues = []
        isRunningDoctor = false
        workflowSource = ""
        originalWorkflowSource = ""
        importedFiles = []
        selectedFileIndex = nil
        saveError = nil
        workflowRuns = []
        isLoadingRuns = false
        tab = .source

        Task {
            await loadDAG(workflow)
            await loadWorkflowSource(workflow)
            await loadWorkflowRuns()
        }
    }

    private func loadWorkflowSource(_ workflow: Workflow) async {
        guard let workflowPath = workflow.filePath else { return }
        do {
            let source = try await smithers.readWorkflowSource(workflowPath)
            guard selectedWorkflow?.id == workflow.id else { return }
            workflowSource = source
            originalWorkflowSource = source

            // Parse imports and load their sources
            let imports = smithers.parseWorkflowImports(source)
            var files: [ImportedFile] = []

            for (name, path) in imports.components {
                if let src = try? await smithers.readWorkflowSource(path) {
                    files.append(ImportedFile(id: path, name: name, kind: .component, source: src, originalSource: src))
                }
            }
            for (name, path) in imports.prompts {
                if let src = try? await smithers.readWorkflowSource(path) {
                    files.append(ImportedFile(id: path, name: name, kind: .prompt, source: src, originalSource: src))
                }
            }

            guard selectedWorkflow?.id == workflow.id else { return }
            importedFiles = files
            if !files.isEmpty {
                selectedFileIndex = 0
            }
        } catch {
            // Source not available — that's ok, detail still works
        }
    }

    private func saveAll() async {
        defer { isSaving = false }
        guard let workflow = selectedWorkflow, let workflowPath = workflow.filePath else { return }
        saveError = nil
        do {
            // Save workflow source
            if workflowSource != originalWorkflowSource {
                try await smithers.saveWorkflowSource(workflowPath, source: workflowSource)
                originalWorkflowSource = workflowSource
            }
            // Save modified imported files
            let filesToSave = importedFiles.filter(\.hasChanges)
            var savedSourceByID: [String: String] = [:]
            for file in filesToSave {
                try await smithers.saveWorkflowSource(file.id, source: file.source)
                savedSourceByID[file.id] = file.source
            }
            if !savedSourceByID.isEmpty {
                importedFiles = importedFiles.map { file in
                    guard let savedSource = savedSourceByID[file.id] else { return file }
                    return ImportedFile(
                        id: file.id,
                        name: file.name,
                        kind: file.kind,
                        source: file.source,
                        originalSource: savedSource
                    )
                }
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func loadWorkflows() async {
        isLoading = true
        error = nil
        do {
            let loaded = try await smithers.listWorkflows()
            workflows = loaded
            await refreshLastRunStatus(loaded)

            if let selectedID = selectedWorkflow?.id,
               let updatedSelection = loaded.first(where: { $0.id == selectedID }) {
                selectedWorkflow = updatedSelection
            } else if selectedWorkflow != nil {
                selectedWorkflow = nil
                launchFields = nil
                workflowDAG = nil
                isLoadingDAG = false
                dagLoadError = nil
                launchInputs = [:]
                launchValidationErrors = [:]
                doctorIssues = []
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func loadDAG(_ workflow: Workflow) async {
        isLoadingDAG = true
        dagLoadError = nil
        defer {
            if selectedWorkflow?.id == workflow.id {
                isLoadingDAG = false
            }
        }
        do {
            let dag = try await smithers.getWorkflowDAG(workflow)
            guard selectedWorkflow?.id == workflow.id else { return }
            workflowDAG = dag
            launchFields = dag.launchFields
            applyLaunchDefaultsIfNeeded()
            refreshLaunchValidationErrors()
        } catch {
            guard selectedWorkflow?.id == workflow.id else { return }
            workflowDAG = nil
            launchFields = []
            launchValidationErrors = [:]
            dagLoadError = error.localizedDescription
        }
    }

    private func handleRunTapped() async {
        guard selectedWorkflow != nil else { return }
        guard !isLaunching else { return }
        if isLoadingDAG && workflowDAG == nil {
            return
        }
        refreshLaunchValidationErrors()
        guard launchValidationErrors.isEmpty else {
            return
        }

        // Mirror TUI fallback semantics: no launch fields (or fetch failure) routes
        // through a confirmation step, while populated forms run directly.
        if launchFields?.isEmpty ?? true {
            showRunConfirmation = true
            return
        }

        await launchWorkflow()
    }

    private func loadWorkflowRuns() async {
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        guard let workflow = selectedWorkflow else { return }
        do {
            let allRuns = try await smithers.listRuns()
            guard selectedWorkflow?.id == workflow.id else { return }
            // Filter to runs matching this workflow by path or name
            workflowRuns = allRuns.filter { run in
                if let runPath = run.workflowPath, let wfPath = workflow.filePath {
                    return runPath == wfPath
                }
                if let runName = run.workflowName {
                    return runName == workflow.name || runName == workflow.id
                }
                return false
            }
            .sorted { ($0.startedAtMs ?? 0) > ($1.startedAtMs ?? 0) }
        } catch {
            // Silently fail — runs are supplementary info
            workflowRuns = []
        }
    }

    private func launchWorkflow() async {
        guard let workflow = selectedWorkflow else { return }
        guard !isLaunching else { return }
        refreshLaunchValidationErrors()
        guard launchValidationErrors.isEmpty else {
            return
        }
        isLaunching = true
        runErrorByWorkflowID[workflow.id] = nil
        do {
            let inputs = try buildLaunchInputs()
            let run = try await smithers.runWorkflow(workflow, inputs: inputs)
            lastRunStatusByWorkflowID[workflow.id] = .running
            launchInputs = [:]
            applyLaunchDefaults(overwritingExistingValues: true)
            onRunStarted?(run.runId, workflow.name)
            onNavigate?(.liveRun(runId: run.runId, nodeId: nil))
        } catch let error as WorkflowLaunchInputError {
            runErrorByWorkflowID[workflow.id] = error.localizedDescription
        } catch {
            runErrorByWorkflowID[workflow.id] = error.localizedDescription
            lastRunStatusByWorkflowID[workflow.id] = .failed
        }
        isLaunching = false
    }

    private func refreshLaunchValidationErrors() {
        launchValidationErrors = currentLaunchValidationErrors()
    }

    private func currentLaunchValidationErrors() -> [String: String] {
        guard let fields = launchFields, !fields.isEmpty else { return [:] }

        return fields.reduce(into: [:]) { errors, field in
            if let error = launchValidationError(for: field) {
                errors[field.key] = error.localizedDescription
            }
        }
    }

    private func launchValidationError(for field: WorkflowLaunchField) -> WorkflowLaunchInputError? {
        let kind = WorkflowLaunchInputKind(field.type)
        let rawValue = rawLaunchInputValue(for: field)
        let trimmed = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if field.required, kind != .boolean, trimmed.isEmpty {
            return .missingRequired(field: field.name)
        }

        guard !trimmed.isEmpty else {
            return nil
        }

        switch kind {
        case .number:
            guard let number = Double(trimmed), number.isFinite else {
                return .invalidNumber(field: field.name, value: rawValue ?? "")
            }
            return nil
        case .object, .array, .json:
            do {
                _ = try decodeLaunchJSON(trimmed, for: field, kind: kind)
                return nil
            } catch let error as WorkflowLaunchInputError {
                return error
            } catch {
                return .invalidJSON(field: field.name, expected: kind.expectedDescription)
            }
        case .boolean, .string:
            return nil
        }
    }

    private func buildLaunchInputs() throws -> [String: JSONValue] {
        guard let fields = launchFields, !fields.isEmpty else { return [:] }
        var inputs: [String: JSONValue] = [:]

        for field in fields {
            let kind = WorkflowLaunchInputKind(field.type)
            switch kind {
            case .string:
                guard let rawValue = rawLaunchInputValue(for: field) else {
                    if field.required { throw WorkflowLaunchInputError.missingRequired(field: field.name) }
                    continue
                }
                if field.required && rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw WorkflowLaunchInputError.missingRequired(field: field.name)
                }
                inputs[field.key] = .string(rawValue)
            case .number:
                guard let rawValue = rawLaunchInputValue(for: field) else {
                    if field.required { throw WorkflowLaunchInputError.missingRequired(field: field.name) }
                    continue
                }
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    if field.required { throw WorkflowLaunchInputError.missingRequired(field: field.name) }
                    continue
                }
                guard let number = Double(trimmed), number.isFinite else {
                    throw WorkflowLaunchInputError.invalidNumber(field: field.name, value: rawValue)
                }
                inputs[field.key] = .number(number)
            case .boolean:
                if !field.required, rawLaunchInputValue(for: field) == nil {
                    continue
                }
                inputs[field.key] = .bool(booleanLaunchInputValue(for: field))
            case .object, .array, .json:
                guard let rawValue = rawLaunchInputValue(for: field) else {
                    if field.required { throw WorkflowLaunchInputError.missingRequired(field: field.name) }
                    continue
                }
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    if field.required { throw WorkflowLaunchInputError.missingRequired(field: field.name) }
                    continue
                }
                let value = try decodeLaunchJSON(trimmed, for: field, kind: kind)
                inputs[field.key] = value
            }
        }

        return inputs
    }

    private func decodeLaunchJSON(
        _ rawValue: String,
        for field: WorkflowLaunchField,
        kind: WorkflowLaunchInputKind
    ) throws -> JSONValue {
        let data = Data(rawValue.utf8)
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw WorkflowLaunchInputError.invalidJSON(field: field.name, expected: kind.expectedDescription)
        }

        switch (kind, value) {
        case (.object, .object), (.array, .array), (.json, _):
            return value
        default:
            throw WorkflowLaunchInputError.invalidJSON(field: field.name, expected: kind.expectedDescription)
        }
    }

    private func runDoctorDiagnostics() async {
        guard let workflow = selectedWorkflow else { return }
        isRunningDoctor = true
        doctorIssues = await smithers.runWorkflowDoctor(workflow)
        guard selectedWorkflow?.id == workflow.id else {
            isRunningDoctor = false
            return
        }
        isRunningDoctor = false
    }

    private func applyLaunchDefaultsIfNeeded() {
        applyLaunchDefaults(overwritingExistingValues: false)
    }

    private func applyLaunchDefaults(overwritingExistingValues: Bool) {
        guard let fields = launchFields, !fields.isEmpty else {
            launchValidationErrors = [:]
            return
        }
        for field in fields {
            guard let defaultValue = field.defaultValue else { continue }
            if overwritingExistingValues || launchInputs[field.key] == nil || launchInputs[field.key]?.isEmpty == true {
                launchInputs[field.key] = defaultValue
            }
        }
        refreshLaunchValidationErrors()
    }

    private func refreshLastRunStatus(_ workflows: [Workflow]) async {
        guard !workflows.isEmpty else {
            lastRunStatusByWorkflowID = [:]
            return
        }

        do {
            let runs = try await smithers.listRuns()
            let idByPath: [String: String] = workflows.reduce(into: [:]) { partial, workflow in
                guard let path = normalizePath(workflow.filePath) else { return }
                partial[path] = workflow.id
                partial[(path as NSString).lastPathComponent] = workflow.id
            }

            var latestByWorkflowID: [String: (status: RunStatus, timestamp: Int64)] = [:]
            for run in runs {
                guard let workflowID = workflowIDForRun(run, workflows: workflows, idByPath: idByPath) else {
                    continue
                }
                let timestamp = run.startedAtMs ?? run.finishedAtMs ?? 0
                if let previous = latestByWorkflowID[workflowID], previous.timestamp >= timestamp {
                    continue
                }
                latestByWorkflowID[workflowID] = (run.status, timestamp)
            }

            lastRunStatusByWorkflowID = latestByWorkflowID.mapValues(\.status)
        } catch {
            // Keep existing badges if run listing isn't available in this environment.
        }
    }

    private func workflowIDForRun(
        _ run: RunSummary,
        workflows: [Workflow],
        idByPath: [String: String]
    ) -> String? {
        if let workflowPath = normalizePath(run.workflowPath),
           let id = idByPath[workflowPath] {
            return id
        }
        if let workflowPath = normalizePath(run.workflowPath) {
            let base = (workflowPath as NSString).lastPathComponent
            if let id = idByPath[base] {
                return id
            }
        }

        if let workflowName = run.workflowName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workflowName.isEmpty,
           let match = workflows.first(where: { $0.name.caseInsensitiveCompare(workflowName) == .orderedSame }) {
            return match.id
        }

        return nil
    }

    private func normalizePath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("./") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    private func workflowStatusColor(_ status: WorkflowStatus) -> Color {
        switch status {
        case .active: return Theme.success
        case .hot: return Theme.warning
        case .draft: return Theme.info
        case .archived, .unknown: return Theme.textTertiary
        }
    }

    private func runStatusBadgeLabel(_ status: RunStatus) -> String {
        status.label
    }

    private func runStatusColor(_ status: RunStatus) -> Color {
        switch status {
        case .running: return Theme.accent
        case .waitingApproval: return Theme.warning
        case .finished: return Theme.success
        case .failed: return Theme.danger
        case .cancelled, .unknown: return Theme.textTertiary
        }
    }

    private func runStatusIcon(_ status: RunStatus) -> String {
        switch status {
        case .running: return "play.circle.fill"
        case .waitingApproval: return "checkmark.shield.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func doctorIssueIcon(_ severity: String) -> String {
        switch severity.lowercased() {
        case "ok": return "checkmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "error": return "xmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    private func doctorIssueColor(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "ok": return Theme.success
        case "warning": return Theme.warning
        case "error": return Theme.danger
        default: return Theme.textTertiary
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
