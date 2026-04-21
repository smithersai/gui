import SwiftUI
import WebKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private struct RunSnapshotsSelection: Identifiable, Equatable {
    let runId: String
    let workflowName: String?

    var id: String { runId }
}

private struct SnapshotsRouteView: View {
    @ObservedObject var smithers: SmithersClient
    var onOpenRunSnapshots: (RunSummary) -> Void

    @State private var runs: [RunSummary] = []
    @State private var selectedRunId: String?
    @State private var isLoading = true
    @State private var error: String?

    private var sortedRuns: [RunSummary] {
        runs.sortedByStartedAtDescending()
    }

    private var selectedRun: RunSummary? {
        if let selectedRunId,
           let selected = sortedRuns.first(where: { $0.runId == selectedRunId }) {
            return selected
        }
        return sortedRuns.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Theme.surface1)
        .task { await loadRuns() }
        .accessibilityIdentifier("view.snapshots")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Timeline / Snapshots")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("Choose a run to inspect snapshots.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }

            Button {
                Task { await loadRuns() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("Refresh")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("snapshots.refresh")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .border(Theme.border, edges: [.bottom])
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading runs...")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.warning)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await loadRuns() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("snapshots.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else if sortedRuns.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.textTertiary)
                Text("No runs found")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                Text("Run a workflow first, then open snapshots.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                runList
                    .frame(width: 340)
                    .background(Theme.surface2)

                Divider().background(Theme.border)

                runDetail
            }
        }
    }

    private var runList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(sortedRuns) { run in
                    let isSelected = run.runId == selectedRun?.runId
                    Button {
                        selectedRunId = run.runId
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(run.workflowName ?? run.runId)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text(run.status.label)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(statusColor(run.status))
                            }

                            Text(run.runId)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .lineLimit(1)

                            if let startedAtMs = run.startedAtMs {
                                Text(runInspectorRelativeDate(startedAtMs))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 8, defaultFill: Theme.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("snapshots.run.\(runInspectorSafeID(run.runId))")
                }
            }
            .padding(12)
        }
        .refreshable { await loadRuns() }
    }

    private var runDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedRun {
                Text(selectedRun.workflowName ?? "Run \(String(selectedRun.runId.prefix(8)))")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                detailRow("Run ID", selectedRun.runId)
                detailRow("Status", selectedRun.status.label)
                detailRow("Started", selectedRun.startedAtMs.map(runInspectorShortDate) ?? "-")
                detailRow("Elapsed", selectedRun.elapsedString.isEmpty ? "-" : selectedRun.elapsedString)

                Divider().background(Theme.border)

                Text("Open Timeline")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                Text("Open the snapshots viewer for this run to inspect timeline frames, then fork or replay.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)

                Button {
                    onOpenRunSnapshots(selectedRun)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .bold))
                        Text("Open Snapshots")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.inputBg)
                    .cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("snapshots.open")

                Spacer(minLength: 0)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select a run")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func statusColor(_ status: RunStatus) -> Color {
        switch status {
        case .running:
            return Theme.info
        case .waitingApproval:
            return Theme.warning
        case .finished:
            return Theme.success
        case .failed, .cancelled:
            return Theme.danger
        case .stale, .orphaned:
            return Theme.warning
        case .unknown:
            return Theme.textTertiary
        }
    }

    private func loadRuns() async {
        isLoading = true
        error = nil

        do {
            let fetched = try await smithers.listRuns()
            runs = fetched

            let sorted = fetched.sortedByStartedAtDescending()
            let availableRunIDs = Set(sorted.map(\.runId))
            if let selectedRunId, availableRunIDs.contains(selectedRunId) {
                self.selectedRunId = selectedRunId
            } else {
                self.selectedRunId = sorted.first?.runId
            }
        } catch {
            runs = []
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

struct SettingsView: View {
    @AppStorage(AppPreferenceKeys.vimModeEnabled) private var vimModeEnabled = false
    @AppStorage(AppPreferenceKeys.developerToolsEnabled) private var developerToolsEnabled = false
    @AppStorage(AppPreferenceKeys.guiControlSidebarEnabled) private var guiControlSidebarEnabled = false
    @AppStorage(AppPreferenceKeys.smithersFeatureEnabled) private var smithersFeatureEnabled = false
    @AppStorage(AppPreferenceKeys.vcsFeatureEnabled) private var vcsFeatureEnabled = false
    @AppStorage(AppPreferenceKeys.externalAgentUnsafeFlagsEnabled) private var externalAgentUnsafeFlagsEnabled = false
    @AppStorage(AppPreferenceKeys.browserSearchEngine) private var browserSearchEngine = BrowserSearchEngine.duckDuckGo.rawValue
    @StateObject private var shortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var neovimPath: String? = NeovimDetector.executablePath()

    private var neovimAvailable: Bool {
        neovimPath != nil
    }

    private var neovimToggle: Binding<Bool> {
        Binding(
            get: { vimModeEnabled && neovimAvailable },
            set: { enabled in
                vimModeEnabled = enabled && neovimAvailable
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    developerToolsSection
                    operatorFeatureSection
                    smithersFeatureSection
                    vcsFeatureSection
                    externalAgentSafetySection
                    browserSearchSection
                    neovimSection
                    shortcutsSection
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surface1)
        .onAppear {
            refreshNeovimPath()
        }
        .accessibilityIdentifier("settings.root")
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    private var developerToolsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Developer tools")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Show the developer debug panel and related diagnostics.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $developerToolsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.developerTools.toggle")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.developerTools.section")
    }

    private var operatorFeatureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Smithers operator")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Show the Smithers Operator feature in the right sidebar.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $guiControlSidebarEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.guiControlSidebar.toggle")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.guiControlSidebar.section")
    }

    private var smithersFeatureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Smithers")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Show the Smithers navigation section in the left sidebar.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $smithersFeatureEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.smithersFeature.toggle")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.smithersFeature.section")
    }

    private var vcsFeatureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("VCS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Show the VCS navigation section in the left sidebar.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $vcsFeatureEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.vcsFeature.toggle")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.vcsFeature.section")
    }

    private var neovimSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vim mode")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Open files in Neovim instead of the built-in editor.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: neovimToggle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!neovimAvailable)
                    .accessibilityIdentifier("settings.neovim.toggle")
            }

            Divider().background(Theme.border)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(neovimAvailable ? "Detected" : "Not detected")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(neovimAvailable ? Theme.success : Theme.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((neovimAvailable ? Theme.success : Theme.warning).opacity(0.14))
                    .cornerRadius(5)

                Text(neovimPath ?? "Install nvim or add it to PATH.")
                    .font(.system(size: 11, design: neovimAvailable ? .monospaced : .default))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(2)

                Spacer()

                Button("Refresh") {
                    refreshNeovimPath()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("settings.neovim.refresh")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.neovim.section")
    }

    private var externalAgentSafetySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.warning)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("External agent unsafe flags")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Opt in to append --dangerously-skip-permissions / --yolo when launching external agent CLIs.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $externalAgentUnsafeFlagsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.externalAgentUnsafeFlags.toggle")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.externalAgentUnsafeFlags.section")
    }

    private var browserSearchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Browser search engine")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Choose the search fallback used by browser surfaces when the address is plain text.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Picker("Search engine", selection: $browserSearchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.label).tag(engine.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityIdentifier("settings.browserSearchEngine.picker")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.browserSearchEngine.section")
    }

    private var shortcutsSection: some View {
        let _ = shortcutSettingsObserver.revision
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard shortcuts")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Rebind app shortcuts or manage them in settings.json.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Button("Open settings.json") {
                    openShortcutSettingsFile()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("settings.shortcuts.openSettingsFile")
            }

            Divider().background(Theme.border)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutSettingsRow(action: action)
                    if action != ShortcutAction.allCases.last {
                        Divider().background(Theme.border.opacity(0.6))
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.shortcuts.section")
    }

    private func refreshNeovimPath() {
        let detectedPath = NeovimDetector.executablePath()
        neovimPath = detectedPath
        if detectedPath == nil {
            vimModeEnabled = false
        }
    }

    private func openShortcutSettingsFile() {
        let fileURL = KeyboardShortcutSettings.settingsFileURLForEditing()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let template = """
            {
              "shortcuts": {
              }
            }
            """
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(fileURL)
    }
}

