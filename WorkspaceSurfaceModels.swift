import Foundation

enum WorkspaceSurfaceKind: String, Hashable, Codable {
    case terminal
    case browser

    var icon: String {
        switch self {
        case .terminal: return "terminal.fill"
        case .browser: return "safari"
        }
    }

    var defaultTitle: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        }
    }
}

enum WorkspaceSplitAxis: String, Hashable, Codable {
    case horizontal
    case vertical
}

indirect enum WorkspaceLayoutNode: Hashable, Codable {
    case leaf(String)
    case split(id: String, axis: WorkspaceSplitAxis, first: WorkspaceLayoutNode, second: WorkspaceLayoutNode)

    var id: String {
        switch self {
        case .leaf(let surfaceId):
            return "leaf-\(surfaceId)"
        case .split(let id, _, _, _):
            return id
        }
    }

    var surfaceIds: [String] {
        switch self {
        case .leaf(let surfaceId):
            return [surfaceId]
        case .split(_, _, let first, let second):
            return first.surfaceIds + second.surfaceIds
        }
    }

    var firstSurfaceId: String? {
        switch self {
        case .leaf(let surfaceId):
            return surfaceId
        case .split(_, _, let first, let second):
            return first.firstSurfaceId ?? second.firstSurfaceId
        }
    }

    func contains(surfaceId: String) -> Bool {
        surfaceIds.contains(surfaceId)
    }

    func replacingLeaf(_ surfaceId: String, with replacement: WorkspaceLayoutNode) -> WorkspaceLayoutNode {
        switch self {
        case .leaf(let currentId):
            return currentId == surfaceId ? replacement : self
        case .split(let id, let axis, let first, let second):
            return .split(
                id: id,
                axis: axis,
                first: first.replacingLeaf(surfaceId, with: replacement),
                second: second.replacingLeaf(surfaceId, with: replacement)
            )
        }
    }

    func removingLeaf(_ surfaceId: String) -> WorkspaceLayoutNode? {
        switch self {
        case .leaf(let currentId):
            return currentId == surfaceId ? nil : self
        case .split(let id, let axis, let first, let second):
            let nextFirst = first.removingLeaf(surfaceId)
            let nextSecond = second.removingLeaf(surfaceId)

            switch (nextFirst, nextSecond) {
            case (.some(let first), .some(let second)):
                return .split(id: id, axis: axis, first: first, second: second)
            case (.some(let only), .none), (.none, .some(let only)):
                return only
            case (.none, .none):
                return nil
            }
        }
    }

    static func makeSplit(axis: WorkspaceSplitAxis, first: WorkspaceLayoutNode, second: WorkspaceLayoutNode) -> WorkspaceLayoutNode {
        .split(id: UUID().uuidString, axis: axis, first: first, second: second)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case surfaceId
        case id
        case axis
        case first
        case second
    }

    private enum Kind: String, Codable {
        case leaf
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .leaf:
            self = .leaf(try container.decode(String.self, forKey: .surfaceId))
        case .split:
            self = .split(
                id: try container.decode(String.self, forKey: .id),
                axis: try container.decode(WorkspaceSplitAxis.self, forKey: .axis),
                first: try container.decode(WorkspaceLayoutNode.self, forKey: .first),
                second: try container.decode(WorkspaceLayoutNode.self, forKey: .second)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let surfaceId):
            try container.encode(Kind.leaf, forKey: .kind)
            try container.encode(surfaceId, forKey: .surfaceId)
        case .split(let id, let axis, let first, let second):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(axis, forKey: .axis)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

struct WorkspaceSurface: Identifiable, Hashable, Codable {
    let id: String
    var kind: WorkspaceSurfaceKind
    var title: String
    var subtitle: String
    var createdAt: Date
    var browserURLString: String?
    var terminalWorkingDirectory: String?
    var terminalCommand: String?
    var terminalBackend: TerminalBackend
    var tmuxSocketName: String?
    var tmuxSessionName: String?

    static func terminal(
        id: String = UUID().uuidString,
        workingDirectory: String? = nil,
        command: String? = nil,
        backend: TerminalBackend = .tmux,
        tmuxSocketName: String? = nil,
        tmuxSessionName: String? = nil
    ) -> WorkspaceSurface {
        WorkspaceSurface(
            id: id,
            kind: .terminal,
            title: WorkspaceSurfaceKind.terminal.defaultTitle,
            subtitle: workingDirectory ?? "Shell session",
            createdAt: Date(),
            browserURLString: nil,
            terminalWorkingDirectory: workingDirectory,
            terminalCommand: command,
            terminalBackend: backend,
            tmuxSocketName: tmuxSocketName,
            tmuxSessionName: tmuxSessionName
        )
    }

    static func browser(id: String = UUID().uuidString, urlString: String? = nil) -> WorkspaceSurface {
        WorkspaceSurface(
            id: id,
            kind: .browser,
            title: WorkspaceSurfaceKind.browser.defaultTitle,
            subtitle: urlString ?? "Web browser",
            createdAt: Date(),
            browserURLString: urlString,
            terminalWorkingDirectory: nil,
            terminalCommand: nil,
            terminalBackend: .ghostty,
            tmuxSocketName: nil,
            tmuxSessionName: nil
        )
    }
}

struct TerminalWorkspaceSnapshot: Hashable, Codable {
    var title: String
    var surfaces: [WorkspaceSurface]
    var layout: WorkspaceLayoutNode
    var focusedSurfaceId: String?
}

@MainActor
protocol TerminalWorkspaceChangeDelegate: AnyObject {
    func terminalWorkspaceDidChange(_ workspace: TerminalWorkspace)
}

@MainActor
final class TerminalWorkspace: ObservableObject, Identifiable {
    let id: String
    @Published var title: String
    @Published private(set) var surfaces: [String: WorkspaceSurface]
    @Published private(set) var layout: WorkspaceLayoutNode
    @Published var focusedSurfaceId: String?
    private let defaultWorkingDirectory: String?
    private let backend: TerminalBackend
    private let tmuxSocketName: String?
    weak var changeDelegate: TerminalWorkspaceChangeDelegate?

    init(
        id: String,
        title: String,
        workingDirectory: String? = nil,
        command: String? = nil,
        rootSurfaceId: String? = nil,
        backend: TerminalBackend = .tmux,
        tmuxSocketName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.defaultWorkingDirectory = workingDirectory
        self.backend = backend
        self.tmuxSocketName = tmuxSocketName

        let surfaceId = rootSurfaceId ?? TmuxController.rootSurfaceId(for: id)
        let target = Self.tmuxTarget(
            surfaceId: surfaceId,
            workingDirectory: workingDirectory,
            socketName: tmuxSocketName
        )
        var initialSurface = WorkspaceSurface.terminal(
            id: surfaceId,
            workingDirectory: workingDirectory,
            command: command,
            backend: backend,
            tmuxSocketName: target?.socketName,
            tmuxSessionName: target?.sessionName
        )
        initialSurface.title = title
        self.surfaces = [initialSurface.id: initialSurface]
        self.layout = .leaf(initialSurface.id)
        self.focusedSurfaceId = initialSurface.id
        SurfaceNotificationStore.shared.register(surfaceId: initialSurface.id, workspaceId: id)
        prepareTerminalSession(initialSurface)
    }

    init(
        id: String,
        snapshot: TerminalWorkspaceSnapshot,
        workingDirectory: String? = nil,
        backend: TerminalBackend = .tmux,
        tmuxSocketName: String? = nil
    ) {
        self.id = id
        self.title = snapshot.title
        self.defaultWorkingDirectory = workingDirectory
        self.backend = backend
        self.tmuxSocketName = tmuxSocketName

        var nextSurfaces: [String: WorkspaceSurface] = [:]
        for var surface in snapshot.surfaces {
            if surface.kind == .terminal {
                surface = Self.normalizedTerminalSurface(
                    surface,
                    defaultWorkingDirectory: workingDirectory,
                    backend: backend,
                    socketName: tmuxSocketName
                )
            }
            nextSurfaces[surface.id] = surface
        }

        if nextSurfaces.isEmpty {
            let fallbackSurfaceId = TmuxController.rootSurfaceId(for: id)
            let target = Self.tmuxTarget(
                surfaceId: fallbackSurfaceId,
                workingDirectory: workingDirectory,
                socketName: tmuxSocketName
            )
            var fallback = WorkspaceSurface.terminal(
                id: fallbackSurfaceId,
                workingDirectory: workingDirectory,
                backend: backend,
                tmuxSocketName: target?.socketName,
                tmuxSessionName: target?.sessionName
            )
            fallback.title = snapshot.title
            nextSurfaces[fallback.id] = fallback
            self.layout = .leaf(fallback.id)
            self.focusedSurfaceId = fallback.id
        } else {
            self.layout = snapshot.layout
            self.focusedSurfaceId = snapshot.focusedSurfaceId ?? snapshot.layout.firstSurfaceId
        }

        self.surfaces = nextSurfaces
        for surface in nextSurfaces.values {
            SurfaceNotificationStore.shared.register(surfaceId: surface.id, workspaceId: id)
            if surface.kind == .terminal {
                prepareTerminalSession(surface)
            }
        }
    }

    var orderedSurfaces: [WorkspaceSurface] {
        layout.surfaceIds.compactMap { surfaces[$0] }
    }

    var terminalSurfaceIds: [String] {
        surfaces.values
            .filter { $0.kind == .terminal }
            .map(\.id)
    }

    var displayPreview: String {
        let terminalCount = surfaces.values.filter { $0.kind == .terminal }.count
        let browserCount = surfaces.values.filter { $0.kind == .browser }.count
        var parts: [String] = []
        if terminalCount > 0 {
            parts.append("\(terminalCount) terminal\(terminalCount == 1 ? "" : "s")")
        }
        if browserCount > 0 {
            parts.append("\(browserCount) browser\(browserCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Workspace" : parts.joined(separator: ", ")
    }

    var snapshot: TerminalWorkspaceSnapshot {
        TerminalWorkspaceSnapshot(
            title: title,
            surfaces: orderedSurfaces,
            layout: layout,
            focusedSurfaceId: focusedSurfaceId
        )
    }

    @discardableResult
    func splitFocused(axis: WorkspaceSplitAxis, kind: WorkspaceSurfaceKind) -> String {
        let newSurface: WorkspaceSurface
        switch kind {
        case .terminal:
            let surfaceId = UUID().uuidString
            let target = Self.tmuxTarget(
                surfaceId: surfaceId,
                workingDirectory: defaultWorkingDirectory,
                socketName: tmuxSocketName
            )
            newSurface = .terminal(
                id: surfaceId,
                workingDirectory: defaultWorkingDirectory,
                backend: backend,
                tmuxSocketName: target?.socketName,
                tmuxSessionName: target?.sessionName
            )
        case .browser:
            newSurface = .browser()
        }

        surfaces[newSurface.id] = newSurface
        SurfaceNotificationStore.shared.register(surfaceId: newSurface.id, workspaceId: id)
        if newSurface.kind == .terminal {
            prepareTerminalSession(newSurface)
        }

        let targetSurfaceId = focusedSurfaceId ?? layout.firstSurfaceId ?? newSurface.id
        if layout.contains(surfaceId: targetSurfaceId) {
            let replacement = WorkspaceLayoutNode.makeSplit(
                axis: axis,
                first: .leaf(targetSurfaceId),
                second: .leaf(newSurface.id)
            )
            layout = layout.replacingLeaf(targetSurfaceId, with: replacement)
        } else {
            layout = WorkspaceLayoutNode.makeSplit(
                axis: axis,
                first: layout,
                second: .leaf(newSurface.id)
            )
        }

        focusSurface(newSurface.id)
        notifyChanged()
        return newSurface.id
    }

    @discardableResult
    func addBrowser(urlString: String? = nil, splitAxis: WorkspaceSplitAxis = .horizontal) -> String {
        let surfaceId = splitFocused(axis: splitAxis, kind: .browser)
        if let urlString {
            updateBrowser(surfaceId: surfaceId, urlString: urlString, title: nil)
        }
        return surfaceId
    }

    func focusSurface(_ surfaceId: String) {
        guard surfaces[surfaceId] != nil else { return }
        focusedSurfaceId = surfaceId
        SurfaceNotificationStore.shared.setFocusedSurface(surfaceId, workspaceId: id)
        SurfaceNotificationStore.shared.markRead(surfaceId: surfaceId)
        notifyChanged()
    }

    func focusSurface(at index: Int) {
        let ordered = orderedSurfaces
        guard ordered.indices.contains(index) else { return }
        focusSurface(ordered[index].id)
    }

    func focusAdjacentSurface(offset: Int) {
        let ordered = orderedSurfaces
        guard !ordered.isEmpty else { return }
        let currentIndex = focusedSurfaceId.flatMap { focusedId in
            ordered.firstIndex { $0.id == focusedId }
        } ?? 0
        let nextIndex = (currentIndex + offset + ordered.count) % ordered.count
        focusSurface(ordered[nextIndex].id)
    }

    func closeSurface(_ surfaceId: String) {
        guard surfaces[surfaceId] != nil else { return }
        guard surfaces.count > 1 else { return }

        let removed = surfaces.removeValue(forKey: surfaceId)
        layout = layout.removingLeaf(surfaceId) ?? .leaf(surfaces.keys.sorted().first ?? surfaceId)
        SurfaceNotificationStore.shared.unregister(surfaceId: surfaceId)

        if removed?.kind == .terminal {
            TerminalSurfaceRegistry.shared.deregister(sessionId: surfaceId)
            TmuxController.terminateSession(
                socketName: removed?.tmuxSocketName,
                sessionName: removed?.tmuxSessionName
            )
        } else if removed?.kind == .browser {
            BrowserSurfaceRegistry.shared.remove(surfaceId: surfaceId)
        }

        if focusedSurfaceId == surfaceId {
            focusedSurfaceId = layout.firstSurfaceId
            if let focusedSurfaceId {
                focusSurface(focusedSurfaceId)
            }
        }
        notifyChanged()
    }

    func closeFocusedSurface() {
        guard let focusedSurfaceId else { return }
        closeSurface(focusedSurfaceId)
    }

    func updateWorkspaceTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.title = trimmed
        if let firstSurfaceId = layout.firstSurfaceId,
           var surface = surfaces[firstSurfaceId],
           surface.kind == .terminal {
            surface.title = trimmed
            surfaces[firstSurfaceId] = surface
        }
        notifyChanged()
    }

    func updateTerminalTitle(surfaceId: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var surface = surfaces[surfaceId] else { return }
        surface.title = trimmed
        surface.subtitle = "Shell session"
        surfaces[surfaceId] = surface
        notifyChanged()
    }

    func updateTerminalWorkingDirectory(surfaceId: String, workingDirectory: String) {
        guard var surface = surfaces[surfaceId] else { return }
        surface.terminalWorkingDirectory = workingDirectory
        if !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            surface.subtitle = workingDirectory
        }
        surfaces[surfaceId] = surface
        notifyChanged()
    }

    func updateBrowser(surfaceId: String, urlString: String?, title: String?) {
        guard var surface = surfaces[surfaceId] else { return }
        if let urlString, !urlString.isEmpty {
            surface.browserURLString = urlString
            surface.subtitle = urlString
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            surface.title = title
        }
        surfaces[surfaceId] = surface
        notifyChanged()
    }

    func prepareAllTerminalSessions() {
        for surface in surfaces.values where surface.kind == .terminal {
            prepareTerminalSession(surface)
        }
    }

    private func prepareTerminalSession(_ surface: WorkspaceSurface) {
        guard surface.kind == .terminal,
              surface.terminalBackend == .tmux,
              !UITestSupport.isEnabled,
              !UITestSupport.isRunningUnitTests
        else {
            return
        }

        _ = TmuxController.ensureSession(
            socketName: surface.tmuxSocketName ?? TmuxController.socketName(for: defaultWorkingDirectory ?? ""),
            sessionName: surface.tmuxSessionName ?? TmuxController.sessionName(for: surface.id),
            workingDirectory: surface.terminalWorkingDirectory ?? defaultWorkingDirectory,
            command: surface.terminalCommand,
            title: surface.title
        )
    }

    private func notifyChanged() {
        changeDelegate?.terminalWorkspaceDidChange(self)
    }

    private static func normalizedTerminalSurface(
        _ surface: WorkspaceSurface,
        defaultWorkingDirectory: String?,
        backend: TerminalBackend,
        socketName: String?
    ) -> WorkspaceSurface {
        var surface = surface
        surface.terminalBackend = backend
        if surface.terminalWorkingDirectory == nil {
            surface.terminalWorkingDirectory = defaultWorkingDirectory
        }
        if backend == .tmux {
            let target = tmuxTarget(
                surfaceId: surface.id,
                workingDirectory: surface.terminalWorkingDirectory ?? defaultWorkingDirectory,
                socketName: socketName
            )
            surface.tmuxSocketName = surface.tmuxSocketName ?? target?.socketName
            surface.tmuxSessionName = surface.tmuxSessionName ?? target?.sessionName
        }
        return surface
    }

    private static func tmuxTarget(
        surfaceId: String,
        workingDirectory: String?,
        socketName: String?
    ) -> TmuxTerminalTarget? {
        let socket = socketName ?? TmuxController.socketName(for: workingDirectory ?? "")
        return TmuxTerminalTarget(
            socketName: socket,
            sessionName: TmuxController.sessionName(for: surfaceId)
        )
    }
}
