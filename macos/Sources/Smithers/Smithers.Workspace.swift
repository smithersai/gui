import Foundation
import SwiftUI
import CSmithersKit

#if os(macOS)
import AppKit
#endif

extension Smithers {
    enum CWD {
        static func resolve(_ requested: String?) -> String {
            let resolved = requested.withOptionalCString { ptr in smithers_cwd_resolve(ptr) }
            return Smithers.string(from: resolved)
        }
    }
}

struct RecentWorkspace: Codable, Equatable, Identifiable {
    let path: String
    var displayName: String
    var lastOpened: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - 0126 Remote workspace identity

/// Identity of a workspace the user has active in the current app session.
/// The macOS app can hold an arbitrary mix of `.local` and `.remote`
/// workspaces at once — see hybrid-session requirement in ticket 0126.
///
/// This type intentionally lives in the macOS support layer: the Shared
/// Store already has `WorkspaceRow` (Electric shape projection) and we
/// don't want to widen that to carry UI / local-FS concerns.
enum WorkspaceIdentity: Equatable, Hashable {
    /// A local filesystem workspace opened via "Open Folder…".
    case local(path: String)
    /// A remote JJHub sandbox opened via the remote-mode picker.
    case remote(workspaceId: String, engineId: String?)

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    /// A stable cross-run identifier suitable for tab keys.
    var stableId: String {
        switch self {
        case .local(let path): return "local:\(path)"
        case .remote(let id, let engine): return "remote:\(engine ?? "default"):\(id)"
        }
    }
}

private let recentWorkspaceDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
}()

@MainActor
final class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    @Published private(set) var activeWorkspacePath: String?
    @Published private(set) var recents: [RecentWorkspace] = []

    private let app: Smithers.App
    private var activeWorkspace: smithers_workspace_t?
    nonisolated(unsafe) private let activeWorkspaceHandle = MainThreadWorkspaceHandle()

    init(
        userDefaults: UserDefaults = .standard,
        launchArguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        app: Smithers.App? = nil
    ) {
        self.app = app ?? Smithers.App()
        refreshRecents()
        if let path = Self.workspaceFromLaunch(arguments: launchArguments, environment: environment) {
            openWorkspace(at: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    deinit {
        activeWorkspaceHandle.close()
    }

    func openWorkspace(at url: URL) {
        let path = Smithers.CWD.resolve(url.standardizedFileURL.path)
        guard let cApp = app.app else { return }
        if activeWorkspace != nil {
            activeWorkspaceHandle.close()
            self.activeWorkspace = nil
        }
        let opened = path.withCString { smithers_app_open_workspace(cApp, $0) }
        activeWorkspace = opened
        activeWorkspaceHandle.replace(app: cApp, workspace: opened)
        activeWorkspacePath = path
        refreshRecents()
        AppLogger.ui.info("WorkspaceManager opened workspace", metadata: ["path": path])
    }

    func closeWorkspace() {
        activeWorkspaceHandle.close()
        activeWorkspace = nil
        activeWorkspacePath = nil
        refreshRecents()
    }

    static func workspaceFromLaunch(arguments: [String], environment: [String: String]) -> String? {
        if let env = environment["SMITHERS_OPEN_WORKSPACE"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg.hasPrefix("-") {
                _ = iterator.next()
                continue
            }
            if arg == "YES" || arg == "NO" { continue }
            return (arg as NSString).expandingTildeInPath
        }
        return nil
    }

    func removeRecent(path: String) {
        guard let cApp = app.app else {
            recents.removeAll { $0.path == path }
            return
        }
        path.withCString { smithers_app_remove_recent_workspace(cApp, $0) }
        refreshRecents()
    }

    func refreshRecents() {
        guard let cApp = app.app else {
            recents = []
            return
        }
        let json = Smithers.string(from: smithers_app_recent_workspaces_json(cApp))
        guard let data = json.data(using: .utf8),
              let decoded = try? recentWorkspaceDecoder.decode([RecentWorkspace].self, from: data) else {
            recents = []
            return
        }
        recents = decoded
    }

    #if os(macOS)
    func presentOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspace(at: url)
        }
    }
#endif
}

private final class MainThreadWorkspaceHandle {
    private var app: smithers_app_t?
    private var workspace: smithers_workspace_t?

    func replace(app newApp: smithers_app_t?, workspace newWorkspace: smithers_workspace_t?) {
        close()
        app = newApp
        workspace = newWorkspace
    }

    func close() {
        guard let app, let workspace else { return }
        Self.close(app: app, workspace: workspace)
        self.app = nil
        self.workspace = nil
    }

    deinit {
        close()
    }

    private static func close(app: smithers_app_t, workspace: smithers_workspace_t) {
        if Thread.isMainThread {
            smithers_app_close_workspace(app, workspace)
        } else {
            DispatchQueue.main.sync {
                smithers_app_close_workspace(app, workspace)
            }
        }
    }
}
