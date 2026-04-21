import Foundation
import SwiftUI
import Combine

@MainActor
class SessionStore: ObservableObject, TerminalWorkspaceChangeDelegate {
    @Published var runTabs: [RunTab] = []
    @Published var terminalTabs: [TerminalTab] = []
    @Published var terminalWorkspaces: [String: TerminalWorkspace] = [:]

    let windowID: WindowID = WindowID()
    private var workspaceWindowIds: [WorkspaceID: WindowID] = [:]
    private let workingDirectory: String
    private let userDefaults: UserDefaults
    private let app: Smithers.App
    private var sessions: [String: Smithers.Session] = [:]

    var workspaceRootPath: String { workingDirectory }

    init(
        workingDirectory: String? = nil,
        userDefaults: UserDefaults = .standard,
        app: Smithers.App? = nil
    ) {
        self.workingDirectory = Smithers.CWD.resolve(workingDirectory)
        self.userDefaults = userDefaults
        self.app = app ?? Smithers.App()
        NotificationCenter.default.addObserver(
            forName: .smithersStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFromCore() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @discardableResult
    func addRunTab(runId: String, title: String?, preview: String? = nil) -> String {
        registerWorkspace(WorkspaceID(runId))
        sessions[runId] = Smithers.Session(app: app, kind: .runInspect, workspacePath: workingDirectory, targetID: runId)
        let now = Date()
        let tab = RunTab(
            runId: runId,
            title: runTabTitle(runId: runId, title: title),
            preview: runTabPreview(preview),
            timestamp: now,
            createdAt: now
        )
        runTabs.removeAll { $0.runId == runId }
        runTabs.insert(tab, at: 0)
        return runId
    }

    func removeRunTab(_ runId: String) {
        runTabs.removeAll { $0.runId == runId }
        sessions[runId] = nil
        workspaceWindowIds[WorkspaceID(runId)] = nil
    }

    @discardableResult
    func addTerminalTab(
        title requestedTitle: String? = nil,
        workingDirectory requestedWorkingDirectory: String? = nil,
        command: String? = nil
    ) -> String {
        let workspaceID = WorkspaceID()
        let id = workspaceID.rawValue
        registerWorkspace(workspaceID)
        sessions[id] = Smithers.Session(app: app, kind: .terminal, workspacePath: self.workingDirectory, targetID: id)

        let cwd = normalizedOptionalText(requestedWorkingDirectory) ?? workingDirectory
        let rootSurfaceID = SurfaceID()
        let rootSurfaceId = rootSurfaceID.rawValue
        let socketName = TmuxController.socketName(for: cwd)
        let sessionName = TmuxController.sessionName(for: rootSurfaceId)
        let title = normalizedOptionalText(requestedTitle) ?? "Terminal \(terminalTabs.count + 1)"
        let workspace = TerminalWorkspace(
            id: workspaceID,
            windowID: windowID,
            title: title,
            workingDirectory: cwd,
            command: command,
            rootSurfaceId: rootSurfaceID,
            backend: .tmux,
            tmuxSocketName: socketName
        )
        attachTerminalWorkspaceChangeHandler(workspace)
        terminalWorkspaces[id] = workspace

        let now = Date()
        terminalTabs.insert(
            TerminalTab(
                terminalId: id,
                title: title,
                preview: command ?? workspace.displayPreview,
                timestamp: now,
                createdAt: now,
                workingDirectory: cwd,
                command: command,
                backend: .tmux,
                rootSurfaceId: rootSurfaceId,
                tmuxSocketName: socketName,
                tmuxSessionName: sessionName
            ),
            at: 0
        )
        return id
    }

    @discardableResult
    func addBrowserTab(title requestedTitle: String? = nil, urlString: String? = nil) -> String {
        let workspaceID = WorkspaceID()
        let id = workspaceID.rawValue
        registerWorkspace(workspaceID)
        let rootSurfaceID = SurfaceID()
        let title = normalizedOptionalText(requestedTitle) ?? "Browser \(terminalTabs.filter { $0.title.hasPrefix("Browser") }.count + 1)"
        let workspace = TerminalWorkspace(
            id: workspaceID,
            windowID: windowID,
            title: title,
            workingDirectory: workingDirectory,
            rootSurfaceId: rootSurfaceID,
            rootKind: .browser,
            browserURLString: urlString,
            backend: .tmux,
            tmuxSocketName: nil
        )
        attachTerminalWorkspaceChangeHandler(workspace)
        terminalWorkspaces[id] = workspace
        let now = Date()
        terminalTabs.insert(
            TerminalTab(
                terminalId: id,
                title: title,
                preview: urlString ?? "Web browser",
                timestamp: now,
                createdAt: now,
                workingDirectory: workingDirectory,
                command: nil,
                backend: .tmux,
                rootSurfaceId: rootSurfaceID.rawValue,
                tmuxSocketName: nil,
                tmuxSessionName: nil
            ),
            at: 0
        )
        return id
    }

    @discardableResult
    func launchExternalAgentTab(name: String, command: String) -> String {
        addTerminalTab(title: name, workingDirectory: workingDirectory, command: Self.applyDefaultAgentFlags(command, userDefaults: userDefaults))
    }

    @discardableResult
    func ensureTerminalTab() -> String {
        if let id = terminalTabs.first?.terminalId {
            ensureTerminalWorkspace(id)
            return id
        }
        return addTerminalTab()
    }

    @discardableResult
    func ensureTerminalWorkspace(_ terminalId: String) -> TerminalWorkspace {
        if let workspace = terminalWorkspaces[terminalId] {
            workspace.prepareAllTerminalSessions()
            return workspace
        }
        let workspaceID = WorkspaceID(terminalId)
        registerWorkspace(workspaceID)
        let tab = terminalTabs.first { $0.terminalId == terminalId }
        let cwd = normalizedOptionalText(tab?.workingDirectory) ?? workingDirectory
        let rootSurfaceID = tab?.rootSurfaceId.map { SurfaceID($0) } ?? SurfaceID()
        let socketName = normalizedOptionalText(tab?.tmuxSocketName) ?? TmuxController.socketName(for: cwd)
        let workspace = TerminalWorkspace(
            id: workspaceID,
            windowID: workspaceWindowIds[workspaceID] ?? windowID,
            title: tab?.title ?? "Terminal",
            workingDirectory: cwd,
            command: tab?.command,
            rootSurfaceId: rootSurfaceID,
            backend: tab?.backend ?? .tmux,
            tmuxSocketName: socketName
        )
        attachTerminalWorkspaceChangeHandler(workspace)
        terminalWorkspaces[terminalId] = workspace
        syncTerminalTabMetadata(from: workspace)
        return workspace
    }

    func terminalWorkspaceIfAvailable(_ terminalId: String) -> TerminalWorkspace? {
        terminalWorkspaces[terminalId]
    }

    func renameTerminalTab(_ terminalId: String, to title: String) {
        guard let idx = terminalTabs.firstIndex(where: { $0.terminalId == terminalId }),
              let title = normalizedOptionalText(title) else { return }
        terminalTabs[idx].title = title
        terminalTabs[idx].timestamp = Date()
        terminalWorkspaces[terminalId]?.updateWorkspaceTitle(title)
    }

    func toggleTerminalPinned(_ terminalId: String) {
        guard let idx = terminalTabs.firstIndex(where: { $0.terminalId == terminalId }) else { return }
        terminalTabs[idx].isPinned.toggle()
        terminalTabs[idx].timestamp = Date()
    }

    func terminalWorkingDirectory(_ terminalId: String) -> String? {
        if let workspace = terminalWorkspaces[terminalId],
           let cwd = workspace.orderedSurfaces.first(where: { $0.kind == .terminal })?.terminalWorkingDirectory {
            return normalizedOptionalText(cwd)
        }
        return normalizedOptionalText(terminalTabs.first { $0.terminalId == terminalId }?.workingDirectory)
    }

    func terminalAttachCommand(_ terminalId: String) -> String? {
        if let workspace = terminalWorkspaces[terminalId],
           let surface = workspace.orderedSurfaces.first(where: { $0.kind == .terminal }) {
            return TmuxController.attachCommand(socketName: surface.tmuxSocketName, sessionName: surface.tmuxSessionName)
        }
        guard let tab = terminalTabs.first(where: { $0.terminalId == terminalId }) else { return nil }
        return TmuxController.attachCommand(socketName: tab.tmuxSocketName, sessionName: tab.tmuxSessionName)
    }

    func removeTerminalTab(_ terminalId: String) {
        if let workspace = terminalWorkspaces.removeValue(forKey: terminalId) {
            for surfaceId in workspace.surfaces.keys {
                SurfaceNotificationStore.shared.unregister(surfaceId: surfaceId.rawValue)
            }
            terminateTmuxSessions(in: workspace.snapshot)
        } else if let tab = terminalTabs.first(where: { $0.terminalId == terminalId }) {
            TmuxController.terminateSession(socketName: tab.tmuxSocketName, sessionName: tab.tmuxSessionName)
        }
        terminalTabs.removeAll { $0.terminalId == terminalId }
        sessions[terminalId] = nil
        workspaceWindowIds[WorkspaceID(terminalId)] = nil
        TerminalSurfaceRegistry.shared.deregister(sessionId: terminalId)
    }

    @discardableResult
    func moveSurface(_ surfaceID: SurfaceID, toPane paneID: PaneID, placement: Placement) -> Swift.Result<WorkspaceSurfacePlacementResult, WorkspaceSurfacePlacementError> {
        guard let sourceWorkspace = terminalWorkspaces.values.first(where: { $0.surfaces[surfaceID] != nil }) else {
            return .failure(.surfaceNotFound)
        }
        guard let targetWorkspace = terminalWorkspaces.values.first(where: { $0.containsPane(paneID) }) else {
            return .failure(.paneNotFound)
        }
        if sourceWorkspace === targetWorkspace {
            return sourceWorkspace.moveSurface(surfaceID, toPane: paneID, placement: placement)
        }
        switch sourceWorkspace.detachSurfaceForMove(surfaceID) {
        case .failure(let error):
            return .failure(error)
        case .success(let surface):
            return targetWorkspace.attachMovedSurface(surface, toPane: paneID, placement: placement)
        }
    }

    @discardableResult
    func reorderSurface(_ surfaceID: SurfaceID, anchor: Anchor) -> Swift.Result<WorkspaceSurfacePlacementResult, WorkspaceSurfacePlacementError> {
        guard let workspace = terminalWorkspaces.values.first(where: { $0.surfaces[surfaceID] != nil }) else {
            return .failure(.surfaceNotFound)
        }
        return workspace.reorderSurface(surfaceID, anchor: anchor)
    }

    @discardableResult
    func moveWorkspace(_ workspaceID: WorkspaceID, toWindow windowID: WindowID, placement: Placement) -> Swift.Result<WorkspaceSurfacePlacementResult, WorkspaceSurfacePlacementError> {
        let terminalId = terminalTabs.first(where: { $0.workspaceID == workspaceID })?.terminalId
        guard terminalId != nil || runTabs.contains(where: { $0.workspaceID == workspaceID }) else {
            return .failure(.workspaceNotFound)
        }
        if terminalId != nil, !reorderTerminalWorkspace(workspaceID: workspaceID, placement: placement) {
            return .failure(.invalidPlacement)
        }
        workspaceWindowIds[workspaceID] = windowID
        if let terminalId, let workspace = terminalWorkspaces[terminalId] {
            workspace.moveToWindow(windowID)
        }
        let workspace = terminalId.flatMap { terminalWorkspaces[$0] }
        let surface = workspace?.orderedSurfaces.first
        let paneID = surface.flatMap { workspace?.paneID(containing: $0.id) } ?? PaneID()
        return .success(WorkspaceSurfacePlacementResult(windowID: windowID, workspaceID: workspaceID, paneID: paneID, surfaceID: surface?.id ?? SurfaceID()))
    }

    @discardableResult
    func reorderWorkspace(_ workspaceID: WorkspaceID, anchor: Anchor) -> Swift.Result<WorkspaceSurfacePlacementResult, WorkspaceSurfacePlacementError> {
        switch anchor {
        case .beforeWorkspace(let anchorID):
            return moveWorkspace(workspaceID, toWindow: workspaceWindowIds[workspaceID] ?? windowID, placement: .beforeWorkspace(anchorID))
        case .afterWorkspace(let anchorID):
            return moveWorkspace(workspaceID, toWindow: workspaceWindowIds[workspaceID] ?? windowID, placement: .afterWorkspace(anchorID))
        case .beforeSurface, .afterSurface:
            return .failure(.invalidPlacement)
        }
    }

    func autoPopulateActiveRunTabs(_ runs: [RunSummary]) {
        for run in runs where run.status == .running || run.status == .waitingApproval {
            if let idx = runTabs.firstIndex(where: { $0.runId == run.runId }) {
                runTabs[idx].title = runTabTitle(runId: run.runId, title: run.workflowName)
                runTabs[idx].preview = runPreview(for: run)
            } else {
                addRunTab(runId: run.runId, title: run.workflowName, preview: runPreview(for: run))
            }
        }
    }

    func sidebarWorkspaces(matching searchText: String = "") -> [SidebarWorkspace] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let runItems = runTabs.map { tab in
            makeSidebarTab(id: "run:\(tab.runId)", kind: .run, runId: tab.runId, terminalId: nil, title: tab.title, preview: tab.preview, date: tab.timestamp, createdDate: tab.createdAt, now: now)
        }
        let terminalItems = terminalTabs.map { tab in
            let workspace = terminalWorkspaces[tab.terminalId]
            return makeSidebarTab(
                id: "terminal:\(tab.terminalId)",
                kind: .terminal,
                runId: nil,
                terminalId: tab.terminalId,
                title: workspace?.title ?? tab.title,
                preview: workspace?.displayPreview ?? tab.preview,
                date: tab.timestamp,
                createdDate: tab.createdAt,
                now: now,
                isPinned: tab.isPinned,
                isUnread: SurfaceNotificationStore.shared.workspaceHasIndicator(tab.terminalId),
                workingDirectory: terminalWorkingDirectory(tab.terminalId),
                sessionIdentifier: tab.tmuxSessionName ?? tab.terminalId
            )
        }
        return (runItems + terminalItems)
            .filter { item in
                needle.isEmpty ||
                    item.title.localizedCaseInsensitiveContains(needle) ||
                    item.preview.localizedCaseInsensitiveContains(needle) ||
                    (item.runId?.localizedCaseInsensitiveContains(needle) ?? false) ||
                    (item.terminalId?.localizedCaseInsensitiveContains(needle) ?? false)
            }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                return $0.sortDate > $1.sortDate
            }
    }

