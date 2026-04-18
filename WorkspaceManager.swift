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
    private let activePathKey = "com.smithers.gui.activeWorkspacePath"
    private let userDefaults: UserDefaults

    init(
        store: RecentWorkspaceStore = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.userDefaults = userDefaults
        self.recents = store.load()
        let saved = userDefaults.string(forKey: activePathKey)
        if let saved, isValidWorkspaceDirectory(saved) {
            self.activeWorkspacePath = saved
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
        userDefaults.set(path, forKey: activePathKey)
        activeWorkspacePath = path
        AppLogger.ui.info("WorkspaceManager opened workspace", metadata: ["path": path])
    }

    func closeWorkspace() {
        activeWorkspacePath = nil
        userDefaults.removeObject(forKey: activePathKey)
        recents = store.load()
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