#if os(macOS)
private struct ShortcutSettingsRow: View {
    let action: ShortcutAction
    @State private var shortcut: StoredShortcut

    init(action: ShortcutAction) {
        self.action = action
        _shortcut = State(initialValue: KeyboardShortcutSettings.current(for: action))
    }

    private var managedByFile: Bool {
        KeyboardShortcutSettings.isManagedBySettingsFile(action)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if let subtitle = KeyboardShortcutSettings.settingsFileManagedSubtitle(for: action) {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            Spacer(minLength: 16)

            KeyboardShortcutRecorder(
                shortcut: $shortcut,
                displayString: { action.displayedShortcutString(for: $0) },
                allowsModifierlessShortcut: action.isPrefixOnly,
                isDisabled: managedByFile
            )
            .frame(width: 150, height: 24)

            Button("Reset") {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(managedByFile ? Theme.textTertiary : Theme.accent)
            .disabled(managedByFile)
        }
        .padding(.vertical, 9)
        .onChange(of: shortcut) { _, newValue in
            KeyboardShortcutSettings.setShortcut(newValue, for: action)
        }
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
            let latest = KeyboardShortcutSettings.current(for: action)
            if latest != shortcut {
                shortcut = latest
            }
        }
        .accessibilityIdentifier("settings.shortcuts.\(action.rawValue)")
    }
}
#endif

struct ContentView: View {
    @StateObject private var store: SessionStore
    @StateObject private var smithers: SmithersClient
    @StateObject private var fileSearchIndex: WorkspaceFileSearchIndex

    init(workspacePath: String? = nil) {
        let resolved = Smithers.CWD.resolve(workspacePath)
        _store = StateObject(wrappedValue: SessionStore(workingDirectory: resolved))
        _smithers = StateObject(wrappedValue: SmithersClient(cwd: resolved))
        _fileSearchIndex = StateObject(wrappedValue: WorkspaceFileSearchIndex(rootPath: resolved))
    }

    @AppStorage(AppPreferenceKeys.developerToolsEnabled) private var developerToolsEnabled = false
    @AppStorage(AppPreferenceKeys.guiControlSidebarEnabled) private var guiControlSidebarEnabled = false
    @AppStorage(AppPreferenceKeys.smithersFeatureEnabled) private var smithersFeatureEnabled = false
    @State private var destination: NavDestination = .dashboard
    @State private var navHistory: [NavDestination] = [.dashboard]
    @State private var navHistoryIndex: Int = 0
    @State private var isNavigatingThroughHistory = false
    @State private var navigationSplitVisibility: NavigationSplitViewVisibility = .all
    @State private var runSnapshotsSelection: RunSnapshotsSelection?
    @State private var workflowsInitialID: String?
    @State private var changesInitialID: String?
    @State private var isLoading = true
    @State private var developerDebugPanelVisible = false
    @State private var guiControlSidebarExpanded = false
    @State private var pendingTerminalCloseId: String?
    @State private var pendingTerminalCloseTitle: String = ""
    @State private var commandPaletteVisible = false
    @State private var commandPaletteSeedQuery = ""
    @State private var newTabPickerVisible = false
    @State private var detailRefreshNonce = 0
    @State private var keyboardShortcutController = KeyboardShortcutController()
    @StateObject private var shortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var paletteWorkflows: [Workflow] = []
    @State private var palettePrompts: [SmithersPrompt] = []
    @State private var paletteIssues: [SmithersIssue] = []
    @State private var paletteTickets: [Ticket] = []
    @State private var paletteLandings: [Landing] = []
    @State private var paletteDataLastRefreshAt: Date = .distantPast
    @State private var paletteDataRefreshTask: Task<Void, Never>?
    @State private var quickLaunchState: QuickLaunchState?

    private struct QuickLaunchState: Identifiable {
        let id = UUID()
        let workflow: Workflow
        let prompt: String
        var phase: Phase
        enum Phase {
            case parsing
            case confirming(fields: [WorkflowLaunchField], inputs: [String: JSONValue], notes: String)
            case error(String)
        }
    }

    private var defaultDestination: NavDestination {
        .dashboard
    }

    private var activeTerminalId: String? {
        if case .terminal(let id) = destination { return id }
        return nil
    }

    private var paletteSlashCommands: [SlashCommandItem] {
        let dynamic = SlashCommandRegistry.dynamicCommands(
            workflows: paletteWorkflows,
            prompts: palettePrompts
        )
        return SlashCommandRegistry.builtInCommands + dynamic.workflows + dynamic.prompts
    }