    func sidebarTabs(matching searchText: String = "") -> [SidebarTab] {
        sidebarWorkspaces(matching: searchText)
    }

    func terminalWorkspaceDidChange(_ workspace: TerminalWorkspace) {
        syncTerminalTabMetadata(from: workspace)
    }

    private func refreshFromCore() {
        for session in sessions.values {
            session.refresh()
        }
    }

    private func attachTerminalWorkspaceChangeHandler(_ workspace: TerminalWorkspace) {
        workspace.changeDelegate = self
        registerWorkspace(workspace.id, in: workspace.windowID)
    }

    private func registerWorkspace(_ workspaceID: WorkspaceID, in windowID: WindowID? = nil) {
        workspaceWindowIds[workspaceID] = windowID ?? workspaceWindowIds[workspaceID] ?? self.windowID
    }

    private func reorderTerminalWorkspace(workspaceID: WorkspaceID, placement: Placement) -> Bool {
        guard let currentIndex = terminalTabs.firstIndex(where: { $0.workspaceID == workspaceID }) else { return true }
        var tabs = terminalTabs
        let tab = tabs.remove(at: currentIndex)
        let insertionIndex: Int
        switch placement {
        case .start: insertionIndex = 0
        case .end: insertionIndex = tabs.count
        case .beforeWorkspace(let anchorID):
            guard let anchorIndex = tabs.firstIndex(where: { $0.workspaceID == anchorID }) else { return false }
            insertionIndex = anchorIndex
        case .afterWorkspace(let anchorID):
            guard let anchorIndex = tabs.firstIndex(where: { $0.workspaceID == anchorID }) else { return false }
            insertionIndex = tabs.index(after: anchorIndex)
        case .beforeSurface, .afterSurface:
            return false
        }
        tabs.insert(tab, at: insertionIndex)
        terminalTabs = tabs
        return true
    }

