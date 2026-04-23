import Foundation
import SwiftUI
import Combine
import CSmithersKit

#if os(macOS)
import AppKit
#endif

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
    private var externalAgentWatchers: [String: ExternalAgentSessionWatcher] = [:]
    private var stateChangedObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?
    private var pendingSaveTask: Task<Void, Never>?
    private let sessionPersistenceDisabled: Bool
    private var nativeSurfaceOperationsInFlight: Set<NativeSurfaceKey> = []

    private static let persistenceSaveDebounceNanoseconds: UInt64 = 500_000_000
    private static let nativeTerminalTERM = "xterm-256color"
    private static let nativeTerminalColorTerm = "truecolor"
    private static let persistenceEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()
    private static let persistenceDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private struct PersistedSessionEntry: Codable {
        enum Kind: String, Codable {
            case run
            case terminal
        }

        let kind: Kind
        let runTab: RunTab?
        let terminalTab: TerminalTab?

        init(runTab: RunTab) {
            kind = .run
            self.runTab = runTab
            terminalTab = nil
        }

        init(terminalTab: TerminalTab) {
            kind = .terminal
            runTab = nil
            self.terminalTab = terminalTab
        }
    }

    private struct NativeSurfaceKey: Hashable {
        let terminalId: String
        let surfaceId: SurfaceID
    }

    var workspaceRootPath: String { workingDirectory }

    init(
        workingDirectory: String? = nil,
        userDefaults: UserDefaults = .standard,
        app: Smithers.App? = nil
    ) {
        self.workingDirectory = Smithers.CWD.resolve(workingDirectory)
        self.userDefaults = userDefaults
        self.app = app ?? Smithers.App()
        self.sessionPersistenceDisabled = Self.isSessionPersistenceDisabled()
        restorePersistedSessions()
        stateChangedObserver = NotificationCenter.default.addObserver(
            forName: .smithersStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFromCore() }
        }
        #if os(macOS)
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flushPendingSave() }
        }
        #endif
    }

    deinit {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        sessions.removeAll()
        if let stateChangedObserver {
            NotificationCenter.default.removeObserver(stateChangedObserver)
        }
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
        }
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
        scheduleSave()
        return runId
    }

    func removeRunTab(_ runId: String) {
        runTabs.removeAll { $0.runId == runId }
        sessions[runId] = nil
        workspaceWindowIds[WorkspaceID(runId)] = nil
        scheduleSave()
    }

    @discardableResult
    func addTerminalTab(
        title requestedTitle: String? = nil,
        workingDirectory requestedWorkingDirectory: String? = nil,
        command: String? = nil,
        runId: String? = nil,
        hijack: TerminalWorkspaceRecord.HijackBinding? = nil
    ) -> String {
        let workspaceID = WorkspaceID()
        let id = workspaceID.rawValue
        registerWorkspace(workspaceID)
        let normalizedRunId = normalizedOptionalText(runId)
        sessions[id] = Smithers.Session(
            app: app,
            kind: terminalSessionKind(runId: normalizedRunId, hijack: hijack),
            workspacePath: self.workingDirectory,
            targetID: id
        )

        let cwd = normalizedOptionalText(requestedWorkingDirectory) ?? workingDirectory
        let rootSurfaceID = SurfaceID()
        let rootSurfaceId = rootSurfaceID.rawValue
        let title = normalizedOptionalText(requestedTitle) ?? "Terminal \(terminalTabs.count + 1)"
        let workspace = TerminalWorkspace(
            id: workspaceID,
            windowID: windowID,
            title: title,
            workingDirectory: cwd,
            command: command,
            runId: normalizedRunId,
            rootSurfaceId: rootSurfaceID,
            backend: .native,
            tmuxSocketName: nil
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
                backend: .native,
                rootSurfaceId: rootSurfaceId,
                tmuxSocketName: nil,
                tmuxSessionName: nil,
                runId: normalizedRunId,
                hijack: hijack,
                rootKind: .terminal,
                browserURLString: nil,
                snapshot: workspace.snapshot
            ),
            at: 0
        )
        scheduleSave()
        reconcileNativeTerminalSurfaces(in: workspace)

        return id
    }

    private func reconcileNativeTerminalSurfaces(in workspace: TerminalWorkspace) {
        let terminalId = workspace.id.rawValue
        for surface in workspace.orderedSurfaces
        where surface.kind == .terminal && surface.terminalBackend == .native {
            let key = NativeSurfaceKey(terminalId: terminalId, surfaceId: surface.id)
            guard !nativeSurfaceOperationsInFlight.contains(key) else { continue }

            switch workspace.nativeTerminalState(surfaceId: surface.id) {
            case .ready, .unavailable:
                continue
            case .pending:
                if let sessionId = normalizedOptionalText(surface.sessionId) {
                    verifyNativeSession(
                        key: key,
                        sessionId: sessionId
                    )
                } else {
                    createNativeSession(
                        key: key,
                        workingDirectory: surface.terminalWorkingDirectory,
                        command: surface.terminalCommand
                    )
                }
            }
        }
    }

    private func createNativeSession(
        key: NativeSurfaceKey,
        workingDirectory: String?,
        command: String?
    ) {
        nativeSurfaceOperationsInFlight.insert(key)
        terminalWorkspaces[key.terminalId]?.markNativeTerminalPending(surfaceId: key.surfaceId)

        let shell = ProcessInfo.processInfo.environment["SHELL"]
        Task { [weak self] in
            do {
                try await SessionController.shared.ensureDaemon()
                let info = try await SessionController.shared.createSession(
                    title: nil,
                    shell: shell,
                    command: command,
                    cwd: workingDirectory,
                    env: Self.nativeSessionEnvironment(),
                    rows: 24,
                    cols: 80
                )
                await MainActor.run {
                    self?.nativeSurfaceOperationsInFlight.remove(key)
                    self?.applyNativeSessionReady(key: key, sessionId: info.id)
                }
            } catch {
                await MainActor.run {
                    self?.nativeSurfaceOperationsInFlight.remove(key)
                    self?.applyNativeSessionUnavailable(
                        key: key,
                        message: "Failed to start terminal session: \(error)"
                    )
                }
            }
        }
    }

    private func verifyNativeSession(
        key: NativeSurfaceKey,
        sessionId: String
    ) {
        nativeSurfaceOperationsInFlight.insert(key)
        terminalWorkspaces[key.terminalId]?.markNativeTerminalPending(surfaceId: key.surfaceId)

        Task { [weak self] in
            do {
                try await SessionController.shared.ensureDaemon()
                _ = try await SessionController.shared.info(sessionId: PTYSessionID(sessionId))
                await MainActor.run {
                    self?.nativeSurfaceOperationsInFlight.remove(key)
                    self?.applyNativeSessionReady(key: key, sessionId: sessionId)
                }
            } catch {
                AppLogger.terminal.info(
                    "persisted native session is gone; keeping surface unavailable",
                    metadata: [
                        "sessionId": sessionId,
                        "error": "\(error)"
                    ]
                )
                let preservingSessionId: Bool = {
                    if case SessionControllerError.daemonUnavailable = error {
                        return true
                    }
                    return false
                }()
                let message = preservingSessionId
                    ? "Saved terminal session could not be verified because the session daemon is unavailable."
                    : "Saved terminal session is no longer available."
                await MainActor.run {
                    self?.nativeSurfaceOperationsInFlight.remove(key)
                    self?.applyNativeSessionUnavailable(
                        key: key,
                        message: message,
                        preservingSessionId: preservingSessionId
                    )
                }
            }
        }
    }

    private func applyNativeSessionReady(key: NativeSurfaceKey, sessionId: String) {
        if let workspace = terminalWorkspaces[key.terminalId] {
            workspace.markNativeTerminalReady(surfaceId: key.surfaceId, sessionId: sessionId)
        }
        if let idx = terminalTabs.firstIndex(where: { $0.terminalId == key.terminalId }) {
            terminalTabs[idx].sessionId = sessionId
            terminalTabs[idx].timestamp = Date()
        }
        scheduleSave()
    }

    private func applyNativeSessionUnavailable(
        key: NativeSurfaceKey,
        message: String,
        preservingSessionId: Bool = false
    ) {
        if let workspace = terminalWorkspaces[key.terminalId] {
            workspace.markNativeTerminalUnavailable(
                surfaceId: key.surfaceId,
                message: message,
                preservingSessionId: preservingSessionId
            )
        }
        if let idx = terminalTabs.firstIndex(where: { $0.terminalId == key.terminalId }) {
            if !preservingSessionId {
                terminalTabs[idx].sessionId = nil
            }
            terminalTabs[idx].timestamp = Date()
        }
        scheduleSave()
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
            backend: .native,
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
                backend: .native,
                rootSurfaceId: rootSurfaceID.rawValue,
                tmuxSocketName: nil,
                tmuxSessionName: nil,
                rootKind: .browser,
                browserURLString: urlString,
                snapshot: workspace.snapshot
            ),
            at: 0
        )
        scheduleSave()
        return id
    }

    @discardableResult
    func launchExternalAgentTab(name: String, command: String) -> String {
        let resolvedCommand = Self.applyDefaultAgentFlags(command, userDefaults: userDefaults)
        let cwd = workingDirectory
        let kind = ExternalAgentKind.detect(fromCommand: resolvedCommand)
        let excluded: Set<String> = {
            guard let kind else { return [] }
            return ExternalAgentSessionSnapshot.existingSessionIds(kind: kind, workingDirectory: cwd)
        }()
        let terminalId = addTerminalTab(title: name, workingDirectory: cwd, command: resolvedCommand)
        if let idx = terminalTabs.firstIndex(where: { $0.terminalId == terminalId }) {
            terminalTabs[idx].agentKind = kind
        }
        if let kind, kind.sessionDirectory(forWorkingDirectory: cwd) != nil {
            startAgentSessionWatcher(
                terminalId: terminalId,
                kind: kind,
                workingDirectory: cwd,
                excludedSessionIds: excluded
            )
        }
        return terminalId
    }

    @discardableResult
    func forkTerminalTab(_ terminalId: String) -> String? {
        guard let tab = terminalTabs.first(where: { $0.terminalId == terminalId }),
              let kind = tab.agentKind,
              kind.supportsResume,
              let sessionId = tab.agentSessionId,
              let command = tab.command else {
            return nil
        }
        let forked = kind.resumeCommand(sessionId: sessionId, originalCommand: command)
        return launchExternalAgentTab(name: tab.title, command: forked)
    }

    func canForkTerminalTab(_ terminalId: String) -> Bool {
        guard let tab = terminalTabs.first(where: { $0.terminalId == terminalId }),
              let kind = tab.agentKind else { return false }
        return kind.supportsResume && tab.agentSessionId != nil && tab.command != nil
    }

    private func startAgentSessionWatcher(
        terminalId: String,
        kind: ExternalAgentKind,
        workingDirectory: String,
        excludedSessionIds: Set<String>
    ) {
        externalAgentWatchers[terminalId]?.cancel()
        let configuration = ExternalAgentSessionWatcher.Configuration(
            kind: kind,
            workingDirectory: workingDirectory,
            launchTime: Date(),
            excludedSessionIds: excludedSessionIds,
            timeout: 30,
            pollInterval: 0.5
        )
        let watcher = ExternalAgentSessionWatcher(
            configuration: configuration,
            onDiscover: { [weak self] sessionId in
                self?.applyDiscoveredAgentSessionId(terminalId: terminalId, sessionId: sessionId)
            },
            onTimeout: { [weak self] in
                self?.externalAgentWatchers[terminalId] = nil
            }
        )
        externalAgentWatchers[terminalId] = watcher
        watcher.start()
    }

    private func applyDiscoveredAgentSessionId(terminalId: String, sessionId: String) {
        if let idx = terminalTabs.firstIndex(where: { $0.terminalId == terminalId }) {
            terminalTabs[idx].agentSessionId = sessionId
            terminalTabs[idx].timestamp = Date()
            scheduleSave()
        }
        externalAgentWatchers[terminalId] = nil
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
            reconcileNativeTerminalSurfaces(in: workspace)
            return workspace
        }
        let workspaceID = WorkspaceID(terminalId)
        registerWorkspace(workspaceID)
        let tab = terminalTabs.first { $0.terminalId == terminalId }
        let cwd = normalizedOptionalText(tab?.workingDirectory) ?? workingDirectory
        let rootSurfaceID = tab?.rootSurfaceId.map { SurfaceID($0) } ?? SurfaceID()
        let resolvedBackend = tab?.backend ?? .native
        let rootKind = tab?.rootKind ?? .terminal
        let socketName: String? = {
            guard resolvedBackend == .tmux else { return nil }
            return normalizedOptionalText(tab?.tmuxSocketName) ?? TmuxController.socketName(for: cwd)
        }()
        let workspace: TerminalWorkspace
        if let snapshot = tab?.snapshot {
            workspace = TerminalWorkspace(
                id: workspaceID,
                windowID: workspaceWindowIds[workspaceID] ?? windowID,
                snapshot: snapshot,
                workingDirectory: cwd,
                runId: tab?.runId,
                backend: resolvedBackend,
                tmuxSocketName: socketName,
                sessionId: tab?.sessionId
            )
        } else {
            workspace = TerminalWorkspace(
                id: workspaceID,
                windowID: workspaceWindowIds[workspaceID] ?? windowID,
                title: tab?.title ?? "Terminal",
                workingDirectory: cwd,
                command: tab?.command,
                runId: tab?.runId,
                rootSurfaceId: rootSurfaceID,
                rootKind: rootKind,
                browserURLString: tab?.browserURLString,
                backend: resolvedBackend,
                tmuxSocketName: socketName,
                sessionId: tab?.sessionId
            )
        }
        attachTerminalWorkspaceChangeHandler(workspace)
        terminalWorkspaces[terminalId] = workspace
        syncTerminalTabMetadata(from: workspace)
        reconcileNativeTerminalSurfaces(in: workspace)
        return workspace
    }

    func terminalWorkspaceIfAvailable(_ terminalId: String) -> TerminalWorkspace? {
        terminalWorkspaces[terminalId]
    }

    func terminalTab(forRunId runId: String) -> TerminalWorkspaceRecord? {
        guard let runId = normalizedOptionalText(runId) else { return nil }
        return terminalTabs.first { $0.runId == runId }
    }

    func sessionKind(forTerminalId terminalId: String) -> Smithers.Session.Kind? {
        sessions[terminalId]?.kind
    }

    func renameTerminalTab(_ terminalId: String, to title: String) {
        guard let idx = terminalTabs.firstIndex(where: { $0.terminalId == terminalId }),
              let title = normalizedOptionalText(title) else { return }
        terminalTabs[idx].title = title
        terminalTabs[idx].timestamp = Date()
        terminalWorkspaces[terminalId]?.updateWorkspaceTitle(title)
        scheduleSave()
    }

    func toggleTerminalPinned(_ terminalId: String) {
        guard let idx = terminalTabs.firstIndex(where: { $0.terminalId == terminalId }) else { return }
        terminalTabs[idx].isPinned.toggle()
        terminalTabs[idx].timestamp = Date()
        scheduleSave()
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
            if surface.terminalBackend == .native {
                guard workspace.nativeTerminalState(surfaceId: surface.id) == .ready else { return nil }
                return nativeAttachCommand(for: surface.sessionId)
            }
            return TmuxController.attachCommand(socketName: surface.tmuxSocketName, sessionName: surface.tmuxSessionName)
        }
        guard let tab = terminalTabs.first(where: { $0.terminalId == terminalId }) else { return nil }
        if tab.backend == .native {
            return nativeAttachCommand(for: tab.sessionId)
        }
        return TmuxController.attachCommand(socketName: tab.tmuxSocketName, sessionName: tab.tmuxSessionName)
    }

    /// Build a `smithers-session-connect <sessionId>` command line, locating
    /// the helper in bundle resources, env overrides, the local checkout, or
    /// PATH. Returns nil when the session id is missing.
    nonisolated func nativeAttachCommand(for sessionId: String?) -> String? {
        Self.buildNativeAttachCommand(for: sessionId)
    }

    nonisolated static func buildNativeAttachCommand(
        for sessionId: String?,
        sessionConnectBinaryOverride: String? = nil,
        socketPathOverride: String? = nil
    ) -> String? {
        guard let sessionId, !sessionId.isEmpty else { return nil }

        let binary: String = {
            if let override = sessionConnectBinaryOverride, !override.isEmpty {
                return override
            }
            return SessionController.locateSessionConnectBinary() ?? "smithers-session-connect"
        }()
        let socketPath = SessionController.resolvedSocketPath(socketPathOverride: socketPathOverride)

        // Defensive shell-quoting: the session id is UUID-ish but don't trust it.
        let escapedId = sessionId.replacingOccurrences(of: "'", with: "'\"'\"'")
        let escapedBin = binary.replacingOccurrences(of: "'", with: "'\"'\"'")
        let escapedSocket = socketPath.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escapedBin)' '\(escapedId)' --socket '\(escapedSocket)'"
    }

    nonisolated static func nativeSessionEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = baseEnvironment
        env["TERM"] = nativeTerminalTERM
        env["COLORTERM"] = nativeTerminalColorTerm
        if env["TERM_PROGRAM"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            env["TERM_PROGRAM"] = "Smithers"
        }
        return env
    }

    func removeTerminalTab(_ terminalId: String) {
        if let workspace = terminalWorkspaces.removeValue(forKey: terminalId) {
            for surfaceId in workspace.surfaces.keys {
                SurfaceNotificationStore.shared.unregister(surfaceId: surfaceId.rawValue)
            }
            terminateTmuxSessions(in: workspace.snapshot)
            terminateNativeSessions(in: workspace.snapshot)
        } else if let tab = terminalTabs.first(where: { $0.terminalId == terminalId }) {
            if let snapshot = tab.snapshot {
                if tab.backend == .tmux {
                    terminateTmuxSessions(in: snapshot)
                } else if tab.backend == .native {
                    terminateNativeSessions(in: snapshot)
                }
            } else if tab.backend == .tmux {
                TmuxController.terminateSession(socketName: tab.tmuxSocketName, sessionName: tab.tmuxSessionName)
            } else if tab.backend == .native, let sid = tab.sessionId {
                Task.detached {
                    try? await SessionController.shared.terminate(sessionId: PTYSessionID(sid))
                }
            }
        }
        terminalTabs.removeAll { $0.terminalId == terminalId }
        sessions[terminalId] = nil
        workspaceWindowIds[WorkspaceID(terminalId)] = nil
        TerminalSurfaceRegistry.shared.deregister(sessionId: terminalId)
        scheduleSave()
    }

    private func terminateNativeSessions(in snapshot: TerminalWorkspaceSnapshot) {
        for surface in snapshot.surfaces
        where surface.kind == .terminal && surface.terminalBackend == .native {
            if let sid = surface.sessionId {
                Task.detached {
                    try? await SessionController.shared.terminate(sessionId: PTYSessionID(sid))
                }
            }
        }
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
        var didMutate = false
        for run in runs {
            if let idx = runTabs.firstIndex(where: { $0.runId == run.runId }) {
                runTabs[idx].title = runTabTitle(runId: run.runId, title: run.workflowName)
                runTabs[idx].preview = runPreview(for: run)
                didMutate = true
            } else if run.status == .running || run.status == .waitingApproval || run.status == .waitingEvent || run.status == .waitingTimer {
                addRunTab(runId: run.runId, title: run.workflowName, preview: runPreview(for: run))
                didMutate = true
            }
        }
        if didMutate {
            scheduleSave()
        }
    }

    func updateRunTab(with run: RunSummary) {
        guard let idx = runTabs.firstIndex(where: { $0.runId == run.runId }) else { return }
        let title = runTabTitle(runId: run.runId, title: run.workflowName)
        let preview = runPreview(for: run)
        var mutated = false
        if runTabs[idx].title != title {
            runTabs[idx].title = title
            mutated = true
        }
        if runTabs[idx].preview != preview {
            runTabs[idx].preview = preview
            mutated = true
        }
        if mutated {
            scheduleSave()
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
        reconcileNativeTerminalSurfaces(in: workspace)
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
        scheduleSave()
        return true
    }

    private func syncTerminalTabMetadata(from workspace: TerminalWorkspace) {
        guard let idx = terminalTabs.firstIndex(where: { $0.workspaceID == workspace.id }) else { return }
        let firstTerminal = workspace.orderedSurfaces.first { $0.kind == .terminal }
        let rootSurface = workspace.layout.firstSurfaceId.flatMap { workspace.surfaces[$0] }
        terminalTabs[idx].title = workspace.title
        terminalTabs[idx].preview = workspace.displayPreview
        terminalTabs[idx].workingDirectory = firstTerminal?.terminalWorkingDirectory ?? terminalTabs[idx].workingDirectory
        terminalTabs[idx].rootSurfaceId = rootSurface?.id.rawValue ?? terminalTabs[idx].rootSurfaceId
        terminalTabs[idx].tmuxSocketName = firstTerminal?.tmuxSocketName ?? terminalTabs[idx].tmuxSocketName
        terminalTabs[idx].tmuxSessionName = firstTerminal?.tmuxSessionName ?? terminalTabs[idx].tmuxSessionName
        terminalTabs[idx].sessionId = firstTerminal?.sessionId ?? terminalTabs[idx].sessionId
        terminalTabs[idx].rootKind = rootSurface?.kind ?? terminalTabs[idx].rootKind
        terminalTabs[idx].browserURLString = rootSurface?.browserURLString ?? terminalTabs[idx].browserURLString
        terminalTabs[idx].snapshot = workspace.snapshot
        terminalTabs[idx].timestamp = Date()
        scheduleSave()
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
        case "kimi":
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

    private func terminalSessionKind(for tab: TerminalTab) -> Smithers.Session.Kind {
        terminalSessionKind(runId: normalizedOptionalText(tab.runId), hijack: tab.hijack)
    }

    private func terminalSessionKind(
        runId: String?,
        hijack: TerminalWorkspaceRecord.HijackBinding?
    ) -> Smithers.Session.Kind {
        (runId != nil || hijack != nil) ? .chat : .terminal
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

    private static func isSessionPersistenceDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["SMITHERS_SESSION_PERSISTENCE_DISABLE"] == "1"
    }

    private func restorePersistedSessions() {
        guard !sessionPersistenceDisabled else { return }
        guard let persistence = app.persistence() else { return }

        let loaded = workingDirectory.withCString { smithers_persistence_load_sessions(persistence, $0) }
        let json = Smithers.string(from: loaded)
        guard let data = json.data(using: .utf8) else { return }

        let entries: [PersistedSessionEntry]
        do {
            entries = try Self.persistenceDecoder.decode([PersistedSessionEntry].self, from: data)
        } catch {
            guard json.trimmingCharacters(in: .whitespacesAndNewlines) != "[]" else { return }
            AppLogger.ui.warning("Failed to decode persisted sessions", metadata: [
                "workspace": workingDirectory,
                "error": "\(error)",
            ])
            return
        }

        runTabs = entries.compactMap { entry in
            guard entry.kind == .run else { return nil }
            return entry.runTab
        }
        terminalTabs = entries.compactMap { entry in
            guard entry.kind == .terminal else { return nil }
            return entry.terminalTab
        }

        for tab in runTabs {
            registerWorkspace(tab.workspaceID)
            sessions[tab.runId] = Smithers.Session(
                app: app,
                kind: .runInspect,
                workspacePath: workingDirectory,
                targetID: tab.runId
            )
        }
        for tab in terminalTabs {
            registerWorkspace(tab.workspaceID)
            sessions[tab.terminalId] = Smithers.Session(
                app: app,
                kind: terminalSessionKind(for: tab),
                workspacePath: workingDirectory,
                targetID: tab.terminalId
            )
        }
    }

    private func scheduleSave() {
        guard !sessionPersistenceDisabled else { return }
        guard app.persistence() != nil else { return }

        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.persistenceSaveDebounceNanoseconds)
            } catch {
                return
            }
            self?.saveSessionsNow()
        }
    }

    private func flushPendingSave() {
        guard !sessionPersistenceDisabled else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveSessionsNow()
    }

    private func saveSessionsNow() {
        guard !sessionPersistenceDisabled else { return }
        guard let persistence = app.persistence() else { return }
        pendingSaveTask = nil

        let entries = runTabs.map(PersistedSessionEntry.init(runTab:)) +
            terminalTabs.map(PersistedSessionEntry.init(terminalTab:))

        do {
            let data = try Self.persistenceEncoder.encode(entries)
            guard let json = String(data: data, encoding: .utf8) else {
                AppLogger.ui.warning("Failed to serialize persisted sessions", metadata: [
                    "workspace": workingDirectory,
                ])
                return
            }
            let saveError = workingDirectory.withCString { workspacePtr in
                json.withCString { jsonPtr in
                    smithers_persistence_save_sessions(persistence, workspacePtr, jsonPtr)
                }
            }
            if let message = Smithers.message(from: saveError) {
                AppLogger.ui.warning("Failed to persist sessions", metadata: [
                    "workspace": workingDirectory,
                    "error": message,
                ])
            }
        } catch {
            AppLogger.ui.warning("Failed to encode persisted sessions", metadata: [
                "workspace": workingDirectory,
                "error": "\(error)",
            ])
        }
    }
}
