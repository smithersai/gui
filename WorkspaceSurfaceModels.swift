import Foundation

enum WorkspaceSurfaceKind: String, Hashable, Codable {
    case terminal
    case browser
    case markdown

    var icon: String {
        switch self {
        case .terminal: return "terminal.fill"
        case .browser: return "safari"
        case .markdown: return "doc.richtext"
        }
    }

    var defaultTitle: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .markdown: return "Markdown"
        }
    }
}

enum WorkspaceSplitAxis: String, Hashable, Codable {
    case horizontal
    case vertical
}

enum Placement: Hashable {
    case beforeSurface(SurfaceID)
    case afterSurface(SurfaceID)
    case beforeWorkspace(WorkspaceID)
    case afterWorkspace(WorkspaceID)
    case start
    case end
}

enum Anchor: Hashable {
    case beforeSurface(SurfaceID)
    case afterSurface(SurfaceID)
    case beforeWorkspace(WorkspaceID)
    case afterWorkspace(WorkspaceID)
}

enum WorkspaceSurfacePlacementError: Error, Equatable {
    case surfaceNotFound
    case paneNotFound
    case workspaceNotFound
    case windowNotFound
    case invalidPlacement
    case cannotMoveOnlySurface
}

struct WorkspaceSurfacePlacementResult: Equatable {
    let windowID: WindowID
    let workspaceID: WorkspaceID
    let paneID: PaneID
    let surfaceID: SurfaceID

    var window_id: WindowID { windowID }
    var workspace_id: WorkspaceID { workspaceID }
    var pane_id: PaneID { paneID }
    var surface_id: SurfaceID { surfaceID }
}