    @ViewBuilder
    private var detailContent: some View {
        switch destination {
        case .terminal(let id):
            TerminalWorkspaceRouteView(
                store: store,
                terminalId: id,
                onClose: {
                    requestTerminalClose(id)
                }
            )
                .id(id)
                .logLifecycle("TerminalWorkspaceView")
                .accessibilityIdentifier("view.terminal")
        case .terminalCommand(let binary, let workingDirectory, let name):
            TerminalView(command: binary, workingDirectory: workingDirectory, onClose: { destination = defaultDestination })
                .id("\(binary)-\(workingDirectory)")
                .accessibilityIdentifier("view.terminalCommand.\(name)")
        case .liveRun(let runId, let nodeId):
            LiveRunView(
                smithers: smithers,
                runId: runId,
                nodeId: nodeId,
                onOpenTerminalCommand: openTerminalCommandTab,
                onOpenWorkflow: { workflowName in
                    workflowsInitialID = workflowName
                    destination = .workflows
                },
                onOpenPrompt: { destination = .prompts },
                onClose: { destination = .runs }
            )
            .id("live-run-\(runId)-\(nodeId ?? "all")")
            .logLifecycle("LiveRunView")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("view.liveRun")
        case .runInspect(let runId, let workflowName):
            RunInspectView(
                smithers: smithers,
                runId: runId,
                onOpenLiveChat: { runId, nodeId in
                    let preview = nodeId.map { "Node \($0)" } ?? "Live run"
                    openRunTab(runId: runId, title: workflowName, preview: preview, nodeId: nodeId)
                },
                onOpenTerminalCommand: openTerminalCommandTab,
                onClose: { destination = .runs }
            )
            .id("run-inspect-\(runId)")
            .logLifecycle("RunInspectView")
            .accessibilityIdentifier("view.runinspect")
        case .dashboard:
            DashboardView(
                smithers: smithers,
                onAutoPopulateActiveRuns: { runs in
                    store.autoPopulateActiveRunTabs(runs)
                },
                onOpenLiveChat: { run, nodeId in
                    openRunTab(run: run, nodeId: nodeId)
                },
                onOpenWorkflow: { workflow in
                    workflowsInitialID = workflow.id
                    destination = .workflows
                }
            )
                .logLifecycle("DashboardView")
                .accessibilityIdentifier("view.dashboard")
        case .vcsDashboard:
            VCSDashboardView(
                smithers: smithers,
                onNavigate: { destination = $0 },
                onOpenChange: { change in
                    changesInitialID = change.changeID
                    destination = .changes
                }
            )
                .logLifecycle("VCSDashboardView")
                .accessibilityIdentifier("view.vcsDashboard")
        case .agents:
            AgentsView(smithers: smithers)
                .logLifecycle("AgentsView")
                .accessibilityIdentifier("view.agents")
        case .changes:
            ChangesView(smithers: smithers, initialChangeID: changesInitialID)
                .id(changesInitialID ?? "changes-default")
                .logLifecycle("ChangesView")
                .accessibilityIdentifier("view.changes")
        case .runs:
            RunsView(
                smithers: smithers,
                onOpenLiveChat: { run, nodeId in
                    openRunTab(run: run, nodeId: nodeId)
                },
                onOpenRunInspector: { run in
                    destination = .runInspect(runId: run.runId, workflowName: run.workflowName)
                },
                onOpenRunSnapshots: { run in
                    runSnapshotsSelection = RunSnapshotsSelection(runId: run.runId, workflowName: run.workflowName)
                },
                onOpenTerminalCommand: openTerminalCommandTab
            )
            .logLifecycle("RunsView")
            .accessibilityIdentifier("view.runs")
        case .snapshots:
            SnapshotsRouteView(
                smithers: smithers,
                onOpenRunSnapshots: { run in
                    runSnapshotsSelection = RunSnapshotsSelection(runId: run.runId, workflowName: run.workflowName)
                }
            )
            .logLifecycle("SnapshotsRouteView")
            .accessibilityIdentifier("view.snapshots")
        case .workflows:
            WorkflowsView(
                smithers: smithers,
                onNavigate: { destination = $0 },
                onRunStarted: { runId, title in
                    openRunTab(runId: runId, title: title, preview: "Workflow run")
                },
                initialWorkflowID: workflowsInitialID
            )
            .id(workflowsInitialID ?? "workflows-default")
            .logLifecycle("WorkflowsView")
            .accessibilityIdentifier("view.workflows")
        case .triggers:
            TriggersView(smithers: smithers)
                .logLifecycle("TriggersView")
                .accessibilityIdentifier("view.triggers")
        case .jjhubWorkflows:
            JJHubWorkflowsView(smithers: smithers)
                .logLifecycle("JJHubWorkflowsView")
                .accessibilityIdentifier("view.jjhubWorkflows")
        case .approvals:
            ApprovalsView(smithers: smithers)
                .logLifecycle("ApprovalsView")
                .accessibilityIdentifier("view.approvals")
        case .prompts:
            PromptsView(smithers: smithers)
                .logLifecycle("PromptsView")
                .accessibilityIdentifier("view.prompts")
        case .scores:
            ScoresView(smithers: smithers)
                .logLifecycle("ScoresView")
                .accessibilityIdentifier("view.scores")
        case .memory:
            MemoryView(smithers: smithers)
                .logLifecycle("MemoryView")
                .accessibilityIdentifier("view.memory")
        case .search:
            SearchView(smithers: smithers)
                .logLifecycle("SearchView")
                .accessibilityIdentifier("view.search")
        case .sql:
            SQLBrowserView(smithers: smithers)
                .logLifecycle("SQLBrowserView")
                .accessibilityIdentifier("view.sql")
        case .landings:
            LandingsView(smithers: smithers)
                .logLifecycle("LandingsView")
                .accessibilityIdentifier("view.landings")
        case .tickets:
            TicketsView(smithers: smithers)
                .logLifecycle("TicketsView")
                .accessibilityIdentifier("view.tickets")
        case .issues:
            IssuesView(smithers: smithers)
                .logLifecycle("IssuesView")
                .accessibilityIdentifier("view.issues")
        case .workspaces:
            WorkspacesView(smithers: smithers)
                .logLifecycle("WorkspacesView")
                .accessibilityIdentifier("view.workspaces")
        case .logs:
            LogViewerView()
                .logLifecycle("LogViewerView")
                .accessibilityIdentifier("view.logs")
        case .settings:
            SettingsView()
                .logLifecycle("SettingsView")
                .accessibilityIdentifier("view.settings")
        }
    }

