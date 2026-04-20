import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
final class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    @Published private(set) var activeWorkspacePath: String?
    @Published private(set) var recents: [RecentWorkspace]

    private let store: RecentWorkspaceStore
    private let userDefaults: UserDefaults

    init(
        store: RecentWorkspaceStore = .shared,
        userDefaults: UserDefaults = .standard,
        launchArguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.userDefaults = userDefaults
        self.recents = store.load()
        // Double-clicking the app always lands on the welcome / picker screen.
        // We only auto-open a workspace when the launch carries an explicit
        // intent — a path arg from a CLI launch (e.g. `SmithersGUI /path/to/repo`)
        // or the SMITHERS_OPEN_WORKSPACE env var. URL-scheme launches go through
        // SmithersApp.handleOpenedURL → openWorkspace and don't need preseeding.
        if let path = Self.workspaceFromLaunch(arguments: launchArguments, environment: environment),
           isValidWorkspaceDirectory(path) {
            self.activeWorkspacePath = path
            self.recents = store.upsert(path: path)
        } else {
            self.activeWorkspacePath = nil
        }
    }

    func openWorkspace(at url: URL) {
        let path = url.standardizedFileURL.path
        guard isValidWorkspaceDirectory(path) else {
            AppLogger.ui.warning("WorkspaceManager refused invalid folder", metadata: ["path": path])
            return
        }
        recents = store.upsert(path: path)
        activeWorkspacePath = path
        AppLogger.ui.info("WorkspaceManager opened workspace", metadata: ["path": path])
    }

    func closeWorkspace() {
        activeWorkspacePath = nil
        recents = store.load()
    }

    /// Extract a workspace path from the process's launch arguments / environment.
    /// `nil` means "no explicit intent" — caller should show the welcome screen.
    static func workspaceFromLaunch(
        arguments: [String],
        environment: [String: String]
    ) -> String? {
        if let env = environment["SMITHERS_OPEN_WORKSPACE"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        // Skip argv[0] (the executable path). Take the first non-flag argument
        // that looks like a real filesystem path. AppKit injects flags like
        // `-NSDocumentRevisionsDebugMode` and `-AppleLanguages (en)` which we
        // must ignore.
        var iter = arguments.dropFirst().makeIterator()
        while let arg = iter.next() {
            if arg.hasPrefix("-") {
                _ = iter.next() // skip the flag's value
                continue
            }
            if arg == "YES" || arg == "NO" { continue }
            return (arg as NSString).expandingTildeInPath
        }
        return nil
    }

    func removeRecent(path: String) {
        recents = store.remove(path: path)
    }

    func refreshRecents() {
        recents = store.load()
    }

    #if os(macOS)
    func presentOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a Smithers workspace"
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspace(at: url)
        }
    }
    #endif

    private func isValidWorkspaceDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