indirect enum WorkspaceLayoutNode: Hashable, Codable {
    case leaf(SurfaceID)
    case split(id: PaneID, axis: WorkspaceSplitAxis, first: WorkspaceLayoutNode, second: WorkspaceLayoutNode)

    var id: String {
        switch self {
        case .leaf(let surfaceId):
            return "leaf-\(surfaceId.rawValue)"
        case .split(let id, _, _, _):
            return id.rawValue
        }
    }

    var surfaceIds: [SurfaceID] {
        switch self {
        case .leaf(let surfaceId):
            return [surfaceId]
        case .split(_, _, let first, let second):
            return first.surfaceIds + second.surfaceIds
        }
    }

    var firstSurfaceId: SurfaceID? {
        switch self {
        case .leaf(let surfaceId):
            return surfaceId
        case .split(_, _, let first, let second):
            return first.firstSurfaceId ?? second.firstSurfaceId
        }
    }

    func contains(surfaceId: SurfaceID) -> Bool {
        surfaceIds.contains(surfaceId)
    }

    func replacingLeaf(_ surfaceId: SurfaceID, with replacement: WorkspaceLayoutNode) -> WorkspaceLayoutNode {
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

    func removingLeaf(_ surfaceId: SurfaceID) -> WorkspaceLayoutNode? {
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
        .split(id: PaneID(), axis: axis, first: first, second: second)
    }

    static func fromOrderedSurfaceIDs(_ surfaceIds: [SurfaceID], axis: WorkspaceSplitAxis = .horizontal) -> WorkspaceLayoutNode? {
        guard let first = surfaceIds.first else { return nil }
        return surfaceIds.dropFirst().reduce(WorkspaceLayoutNode.leaf(first)) { partial, surfaceId in
            WorkspaceLayoutNode.makeSplit(axis: axis, first: partial, second: .leaf(surfaceId))
        }
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
            self = .leaf(try container.decode(SurfaceID.self, forKey: .surfaceId))
        case .split:
            self = .split(
                id: try container.decode(PaneID.self, forKey: .id),
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
    let id: SurfaceID
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
    var markdownFilePath: String?

    static func terminal(
        id: SurfaceID = SurfaceID(),
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
            tmuxSessionName: tmuxSessionName,
            markdownFilePath: nil
        )
    }

    static func browser(id: SurfaceID = SurfaceID(), urlString: String? = nil) -> WorkspaceSurface {
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
            tmuxSessionName: nil,
            markdownFilePath: nil
        )
    }

    static func markdown(id: SurfaceID = SurfaceID(), filePath: String) -> WorkspaceSurface {
        let normalizedPath = (filePath as NSString).standardizingPath
        let fileName = (normalizedPath as NSString).lastPathComponent
        return WorkspaceSurface(
            id: id,
            kind: .markdown,
            title: fileName.isEmpty ? WorkspaceSurfaceKind.markdown.defaultTitle : fileName,
            subtitle: normalizedPath,
            createdAt: Date(),
            browserURLString: nil,
            terminalWorkingDirectory: nil,
            terminalCommand: nil,
            terminalBackend: .ghostty,
            tmuxSocketName: nil,
            tmuxSessionName: nil,
            markdownFilePath: normalizedPath
        )
    }
}

struct TerminalWorkspaceSnapshot: Hashable, Codable {
    var title: String
    var surfaces: [WorkspaceSurface]
    var layout: WorkspaceLayoutNode
    var focusedSurfaceId: SurfaceID?
}

@MainActor
protocol TerminalWorkspaceChangeDelegate: AnyObject {
    func terminalWorkspaceDidChange(_ workspace: TerminalWorkspace)
}

@MainActor
final class TerminalWorkspace: ObservableObject, Identifiable {
    let id: WorkspaceID
    @Published private(set) var windowID: WindowID
    @Published var title: String
    @Published private(set) var surfaces: [SurfaceID: WorkspaceSurface]
    @Published private(set) var layout: WorkspaceLayoutNode
    @Published private(set) var paneIdsBySurfaceId: [SurfaceID: PaneID]
    @Published var focusedSurfaceId: SurfaceID?
    private let defaultWorkingDirectory: String?
    private let backend: TerminalBackend
    private let tmuxSocketName: String?
    weak var changeDelegate: TerminalWorkspaceChangeDelegate?

    init(
        id: WorkspaceID,
        windowID: WindowID = WindowID(),
        title: String,
        workingDirectory: String? = nil,
        command: String? = nil,
        rootSurfaceId: SurfaceID? = nil,
        backend: TerminalBackend = .tmux,
        tmuxSocketName: String? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.title = title
        self.defaultWorkingDirectory = workingDirectory
        self.backend = backend
        self.tmuxSocketName = tmuxSocketName

        let surfaceId = rootSurfaceId ?? SurfaceID()
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
        self.paneIdsBySurfaceId = [initialSurface.id: PaneID()]
        self.focusedSurfaceId = initialSurface.id
        SurfaceNotificationStore.shared.register(surfaceId: initialSurface.id.rawValue, workspaceId: id.rawValue)
        prepareTerminalSession(initialSurface)
    }

    init(
        id: WorkspaceID,
        windowID: WindowID = WindowID(),
        snapshot: TerminalWorkspaceSnapshot,
        workingDirectory: String? = nil,
        backend: TerminalBackend = .tmux,
        tmuxSocketName: String? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.title = snapshot.title
        self.defaultWorkingDirectory = workingDirectory
        self.backend = backend
        self.tmuxSocketName = tmuxSocketName

        var nextSurfaces: [SurfaceID: WorkspaceSurface] = [:]
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

        let restoredLayout: WorkspaceLayoutNode
        let restoredFocusedSurfaceID: SurfaceID?

        if nextSurfaces.isEmpty {
            let fallbackSurfaceId = SurfaceID()
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
            restoredLayout = .leaf(fallback.id)
            restoredFocusedSurfaceID = fallback.id
        } else {
            restoredLayout = snapshot.layout
            restoredFocusedSurfaceID = snapshot.focusedSurfaceId ?? snapshot.layout.firstSurfaceId
        }

        self.surfaces = nextSurfaces
        self.layout = restoredLayout
        self.paneIdsBySurfaceId = Dictionary(uniqueKeysWithValues: restoredLayout.surfaceIds.map { ($0, PaneID()) })
        self.focusedSurfaceId = restoredFocusedSurfaceID
        for surface in nextSurfaces.values {
            SurfaceNotificationStore.shared.register(surfaceId: surface.id.rawValue, workspaceId: id.rawValue)
            if surface.kind == .terminal {
                prepareTerminalSession(surface)
            }
        }
    }

    var orderedSurfaces: [WorkspaceSurface] {
        layout.surfaceIds.compactMap { surfaces[$0] }
    }

    var terminalSurfaceIds: [SurfaceID] {
        surfaces.values
            .filter { $0.kind == .terminal }
            .map(\.id)
    }

    var displayPreview: String {
        let terminalCount = surfaces.values.filter { $0.kind == .terminal }.count
        let browserCount = surfaces.values.filter { $0.kind == .browser }.count
        let markdownCount = surfaces.values.filter { $0.kind == .markdown }.count
        var parts: [String] = []
        if terminalCount > 0 {
            parts.append("\(terminalCount) terminal\(terminalCount == 1 ? "" : "s")")
        }
        if browserCount > 0 {
            parts.append("\(browserCount) browser\(browserCount == 1 ? "" : "s")")
        }
        if markdownCount > 0 {
            parts.append("\(markdownCount) markdown\(markdownCount == 1 ? "" : "s")")
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

    var paneIDs: [PaneID] {
        layout.surfaceIds.compactMap { paneIdsBySurfaceId[$0] }
    }

    func moveToWindow(_ windowID: WindowID) {
        self.windowID = windowID
        notifyChanged()
    }

    func paneID(containing surfaceId: SurfaceID) -> PaneID? {
        guard surfaces[surfaceId] != nil else { return nil }
        return paneIdsBySurfaceId[surfaceId]
    }

    func containsPane(_ paneID: PaneID) -> Bool {
        paneIdsBySurfaceId.values.contains(paneID)
    }

    @discardableResult
    func moveSurface(
        _ surfaceId: SurfaceID,
        toPane paneID: PaneID,
        placement: Placement
    ) -> Swift.Result<WorkspaceSurfacePlacementResult, WorkspaceSurfacePlacementError> {
        guard surfaces[surfaceId] != nil else {
            return .failure(.surfaceNotFound)
        }
        guard containsPane(paneID) else {
            return .failure(.paneNotFound)
        }
        guard let nextOrder = reorderedSurfaceIDs(moving: surfaceId, placement: placement) else {
            return .failure(.invalidPlacement)
        }
        guard rebuildLayout(with: nextOrder) else {
            return .failure(.invalidPlacement)
        }

        paneIdsBySurfaceId[surfaceId] = paneID
        focusSurface(surfaceId)
        notifyChanged()
        return .success(
            WorkspaceSurfacePlacementResult(
                windowID: windowID,
                workspaceID: id,
                paneID: paneID,
                surfaceID: surfaceId
            )
        )
    }

    @discardableResult
    func reorderSurface(
        _ surfaceId: SurfaceID,
        anchor: Anchor
    ) -> Swift.Result<WorkspaceSurfacePlacementResult, WorkspaceSurfacePlacementError> {
        guard let paneID = paneID(containing: surfaceId) else {
            return .failure(.surfaceNotFound)
        }

        switch anchor {
        case .beforeSurface(let anchorID):
            return moveSurface(surfaceId, toPane: paneID, placement: .beforeSurface(anchorID))
        case .afterSurface(let anchorID):
            return moveSurface(surfaceId, toPane: paneID, placement: .afterSurface(anchorID))
        case .beforeWorkspace, .afterWorkspace:
            return .failure(.invalidPlacement)
        }
    }

    func detachSurfaceForMove(
        _ surfaceId: SurfaceID
    ) -> Swift.Result<WorkspaceSurface, WorkspaceSurfacePlacementError> {
        guard let surface = surfaces[surfaceId] else {
            return .failure(.surfaceNotFound)
        }
        guard surfaces.count > 1 else {
            return .failure(.cannotMoveOnlySurface)
        }

        surfaces[surfaceId] = nil
        paneIdsBySurfaceId[surfaceId] = nil
        layout = layout.removingLeaf(surfaceId) ?? layout
        if focusedSurfaceId == surfaceId {
            focusedSurfaceId = layout.firstSurfaceId
        }
        notifyChanged()
        return .success(surface)
    }

    @discardableResult
    func attachMovedSurface(
        _ surface: WorkspaceSurface,
        toPane paneID: PaneID,
        placement: Placement
    ) -> Swift.Result<WorkspaceSurfacePlacementResult, WorkspaceSurfacePlacementError> {
        guard containsPane(paneID) else {
            return .failure(.paneNotFound)
        }

        surfaces[surface.id] = surface
        paneIdsBySurfaceId[surface.id] = paneID
        guard let nextOrder = reorderedSurfaceIDs(moving: surface.id, placement: placement),
              rebuildLayout(with: nextOrder)
        else {
            surfaces[surface.id] = nil
            paneIdsBySurfaceId[surface.id] = nil
            return .failure(.invalidPlacement)
        }

        SurfaceNotificationStore.shared.register(surfaceId: surface.id.rawValue, workspaceId: id.rawValue)
        if surface.kind == .terminal {
            prepareTerminalSession(surface)
        }
        focusSurface(surface.id)
        notifyChanged()
        return .success(
            WorkspaceSurfacePlacementResult(
                windowID: windowID,
                workspaceID: id,
                paneID: paneID,
                surfaceID: surface.id
            )
        )
    }

    @discardableResult
    func splitFocused(axis: WorkspaceSplitAxis, kind: WorkspaceSurfaceKind) -> SurfaceID {
        let newSurface: WorkspaceSurface
        switch kind {
        case .terminal:
            let surfaceId = SurfaceID()
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
        case .markdown:
            assertionFailure("Use addMarkdown(filePath:splitAxis:) for markdown surfaces.")
            newSurface = .markdown(filePath: "")
        }

        return insertSurface(newSurface, splitAxis: axis)
    }

    @discardableResult
    func addMarkdown(filePath: String, splitAxis: WorkspaceSplitAxis = .horizontal) -> SurfaceID {
        insertSurface(.markdown(filePath: filePath), splitAxis: splitAxis)
    }

    @discardableResult
    private func insertSurface(_ newSurface: WorkspaceSurface, splitAxis: WorkspaceSplitAxis) -> SurfaceID {
        surfaces[newSurface.id] = newSurface
        paneIdsBySurfaceId[newSurface.id] = PaneID()
        SurfaceNotificationStore.shared.register(surfaceId: newSurface.id.rawValue, workspaceId: id.rawValue)
        if newSurface.kind == .terminal {
            prepareTerminalSession(newSurface)
        }

        let targetSurfaceId = focusedSurfaceId ?? layout.firstSurfaceId ?? newSurface.id
        if layout.contains(surfaceId: targetSurfaceId) {
            let replacement = WorkspaceLayoutNode.makeSplit(
                axis: splitAxis,
                first: .leaf(targetSurfaceId),
                second: .leaf(newSurface.id)
            )
            layout = layout.replacingLeaf(targetSurfaceId, with: replacement)
        } else {
            layout = WorkspaceLayoutNode.makeSplit(
                axis: splitAxis,
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
        return surfaceId.rawValue
    }

    func focusSurface(_ surfaceId: String) {
        focusSurface(SurfaceID(surfaceId))
    }

    func focusSurface(_ surfaceId: SurfaceID) {
        guard surfaces[surfaceId] != nil else { return }
        focusedSurfaceId = surfaceId
        SurfaceNotificationStore.shared.setFocusedSurface(surfaceId.rawValue, workspaceId: id.rawValue)
        SurfaceNotificationStore.shared.markRead(surfaceId: surfaceId.rawValue)
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
        closeSurface(SurfaceID(surfaceId))
    }

    func closeSurface(_ surfaceId: SurfaceID) {
        guard surfaces[surfaceId] != nil else { return }
        guard surfaces.count > 1 else { return }

        let removed = surfaces.removeValue(forKey: surfaceId)
        layout = layout.removingLeaf(surfaceId) ?? .leaf(surfaces.keys.first ?? surfaceId)
        paneIdsBySurfaceId[surfaceId] = nil
        SurfaceNotificationStore.shared.unregister(surfaceId: surfaceId.rawValue)

        if removed?.kind == .terminal {
            TerminalSurfaceRegistry.shared.deregister(sessionId: surfaceId.rawValue)
            TmuxController.terminateSession(
                socketName: removed?.tmuxSocketName,
                sessionName: removed?.tmuxSessionName
            )
        } else if removed?.kind == .browser {
            BrowserSurfaceRegistry.shared.remove(surfaceId: surfaceId.rawValue)
        } else if removed?.kind == .markdown {
            MarkdownSurfaceRegistry.shared.remove(surfaceId: surfaceId.rawValue)
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
        updateTerminalTitle(surfaceId: SurfaceID(surfaceId), title: title)
    }

    func updateTerminalTitle(surfaceId: SurfaceID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var surface = surfaces[surfaceId] else { return }
        surface.title = trimmed
        surface.subtitle = "Shell session"
        surfaces[surfaceId] = surface
        notifyChanged()
    }

    func updateTerminalWorkingDirectory(surfaceId: String, workingDirectory: String) {
        updateTerminalWorkingDirectory(surfaceId: SurfaceID(surfaceId), workingDirectory: workingDirectory)
    }

    func updateTerminalWorkingDirectory(surfaceId: SurfaceID, workingDirectory: String) {
        guard var surface = surfaces[surfaceId] else { return }
        surface.terminalWorkingDirectory = workingDirectory
        if !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            surface.subtitle = workingDirectory
        }
        surfaces[surfaceId] = surface
        notifyChanged()
    }

    func updateBrowser(surfaceId: String, urlString: String?, title: String?) {
        updateBrowser(surfaceId: SurfaceID(surfaceId), urlString: urlString, title: title)
    }

    func updateBrowser(surfaceId: SurfaceID, urlString: String?, title: String?) {
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
            sessionName: surface.tmuxSessionName ?? TmuxController.sessionName(for: surface.id.rawValue),
            workingDirectory: surface.terminalWorkingDirectory ?? defaultWorkingDirectory,
            command: surface.terminalCommand,
            title: surface.title
        )
    }

    private func notifyChanged() {
        changeDelegate?.terminalWorkspaceDidChange(self)
    }

    private func reorderedSurfaceIDs(moving surfaceId: SurfaceID, placement: Placement) -> [SurfaceID]? {
        var order = layout.surfaceIds.filter { $0 != surfaceId }
        let insertionIndex: Int

        switch placement {
        case .start:
            insertionIndex = 0
        case .end:
            insertionIndex = order.count
        case .beforeSurface(let anchorID):
            guard anchorID != surfaceId else {
                return layout.surfaceIds
            }
            guard let index = order.firstIndex(of: anchorID) else { return nil }
            insertionIndex = index
        case .afterSurface(let anchorID):
            guard anchorID != surfaceId else {
                return layout.surfaceIds
            }
            guard let index = order.firstIndex(of: anchorID) else { return nil }
            insertionIndex = order.index(after: index)
        case .beforeWorkspace, .afterWorkspace:
            return nil
        }

        order.insert(surfaceId, at: insertionIndex)
        return order
    }

    private func rebuildLayout(with surfaceIds: [SurfaceID]) -> Bool {
        guard let nextLayout = WorkspaceLayoutNode.fromOrderedSurfaceIDs(surfaceIds) else {
            return false
        }
        layout = nextLayout
        return true
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
        surfaceId: SurfaceID,
        workingDirectory: String?,
        socketName: String?
    ) -> TmuxTerminalTarget? {
        let socket = socketName ?? TmuxController.socketName(for: workingDirectory ?? "")
        return TmuxTerminalTarget(
            socketName: socket,
            sessionName: TmuxController.sessionName(for: surfaceId.rawValue)
        )
    }
}