    var body: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Connecting to Smithers...")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.base)
            .task {
                let logStats = await AppLogger.fileWriter.stats()
                AppLogger.lifecycle.info("File logging ready", metadata: [
                    "path": logStats.fileURL.path,
                    "entries": String(logStats.entryCount),
                    "size_bytes": String(logStats.sizeBytes)
                ])
                AppLogger.lifecycle.info("App launching, checking connection")
                await smithers.checkConnection()
                AppLogger.lifecycle.info("Connection check complete", metadata: [
                    "connected": String(smithers.isConnected),
                    "cliAvailable": String(smithers.cliAvailable)
                ])
                if !UITestSupport.isEnabled {
                    AppNotifications.shared.beginRunEventMonitoring(smithers: smithers)
                }
                isLoading = false

                let environment = ProcessInfo.processInfo.environment
                if UITestSupport.isEnabled,
                   environment["SMITHERS_GUI_UITEST_OPEN_TREE_ON_LAUNCH"] == "1" {
                    destination = .liveRun(runId: "ui-run-active-001", nodeId: nil)
                }
            }
        } else {
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $navigationSplitVisibility) {
                    SidebarView(
                        store: store,
                        destination: $destination,
                        developerDebugPanelVisible: $developerDebugPanelVisible,
                        developerDebugAvailable: developerToolsEnabled,
                        onOpenNewTabPicker: { newTabPickerVisible = true },
                        versionProvider: { await smithers.getOrchestratorVersion() }
                    )
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
                } detail: {
                    ZStack(alignment: .topLeading) {
                        TerminalTabsLayer(
                            store: store,
                            activeTerminalId: activeTerminalId,
                            onRequestClose: { id in requestTerminalClose(id) }
                        )
                        .opacity(activeTerminalId != nil ? 1 : 0)
                        .allowsHitTesting(activeTerminalId != nil)
                        .accessibilityHidden(activeTerminalId == nil)

                        if activeTerminalId == nil {
                            VStack(spacing: 0) {
                                if smithersFeatureEnabled,
                                   let installed = smithers.orchestratorVersion,
                                   smithers.orchestratorVersionMeetsMinimum == false {
                                    SmithersVersionWarningBanner(installed: installed)
                                }
                                detailContent
                            }
                            .id("\(String(describing: destination)):\(detailRefreshNonce)")
                        }
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar {
                            ToolbarItemGroup(placement: .navigation) {
                                Button(action: goBack) {
                                    Image(systemName: "chevron.left")
                                }
                                .disabled(!canGoBack)
                                .help("Back (⌘[)")
                                .accessibilityIdentifier("nav.back")

                                Button(action: goForward) {
                                    Image(systemName: "chevron.right")
                                }
                                .disabled(!canGoForward)
                                .help("Forward (⌘])")
                                .accessibilityIdentifier("nav.forward")
                            }
                        }
                }
                .navigationSplitViewStyle(.balanced)
                .sheet(item: $runSnapshotsSelection) { selection in
                    RunSnapshotsSheet(
                        smithers: smithers,
                        runId: selection.runId,
                        nodeIdFilter: nil,
                        onClose: { runSnapshotsSelection = nil }
                    )
                    .frame(minWidth: 840, minHeight: 520)
                }
                .frame(minWidth: 800, minHeight: 600)
                .background(Theme.base)
                .overlay(alignment: .topLeading) {
                    hiddenShortcutButtons
                }
                .accessibilityIdentifier("app.root")
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    handleMarkdownFileDrop(providers)
                }
                .onChange(of: destination) { _, newValue in
                    AppLogger.ui.debug("Navigate to \(newValue.label)")
                    recordHistory(newValue)
                }
                .onReceive(NotificationCenter.default.publisher(for: .smithersAction)) { notification in
                    handleSmithersActionNotification(notification)
                }
                if guiControlSidebarEnabled {
                    GUIControlSidebar(
                        isExpanded: $guiControlSidebarExpanded,
                        store: store,
                        smithers: smithers,
                        destination: destination,
                        onNavigate: handleNavigation
                    )
                }

                if developerDebugPanelVisible && developerToolsEnabled {
                    DeveloperDebugPanel(
                        store: store,
                        smithers: smithers,
                        destination: destination,
                        onClose: { developerDebugPanelVisible = false },
                        onOpenLogs: { destination = .logs }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                AppToastOverlay()
            }
            .overlay {
                if commandPaletteVisible {
                    CommandPaletteView(
                        initialQuery: commandPaletteSeedQuery,
                        itemsProvider: { query in
                            commandPaletteItems(for: query)
                        },
                        onExecute: { item, query in
                            executePaletteItem(item, rawQuery: query)
                        },
                        onDismiss: {
                            commandPaletteVisible = false
                        }
                    )
                    .transition(.opacity)
                }
            }
            .overlay {
                if newTabPickerVisible {
                    NewTabPicker(
                        smithers: smithers,
                        onSelect: { selection in
                            newTabPickerVisible = false
                            handleNewTabSelection(selection)
                        },
                        onDismiss: { newTabPickerVisible = false }
                    )
                    .transition(.opacity)
                }
            }
            .overlay {
                if let state = quickLaunchState {
                    quickLaunchOverlay(state: state)
                        .transition(.opacity)
                }
            }
            .background(Theme.base)
            .onAppear {
                installKeyboardShortcutMonitor()
                fileSearchIndex.updateRootPath(store.workspaceRootPath)
                fileSearchIndex.ensureLoaded()
            }
            .onDisappear {
                keyboardShortcutController.uninstall()
                paletteDataRefreshTask?.cancel()
                paletteDataRefreshTask = nil
            }
            .confirmationDialog(
                "Terminate Terminal?",
                isPresented: terminateTerminalConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Terminate Terminal", role: .destructive) {
                    confirmTerminalClose()
                }
                Button("Cancel", role: .cancel) {
                    clearPendingTerminalClose()
                }
            } message: {
            Text("Terminate \"\(pendingTerminalCloseTitle)\"? This will stop the terminal session and close the workspace. This action cannot be undone.")
            }
        } // end else (isLoading)
    }

    @ViewBuilder
    private var hiddenShortcutButtons: some View {
        VStack(spacing: 0) {
            Button("Open Launcher") {
                openCommandPalette(prefill: "")
            }
            .appKeyboardShortcut(.commandPalette)
            .accessibilityIdentifier("shortcut.openLauncher")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Open Command Palette") {
                openCommandPalette(prefill: ">")
            }
            .appKeyboardShortcut(.commandPaletteCommandMode)
            .accessibilityIdentifier("shortcut.commandPalette")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Open Ask AI Launcher") {
                openCommandPalette(prefill: "?")
            }
            .appKeyboardShortcut(.commandPaletteAskAI)
            .accessibilityIdentifier("shortcut.askAI")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("New Terminal Workspace") {
                createNewTerminalTab()
            }
            .appKeyboardShortcut(.newTerminal)
            .accessibilityIdentifier("shortcut.newTerminal")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Reopen Closed Workspace") {
                AppNotifications.shared.post(
                    title: "Workspaces",
                    message: "Reopen closed workspace is not available yet.",
                    level: .info
                )
            }
            .appKeyboardShortcut(.reopenClosedTab)
            .accessibilityIdentifier("shortcut.reopenWorkspace")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Navigate Back") {
                goBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!canGoBack)
            .accessibilityIdentifier("shortcut.navBack")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Navigate Forward") {
                goForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!canGoForward)
            .accessibilityIdentifier("shortcut.navForward")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Previous Visible Workspace") {
                moveVisibleTab(offset: -1)
            }
            .appKeyboardShortcut(.prevSidebarTab)
            .accessibilityIdentifier("shortcut.previousWorkspace")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Next Visible Workspace") {
                moveVisibleTab(offset: 1)
            }
            .appKeyboardShortcut(.nextSidebarTab)
            .accessibilityIdentifier("shortcut.nextWorkspace")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Find in Context") {
                handleFindShortcut()
            }
            .appKeyboardShortcut(.find)
            .accessibilityIdentifier("shortcut.find")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Global Search") {
                destination = .search
            }
            .appKeyboardShortcut(.globalSearch)
            .accessibilityIdentifier("shortcut.globalSearch")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Refresh Current View") {
                refreshCurrentView()
            }
            .appKeyboardShortcut(.refreshCurrentView)
            .accessibilityIdentifier("shortcut.refresh")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Cancel Current Operation") {
                cancelCurrentOperation()
            }
            .appKeyboardShortcut(.cancelCurrentOperation)
            .accessibilityIdentifier("shortcut.cancel")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Shortcut Cheat Sheet") {
                openCommandPalette(prefill: ">shortcut")
            }
            .appKeyboardShortcut(.showShortcutCheatSheet)
            .accessibilityIdentifier("shortcut.cheatSheet")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            ForEach(1...9, id: \.self) { index in
                Button("Switch to Workspace \(index)") {
                    switchVisibleTab(at: index - 1)
                }
                .appNumberedKeyboardShortcut(.selectWorkspaceByNumber, digit: index)
                .accessibilityIdentifier("shortcut.switchWorkspace.\(index)")
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }

            if developerToolsEnabled {
                Button("Toggle Developer Debug") {
                    toggleDeveloperDebugPanel()
                }
                .appKeyboardShortcut(.toggleDeveloperDebug)
                .accessibilityIdentifier("shortcut.toggleDeveloperDebug")
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }

            if UITestSupport.isEnabled {
                ForEach(uiTestNavDestinations, id: \.label) { item in
                    Button(item.label) {
                        destination = item.destination
                    }
                    .accessibilityIdentifier("nav.\(item.label.replacingOccurrences(of: " ", with: ""))")
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                }
            }
        }
        .id(shortcutSettingsObserver.revision)
    }

    private var uiTestNavDestinations: [(label: String, destination: NavDestination)] {
        [
            ("Dashboard", .dashboard),
            ("VCSDashboard", .vcsDashboard),
            ("Agents", .agents),
            ("Changes", .changes),
            ("Runs", .runs),
            ("Snapshots", .snapshots),
            ("Workflows", .workflows),
            ("Triggers", .triggers),
            ("JJHub Workflows", .jjhubWorkflows),
            ("Approvals", .approvals),
            ("Prompts", .prompts),
            ("Scores", .scores),
            ("Memory", .memory),
            ("Search", .search),
            ("SQL Browser", .sql),
            ("Landings", .landings),
            ("Tickets", .tickets),
            ("Issues", .issues),
            ("Workspaces", .workspaces),
            ("Logs", .logs),
            ("Terminal", .terminal()),
        ]
    }

    private func installKeyboardShortcutMonitor() {
        keyboardShortcutController.install(
            onCommand: { command in
                handleKeyboardShortcutCommand(command)
            },
            focusState: {
                let window = NSApp.keyWindow
                return KeyboardShortcutFocusState(
                    textInputFocused: KeyboardShortcutController.isTextInputFocused(window: window),
                    terminalFocused: KeyboardShortcutController.isTerminalFocused(window: window),
                    paletteVisible: commandPaletteVisible
                )
            }
        )
    }

    private func handleKeyboardShortcutCommand(_ command: KeyboardShortcutCommand) {
        switch command {
        case .shortcut(let action):
            handleShortcutAction(action)
        case .numbered(let action, let digit):
            handleNumberedShortcut(action, digit: digit)
        case .palette(let action):
            executePaletteAction(action, rawQuery: "")
        }
    }

    private func handleNumberedShortcut(_ action: ShortcutAction, digit: Int) {
        switch action {
        case .selectWorkspaceByNumber:
            switchVisibleTab(at: digit - 1)
        case .selectSurfaceByNumber:
            currentTerminalWorkspace()?.focusSurface(at: digit - 1)
        default:
            break
        }
    }

    private func handleShortcutAction(_ action: ShortcutAction) {
        switch action {
        case .commandPalette:
            openCommandPalette(prefill: "")
        case .commandPaletteCommandMode:
            openCommandPalette(prefill: ">")
        case .commandPaletteAskAI:
            openCommandPalette(prefill: "?")
        case .newTerminal:
            createNewTerminalTab()
        case .reopenClosedTab:
            AppNotifications.shared.post(title: "Tabs", message: "Reopen closed tab is not available yet.", level: .info)
        case .closeCurrentTab:
            closeCurrentTab()
        case .nextSidebarTab:
            moveVisibleTab(offset: 1)
        case .prevSidebarTab:
            moveVisibleTab(offset: -1)
        case .selectWorkspaceByNumber:
            break
        case .toggleDeveloperDebug:
            toggleDeveloperDebugPanel()
        case .toggleSidebar:
            toggleSidebar()
        case .splitRight:
            if !splitFocused(axis: .horizontal, kind: .terminal) {
                createNewTerminalTab()
            }
        case .splitDown:
            if !splitFocused(axis: .vertical, kind: .terminal), developerToolsEnabled {
                toggleDeveloperDebugPanel()
            }
        case .focusLeft, .focusUp:
            currentTerminalWorkspace()?.focusAdjacentSurface(offset: -1)
        case .focusRight, .focusDown:
            currentTerminalWorkspace()?.focusAdjacentSurface(offset: 1)
        case .toggleSplitZoom:
            AppNotifications.shared.post(title: "Workspace", message: "Split zoom is not available yet.", level: .info)
        case .nextSurface:
            currentTerminalWorkspace()?.focusAdjacentSurface(offset: 1)
        case .prevSurface:
            currentTerminalWorkspace()?.focusAdjacentSurface(offset: -1)
        case .selectSurfaceByNumber:
            break
        case .renameWorkspace:
            AppNotifications.shared.post(title: "Workspace", message: "Rename from keyboard is not available yet.", level: .info)
        case .renameSurface:
            AppNotifications.shared.post(title: "Workspace", message: "Rename surface from keyboard is not available yet.", level: .info)
        case .jumpToUnread:
            jumpToLatestUnreadSurface()
        case .triggerFlash:
            SurfaceNotificationStore.shared.flashFocusedSurface()
        case .showNotifications:
            showNotificationSummary()
        case .toggleFullScreen:
            NSApp.keyWindow?.toggleFullScreen(nil)
        case .focusBrowserAddressBar:
            focusBrowserAddressBar()
        case .browserBack:
            performFocusedBrowserAction { $0.goBack() }
        case .browserForward:
            performFocusedBrowserAction { $0.goForward() }
        case .browserReload:
            if !performFocusedBrowserAction({ $0.reload() }) {
                refreshCurrentView()
            }
        case .find:
            handleFindShortcut()
        case .findNext:
            AppNotifications.shared.post(title: "Find", message: "Find next is not available in this view.", level: .info)
        case .findPrevious:
            AppNotifications.shared.post(title: "Find", message: "Find previous is not available in this view.", level: .info)
        case .hideFind:
            destination = .search
        case .useSelectionForFind:
            AppNotifications.shared.post(title: "Find", message: "Use selection for find is not available in this view.", level: .info)
        case .openBrowser:
            if !splitFocused(axis: .horizontal, kind: .browser) {
                AppNotifications.shared.post(title: "Browser", message: "Open a terminal workspace before adding a browser surface.", level: .info)
            }
        case .globalSearch:
            destination = .search
        case .refreshCurrentView:
            refreshCurrentView()
        case .cancelCurrentOperation:
            cancelCurrentOperation()
        case .showShortcutCheatSheet:
            openCommandPalette(prefill: ">shortcut")
        case .linearNavigationPrefix, .tmuxPrefix:
            break
        }
    }

    private func openCommandPalette(prefill: String) {
        commandPaletteSeedQuery = prefill
        commandPaletteVisible = true
        fileSearchIndex.updateRootPath(store.workspaceRootPath)
        fileSearchIndex.ensureLoaded()
        refreshPaletteDataIfNeeded()
    }

    private func refreshPaletteDataIfNeeded(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(paletteDataLastRefreshAt) < 30 {
            return
        }

        paletteDataLastRefreshAt = now
        paletteDataRefreshTask?.cancel()
        paletteDataRefreshTask = Task {
            async let workflowsTask = smithers.listWorkflows()
            async let promptsTask = smithers.listPrompts()
            async let issuesTask = smithers.listIssues(state: "open")
            async let ticketsTask = smithers.listTickets()
            async let landingsTask = smithers.listLandings(state: "open")

            let workflows = (try? await workflowsTask) ?? []
            let prompts = (try? await promptsTask) ?? []
            let issues = (try? await issuesTask) ?? []
            let tickets = (try? await ticketsTask) ?? []
            let landings = (try? await landingsTask) ?? []

            guard !Task.isCancelled else { return }
            paletteWorkflows = workflows
            palettePrompts = prompts
            paletteIssues = issues
            paletteTickets = tickets
            paletteLandings = landings
        }
    }

    private func commandPaletteItems(for rawQuery: String) -> [CommandPaletteItem] {
        let parsed = CommandPaletteQueryParser.parse(rawQuery)
        let tabQuery = parsed.mode == .openAnything ? parsed.searchText : ""
        let fileQuery = (parsed.mode == .openAnything || parsed.mode == .mentionFile) ? parsed.searchText : ""

        let context = CommandPaletteContext(
            destination: destination,
            sidebarTabs: store.sidebarTabs(matching: tabQuery),
            runTabs: store.runTabs,
            workflows: paletteWorkflows,
            prompts: palettePrompts,
            issues: paletteIssues,
            tickets: paletteTickets,
            landings: paletteLandings,
            slashCommands: paletteSlashCommands,
            files: fileSearchIndex.matches(for: fileQuery),
            developerToolsEnabled: developerToolsEnabled
        )

        return CommandPaletteBuilder.items(for: rawQuery, context: context)
    }

    private func executePaletteItem(_ item: CommandPaletteItem, rawQuery: String) {
        commandPaletteVisible = false
        // If the user selected a workflow item and typed trailing prompt text
        // (e.g. "implement add a /health endpoint"), route through quick-launch
        // instead of the default "type /name in chat" hint.
        if case .slashCommand(let name) = item.action,
           let cmd = paletteSlashCommands.first(where: { $0.name == name }),
           case .runWorkflow(let workflow) = cmd.action,
           let trailing = trailingPrompt(from: rawQuery, matchedTokens: [name, item.title, cmd.title] + cmd.aliases),
           !trailing.isEmpty {
            startQuickLaunch(workflow: workflow, prompt: trailing)
            return
        }
        executePaletteAction(item.action, rawQuery: rawQuery)
    }

    private func trailingPrompt(from rawQuery: String, matchedTokens: [String]) -> String? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip leading sigils like `/` or `>` the palette uses for command modes.
        let stripped: String = {
            if trimmed.hasPrefix("/") || trimmed.hasPrefix(">") {
                return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }()
        guard let firstSpace = stripped.firstIndex(of: " ") else { return nil }
        let first = String(stripped[..<firstSpace])
        let rest = stripped[firstSpace...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let lowered = first.lowercased()
        for token in matchedTokens {
            if token.lowercased() == lowered { return rest }
        }
        return nil
    }

    @ViewBuilder
    private func quickLaunchOverlay(state: QuickLaunchState) -> some View {
        switch state.phase {
        case .parsing:
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { quickLaunchState = nil }
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Parsing prompt for \(state.workflow.name)…")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(24)
                .background(Theme.surface1)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 160)
            }
        case .confirming(let fields, let inputs, let notes):
            QuickLaunchConfirmSheet(
                smithers: smithers,
                target: state.workflow,
                fields: fields,
                initialInputs: inputs,
                notes: notes,
                prompt: state.prompt,
                onLaunched: { result in
                    quickLaunchState = nil
                    destination = .liveRun(runId: result.runId, nodeId: nil)
                },
                onDismiss: { quickLaunchState = nil }
            )
        case .error(let message):
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { quickLaunchState = nil }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick-launch failed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(6)
                    HStack {
                        Spacer()
                        Button("Close") { quickLaunchState = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(16)
                .frame(maxWidth: 520)
                .background(Theme.surface1)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 160)
                .padding(.horizontal, 24)
            }
        }
    }

    private func startQuickLaunch(workflow: Workflow, prompt: String) {
        quickLaunchState = QuickLaunchState(workflow: workflow, prompt: prompt, phase: .parsing)
        let client = smithers
        Task { @MainActor in
            do {
                let result = try await client.runQuickLaunchParser(target: workflow, prompt: prompt)
                let dag = try await client.getWorkflowDAG(workflow)
                quickLaunchState = QuickLaunchState(
                    workflow: workflow,
                    prompt: prompt,
                    phase: .confirming(fields: dag.launchFields, inputs: result.inputs, notes: result.notes)
                )
            } catch {
                quickLaunchState = QuickLaunchState(
                    workflow: workflow,
                    prompt: prompt,
                    phase: .error(error.localizedDescription)
                )
            }
        }
    }

    private func executePaletteAction(_ action: CommandPaletteAction, rawQuery: String) {
        switch action {
        case .navigate(let next):
            navigateFromPalette(to: next)
        case .selectSidebarTab(let id):
            activateSidebarTab(withID: id)
        case .newTerminal:
            createNewTerminalTab()
        case .openMarkdownFilePicker:
            openMarkdownFilePicker()
        case .closeCurrentTab:
            closeCurrentTab()
        case .askAI(let query):
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                openCommandPalette(prefill: "?")
            } else {
                askMainAI(trimmed)
            }
        case .slashCommand(let name):
            executeSlashCommandFromPalette(name)
        case .openFile(let path):
            openFileFromPalette(path)
        case .globalSearch(let query):
            _ = query
            destination = .search
        case .refreshCurrentView:
            refreshCurrentView()
        case .cancelCurrentOperation:
            cancelCurrentOperation()
        case .toggleDeveloperDebug:
            toggleDeveloperDebugPanel()
        case .switchToTabIndex(let index):
            switchVisibleTab(at: index)
        case .nextVisibleTab:
            moveVisibleTab(offset: 1)
        case .previousVisibleTab:
            moveVisibleTab(offset: -1)
        case .showShortcutCheatSheet:
            openCommandPalette(prefill: ">shortcut")
        case .openTabSwitcher:
            openCommandPalette(prefill: "workspace")
        case .findTab:
            openCommandPalette(prefill: "workspace")
        case .unsupported(let message):
            AppNotifications.shared.post(
                title: "Command Palette",
                message: message,
                level: .info
            )
        }

        if !rawQuery.isEmpty {
            commandPaletteSeedQuery = ""
        }
    }

    private func navigateFromPalette(to next: NavDestination) {
        switch next {
        case .terminal(id: _):
            let terminalId = store.ensureTerminalTab()
            destination = .terminal(id: terminalId)
        default:
            handleNavigation(next)
        }
    }

    private func currentTerminalWorkspace() -> TerminalWorkspace? {
        guard case .terminal(let terminalId) = destination else { return nil }
        return store.terminalWorkspaceIfAvailable(terminalId) ?? store.ensureTerminalWorkspace(terminalId)
    }

    @discardableResult
    private func splitFocused(axis: WorkspaceSplitAxis, kind: WorkspaceSurfaceKind) -> Bool {
        guard let workspace = currentTerminalWorkspace() else { return false }
        workspace.splitFocused(axis: axis, kind: kind)
        return true
    }

    private func toggleSidebar() {
        navigationSplitVisibility = navigationSplitVisibility == .detailOnly ? .all : .detailOnly
    }

    private func jumpToLatestUnreadSurface() {
        let notifications = SurfaceNotificationStore.shared
        if let workspace = currentTerminalWorkspace(),
           let surfaceId = notifications.latestUnreadSurface(in: workspace.id.rawValue) {
            workspace.focusSurface(surfaceId)
            return
        }

        guard let surfaceId = notifications.latestUnreadSurface(),
              let workspaceId = notifications.surfaceWorkspaceIds[surfaceId]
        else {
            AppNotifications.shared.post(title: "Notifications", message: "No unread surfaces.", level: .info)
            return
        }

        destination = .terminal(id: workspaceId)
        let workspace = store.terminalWorkspaceIfAvailable(workspaceId) ?? store.ensureTerminalWorkspace(workspaceId)
        workspace.focusSurface(surfaceId)
    }

    private func showNotificationSummary() {
        let notifications = AppNotifications.shared.toasts
        if notifications.isEmpty {
            AppNotifications.shared.post(title: "Notifications", message: "No notifications.", level: .info)
        } else {
            AppNotifications.shared.post(
                title: "Notifications",
                message: "\(notifications.count) notification\(notifications.count == 1 ? "" : "s") visible.",
                level: .info
            )
        }
    }

    private func focusedBrowserSurfaceId() -> String? {
        guard let workspace = currentTerminalWorkspace(),
              let surfaceId = workspace.focusedSurfaceId,
              workspace.surfaces[surfaceId]?.kind == .browser
        else {
            return nil
        }
        return surfaceId.rawValue
    }

    @discardableResult
    private func performFocusedBrowserAction(_ action: (WKWebView) -> Void) -> Bool {
        guard let surfaceId = focusedBrowserSurfaceId() else { return false }
        action(BrowserSurfaceRegistry.shared.webView(for: surfaceId))
        return true
    }

    private func focusBrowserAddressBar() {
        guard let surfaceId = focusedBrowserSurfaceId() else { return }
        NotificationCenter.default.post(
            name: BrowserSurfaceView.focusAddressBarNotification,
            object: nil,
            userInfo: [BrowserSurfaceView.surfaceIdUserInfoKey: surfaceId]
        )
    }

    private func createNewTerminalTab() {
        let terminalId = store.addTerminalTab()
        destination = .terminal(id: terminalId)
    }

    private func handleSmithersActionNotification(_ notification: Notification) {
        guard let action = notification.userInfo?["action"] as? Smithers.Action,
              let kind = action.sessionKind
        else {
            return
        }
        openSmithersSession(kind)
    }

    private func openSmithersSession(_ kind: Smithers.Session.Kind) {
        switch kind {
        case .terminal, .chat:
            createNewTerminalTab()
        case .runInspect:
            destination = .runs
        case .workflow:
            destination = .workflows
        case .memory:
            destination = .memory
        case .dashboard:
            destination = .dashboard
        }
    }

    private func handleNewTabSelection(_ selection: NewTabSelection) {
        switch selection {
        case .terminal:
            let terminalId = store.addTerminalTab()
            destination = .terminal(id: terminalId)
        case .browser:
            let terminalId = store.addBrowserTab()
            destination = .terminal(id: terminalId)
        case .externalAgent(let target):
            let terminalId = store.launchExternalAgentTab(
                name: target.name,
                command: target.binary
            )
            destination = .terminal(id: terminalId)
        }
    }

    private func openMarkdownFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Open Markdown File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.workspaceRootPath, isDirectory: true)
        let markdownTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }
        panel.allowedContentTypes = markdownTypes.isEmpty ? [.plainText] : markdownTypes

        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }

        openMarkdownFile(url)
    }

    private func openMarkdownFile(_ url: URL) {
        guard isMarkdownFile(url) else {
            AppNotifications.shared.post(
                title: "Markdown",
                message: "Choose a .md file.",
                level: .warning
            )
            return
        }

        let normalizedPath = (url.path as NSString).standardizingPath
        let terminalId: String
        if case .terminal(let id) = destination {
            terminalId = id
        } else {
            let rawTitle = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? "Markdown" : rawTitle
            terminalId = store.addTerminalTab(title: title, workingDirectory: store.workspaceRootPath)
        }

        let workspace = store.ensureTerminalWorkspace(terminalId)
        if let existing = workspace.orderedSurfaces.first(where: {
            $0.kind == .markdown && $0.markdownFilePath == normalizedPath
        }) {
            workspace.focusSurface(existing.id)
        } else {
            workspace.addMarkdown(filePath: normalizedPath, splitAxis: .horizontal)
        }
        destination = .terminal(id: terminalId)
    }

    private func handleMarkdownFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }

                DispatchQueue.main.async {
                    openMarkdownFile(url)
                }
            }
        }

        return true
    }

    private func handleFindShortcut() {
        if destination == .search {
            return
        }
        openCommandPalette(prefill: "\(destination.label.lowercased()) ")
    }

    private func refreshCurrentView() {
        detailRefreshNonce += 1
    }

    private func cancelCurrentOperation() {
        if case .liveRun(let runId, _) = destination {
            Task { @MainActor in
                do {
                    try await smithers.cancelRun(runId)
                    AppNotifications.shared.post(
                        title: "Runs",
                        message: "Cancel requested for run \(runId).",
                        level: .info
                    )
                } catch {
                    AppNotifications.shared.post(
                        title: "Runs",
                        message: error.localizedDescription,
                        level: .warning
                    )
                }
            }
            return
        }

        AppNotifications.shared.post(
            title: "Cancel",
            message: "No cancellable operation is active.",
            level: .info
        )
    }

    private func askMainAI(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppNotifications.shared.post(
            title: "Ask AI",
            message: "Open a terminal tab with your preferred agent CLI to ask: \(trimmed)",
            level: .info
        )
    }

    private func closeCurrentTab() {
        switch destination {
        case .terminal(let terminalID):
            requestTerminalClose(terminalID)

        case .liveRun(let runId, _):
            store.removeRunTab(runId)
            destination = .runs

        case .runInspect(runId: _, workflowName: _):
            destination = .runs

        default:
            break
        }
    }

    private func switchVisibleTab(at index: Int) {
        let tabs = store.sidebarTabs(matching: "")
        guard tabs.indices.contains(index) else { return }
        activateSidebarTab(tabs[index])
    }

    private func moveVisibleTab(offset: Int) {
        let tabs = store.sidebarTabs(matching: "")
        guard !tabs.isEmpty else { return }

        let currentIndex = activeVisibleTabIndex(in: tabs) ?? 0
        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        activateSidebarTab(tabs[nextIndex])
    }

    private func activeVisibleTabIndex(in tabs: [SidebarTab]) -> Int? {
        tabs.firstIndex { tab in
            switch tab.kind {
            case .run:
                if case .liveRun(let runId, _) = destination {
                    return runId == tab.runId
                }
                return false
            case .terminal:
                if case .terminal(let terminalId) = destination {
                    return terminalId == tab.terminalId
                }
                return false
            }
        }
    }

    private func activateSidebarTab(withID tabID: String) {
        guard let tab = store.sidebarTabs(matching: "").first(where: { $0.id == tabID }) else { return }
        activateSidebarTab(tab)
    }

    private func activateSidebarTab(_ tab: SidebarTab) {
        switch tab.kind {
        case .run:
            if let runID = tab.runId {
                destination = .liveRun(runId: runID, nodeId: nil)
            }
        case .terminal:
            if let terminalID = tab.terminalId {
                destination = .terminal(id: terminalID)
            }
        }
    }

    private func executeSlashCommandFromPalette(_ name: String) {
        guard let command = paletteSlashCommands.first(where: { $0.name == name }) else {
            AppNotifications.shared.post(
                title: "Slash Command",
                message: "Command /\(name) is not currently available.",
                level: .warning
            )
            return
        }

        switch command.action {
        case .navigate(let nav):
            navigateFromPalette(to: nav)
        case .toggleDeveloperDebug:
            toggleDeveloperDebugPanel()
        case .showHelp:
            openCommandPalette(prefill: ">")
        case .quit:
            NSApplication.shared.terminate(nil)
        case .runWorkflow(_):
            destination = .workflows
            AppNotifications.shared.post(
                title: "Workflow Command",
                message: "Use /\(name) from an external agent terminal to run this workflow with arguments.",
                level: .info
            )
        case .runSmithersPrompt(_):
            destination = .prompts
            AppNotifications.shared.post(
                title: "Prompt Command",
                message: "Use /\(name) from an external agent terminal to run this prompt with arguments.",
                level: .info
            )
        }
    }

    private func openFileFromPalette(_ path: String) {
        let fileMention = "@\(path)"
        let absolutePath = absoluteWorkspacePath(for: path)
        let fileURL = URL(fileURLWithPath: absolutePath)
        if FileManager.default.fileExists(atPath: absolutePath) {
            if isMarkdownFile(fileURL) {
                openMarkdownFile(fileURL)
            } else {
                NSWorkspace.shared.open(fileURL)
            }
        } else {
            copyTextToClipboard(fileMention)
            AppNotifications.shared.post(
                title: "File Missing",
                message: "Copied \(fileMention) to clipboard instead.",
                level: .warning
            )
        }
    }

    private func absoluteWorkspacePath(for path: String) -> String {
        if path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        return ((store.workspaceRootPath as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    private func isMarkdownFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func openRunTab(run: RunSummary, nodeId: String?) {
        let previewParts = [
            run.status.label,
            nodeId.map { "Node \($0)" },
            run.elapsedString.isEmpty ? nil : run.elapsedString,
        ].compactMap { $0 }
        openRunTab(
            runId: run.runId,
            title: run.workflowName,
            preview: previewParts.joined(separator: " · "),
            nodeId: nodeId
        )
    }

    private func openRunTab(runId: String, title: String?, preview: String, nodeId: String? = nil) {
        store.addRunTab(runId: runId, title: title, preview: preview)
        destination = .liveRun(runId: runId, nodeId: nodeId)
    }

    private var terminateTerminalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingTerminalCloseId != nil },
            set: { presented in
                if !presented {
                    clearPendingTerminalClose()
                }
            }
        )
    }

    private func requestTerminalClose(_ terminalId: String) {
        pendingTerminalCloseId = terminalId
        pendingTerminalCloseTitle = store.terminalTabs.first(where: { $0.terminalId == terminalId })?.title ?? terminalId
    }

    private func confirmTerminalClose() {
        guard let terminalId = pendingTerminalCloseId else { return }
        store.removeTerminalTab(terminalId)
        if case .terminal(let activeId) = destination, activeId == terminalId {
            destination = defaultDestination
        }
        clearPendingTerminalClose()
    }

    private func clearPendingTerminalClose() {
        pendingTerminalCloseId = nil
        pendingTerminalCloseTitle = ""
    }

    private func handleNavigation(_ next: NavDestination) {
        switch next {
        case .terminalCommand(let binary, let workingDirectory, let name):
            openTerminalCommandTab(command: binary, workingDirectory: workingDirectory, name: name)
        default:
            destination = next
        }
    }

    private var canGoBack: Bool { navHistoryIndex > 0 }
    private var canGoForward: Bool { navHistoryIndex < navHistory.count - 1 }

    private func recordHistory(_ next: NavDestination) {
        if isNavigatingThroughHistory {
            isNavigatingThroughHistory = false
            return
        }
        if navHistory.indices.contains(navHistoryIndex),
           navHistory[navHistoryIndex] == next {
            return
        }
        if navHistoryIndex < navHistory.count - 1 {
            navHistory.removeSubrange((navHistoryIndex + 1)...)
        }
        navHistory.append(next)
        navHistoryIndex = navHistory.count - 1
        trimHistoryIfNeeded()
    }

    private func trimHistoryIfNeeded() {
        let cap = 50
        if navHistory.count > cap {
            let overflow = navHistory.count - cap
            navHistory.removeFirst(overflow)
            navHistoryIndex -= overflow
        }
    }

    private func goBack() {
        guard canGoBack else { return }
        navHistoryIndex -= 1
        isNavigatingThroughHistory = true
        destination = navHistory[navHistoryIndex]
    }

    private func goForward() {
        guard canGoForward else { return }
        navHistoryIndex += 1
        isNavigatingThroughHistory = true
        destination = navHistory[navHistoryIndex]
    }

    private func openTerminalCommandTab(command: String, workingDirectory: String, name: String) {
        let terminalId = store.addTerminalTab(
            title: name,
            workingDirectory: workingDirectory,
            command: SessionStore.applyDefaultAgentFlags(command)
        )
        destination = .terminal(id: terminalId)
    }

    private func toggleDeveloperDebugPanel() {
        guard developerToolsEnabled else { return }
        developerDebugPanelVisible.toggle()
        AppLogger.ui.info(
            "Developer debug panel toggled",
            metadata: ["visible": String(developerDebugPanelVisible)]
        )
    }

    private func emptyState(_ message: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(Theme.textTertiary)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface1)
    }
}