    private func syncTerminalTabMetadata(from workspace: TerminalWorkspace) {
        guard let idx = terminalTabs.firstIndex(where: { $0.workspaceID == workspace.id }) else { return }
        let firstTerminal = workspace.orderedSurfaces.first { $0.kind == .terminal }
        terminalTabs[idx].title = workspace.title
        terminalTabs[idx].preview = workspace.displayPreview
        terminalTabs[idx].workingDirectory = firstTerminal?.terminalWorkingDirectory ?? terminalTabs[idx].workingDirectory
        terminalTabs[idx].rootSurfaceId = firstTerminal?.id.rawValue ?? terminalTabs[idx].rootSurfaceId
        terminalTabs[idx].tmuxSocketName = firstTerminal?.tmuxSocketName ?? terminalTabs[idx].tmuxSocketName
        terminalTabs[idx].tmuxSessionName = firstTerminal?.tmuxSessionName ?? terminalTabs[idx].tmuxSessionName
        terminalTabs[idx].timestamp = Date()
    }

    private func terminateTmuxSessions(in snapshot: TerminalWorkspaceSnapshot) {
        for surface in snapshot.surfaces where surface.kind == .terminal {
            TmuxController.terminateSession(socketName: surface.tmuxSocketName, sessionName: surface.tmuxSessionName)
        }
    }

