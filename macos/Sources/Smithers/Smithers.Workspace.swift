import Foundation
import SwiftUI
import CSmithersKit

#if os(macOS)
import AppKit
#endif

extension Smithers {
    enum CWD {
        static func resolve(_ requested: String?) -> String {
            #if SMITHERS_STUB
            let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = trimmed?.isEmpty == false ? trimmed! : FileManager.default.currentDirectoryPath
            let standardized = (candidate as NSString).expandingTildeInPath
            if standardized == "/" { return NSHomeDirectory() }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return NSHomeDirectory()
            }
            return (standardized as NSString).standardizingPath
            #else
            let resolved = requested.withOptionalCString { ptr in smithers_cwd_resolve(ptr) }
            return Smithers.string(from: resolved)
            #endif
        }
    }
}

@MainActor
final class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    @Published private(set) var activeWorkspacePath: String?
    @Published private(set) var recents: [RecentWorkspace] = []

    private let app: Smithers.App
    private var activeWorkspace: smithers_workspace_t?

    init(
        store: RecentWorkspaceStore = .shared,
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

    func openWorkspace(at url: URL) {
        let path = Smithers.CWD.resolve(url.standardizedFileURL.path)
        #if !SMITHERS_STUB
        guard let cApp = app.app else { return }
        activeWorkspace = path.withCString { smithers_app_open_workspace(cApp, $0) }
        #endif
        activeWorkspacePath = path
        refreshRecents()
        AppLogger.ui.info("WorkspaceManager opened workspace", metadata: ["path": path])
    }

    func closeWorkspace() {
        #if !SMITHERS_STUB
        if let cApp = app.app, let activeWorkspace {
            smithers_app_close_workspace(cApp, activeWorkspace)
        }
        #endif
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
        recents.removeAll { $0.path == path }
    }

    func refreshRecents() {
        #if SMITHERS_STUB
        recents = activeWorkspacePath.map {
            [RecentWorkspace(path: $0, displayName: ($0 as NSString).lastPathComponent, lastOpened: Date())]
        } ?? []
        #else
        guard let cApp = app.app else {
            recents = []
            return
        }
        let json = Smithers.string(from: smithers_app_recent_workspaces_json(cApp))
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentWorkspace].self, from: data) else {
            recents = []
            return
        }
        recents = decoded
        #endif
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