@main
struct SmithersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var workspaceManager = WorkspaceManager.shared

    var body: some Scene {
        WindowGroup {
            SmithersRootView(manager: workspaceManager)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    SmithersApp.handleOpenedURL(url, manager: workspaceManager)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }

    static func handleOpenedURL(_ url: URL, manager: WorkspaceManager) {
        if url.isFileURL {
            manager.openWorkspace(at: url)
            return
        }
        guard url.scheme == "smithers-gui" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
            manager.openWorkspace(at: URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}

struct SmithersRootView: View {
    @ObservedObject var manager: WorkspaceManager

    var body: some View {
        Group {
            if let path = manager.activeWorkspacePath {
                ContentView(workspacePath: path)
                    .id(path)
            } else {
                WelcomeView(manager: manager)
            }
        }
        .environmentObject(manager)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        AppLogger.lifecycle.info("Application did finish launching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppDelegate.relocateOffScreenWindows()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppDelegate.relocateOffScreenWindows()
        }
    }

    private static func relocateOffScreenWindows() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        // Fallback target when a window is off every connected screen. Prefer
        // the screen anchored at origin (0, 0) — NSScreen.main can point at a
        // phantom display remembered from a prior multi-monitor setup.
        let anchored = screens.first(where: { $0.frame.origin == .zero })
        guard let fallbackScreen = anchored ?? NSScreen.main else { return }
        let visibleFrame = fallbackScreen.visibleFrame
        for window in NSApp.windows {
            let frame = window.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            let onAnyScreen = screens.contains { $0.visibleFrame.intersects(frame) }
            if onAnyScreen { continue }
            let size = NSSize(
                width: min(frame.width, visibleFrame.width * 0.9),
                height: min(frame.height, visibleFrame.height * 0.9)
            )
            let origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
            AppLogger.ui.info("relocating off-screen window", metadata: [
                "from": "\(frame)",
                "to": "\(NSRect(origin: origin, size: size))"
            ])
            window.setFrame(NSRect(origin: origin, size: size), display: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                SmithersApp.handleOpenedURL(url, manager: WorkspaceManager.shared)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            AppNotifications.shared.stopRunEventMonitoring()
            GhosttyApp.shared.shutdown()
        }
        AppLogger.lifecycle.info("Application will terminate")
    }
}