    nonisolated static func applyDefaultAgentFlags(_ command: String, unsafeFlagsEnabled: Bool? = nil, userDefaults: UserDefaults = .standard) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return command }
        let enabled = unsafeFlagsEnabled ?? userDefaults.bool(forKey: AppPreferenceKeys.externalAgentUnsafeFlagsEnabled)
        guard enabled else { return command }
        let executable = trimmed.split(whereSeparator: \.isWhitespace).first?.split(separator: "/").last.map(String.init) ?? trimmed
        switch executable {
        case "claude":
            return appendFlagIfMissing("--dangerously-skip-permissions", to: trimmed)
        case "gemini":
            return appendFlagIfMissing("--yolo", to: trimmed)
        case "codex":
            let base = trimmed.contains("model_reasoning_effort") ? trimmed : "\(trimmed) -c model_reasoning_effort=\"high\""
            return appendFlagIfMissing("--yolo", to: base)
        default:
            return trimmed
        }
    }

    private nonisolated static func appendFlagIfMissing(_ flag: String, to command: String) -> String {
        Set(command.split(whereSeparator: \.isWhitespace).map(String.init)).contains(flag) ? command : "\(command) \(flag)"
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runTabTitle(runId: String, title: String?) -> String {
        normalizedOptionalText(title) ?? "Run \(String(runId.prefix(8)))"
    }

    private func runTabPreview(_ preview: String?) -> String {
        normalizedOptionalText(preview) ?? "Workflow run"
    }

    private func runPreview(for run: RunSummary) -> String {
        [run.status.label, run.elapsedString.isEmpty ? nil : run.elapsedString]
            .compactMap { $0 }
            .joined(separator: " - ")
    }

    private func makeSidebarTab(
        id: String,
        kind: SidebarTabKind,
        runId: String?,
        terminalId: String?,
        title: String,
        preview: String,
        date: Date,
        createdDate: Date,
        now: Date,
        isPinned: Bool = false,
        isArchived: Bool = false,
        isUnread: Bool = false,
        workingDirectory: String? = nil,
        sessionIdentifier: String? = nil
    ) -> SidebarTab {
        SidebarTab(
            id: id,
            kind: kind,
            runId: runId,
            terminalId: terminalId,
            title: title,
            preview: preview,
            timestamp: Self.relativeTime(from: date, to: now),
            group: isPinned ? "Pinned" : Self.groupLabel(for: createdDate),
            sortDate: createdDate,
            isPinned: isPinned,
            isArchived: isArchived,
            isUnread: isUnread,
            workingDirectory: workingDirectory,
            sessionIdentifier: sessionIdentifier
        )
    }

    private static func groupLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return "Older"
    }

    private static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}
