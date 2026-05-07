import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

extension Smithers {
    enum CWD {
        static func resolve(_ requested: String?) -> String {
            let raw = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = raw?.isEmpty == false ? raw! : FileManager.default.currentDirectoryPath
            let expanded = (candidate as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded).standardizedFileURL.path
            }
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expanded)
                .standardizedFileURL
                .path
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

enum WorkspaceIdentity: Equatable, Hashable {
    case local(path: String)
    case remote(workspaceId: String, engineId: String?)

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

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

private let recentWorkspaceEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    return encoder
}()

@MainActor
final class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    @Published private(set) var activeWorkspacePath: String?
    @Published private(set) var recents: [RecentWorkspace] = []

    private static let recentsKey = "smithers.recentWorkspaces"
    private let userDefaults: UserDefaults
    private let app: Smithers.App

    init(
        userDefaults: UserDefaults = .standard,
        launchArguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        app: Smithers.App? = nil
    ) {
        self.userDefaults = userDefaults
        self.app = app ?? Smithers.App()
        refreshRecents()
        if let path = Self.workspaceFromLaunch(arguments: launchArguments, environment: environment) {
            openWorkspace(at: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func openWorkspace(at url: URL) {
        let path = Smithers.CWD.resolve(url.standardizedFileURL.path)
        activeWorkspacePath = path
        upsertRecent(path: path)
        AppLogger.ui.info("WorkspaceManager opened workspace", metadata: ["path": path])
    }

    func closeWorkspace() {
        activeWorkspacePath = nil
    }

    static func workspaceFromLaunch(arguments: [String], environment: [String: String]) -> String? {
        if let env = environment["SMITHERS_APP_OPEN_WORKSPACE"], !env.isEmpty {
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
        saveRecents()
    }

    func refreshRecents() {
        guard let data = userDefaults.data(forKey: Self.recentsKey),
              let decoded = try? recentWorkspaceDecoder.decode([RecentWorkspace].self, from: data) else {
            recents = []
            return
        }
        recents = decoded
    }

    private func upsertRecent(path: String) {
        let displayName = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        recents.removeAll { $0.path == path }
        recents.insert(
            RecentWorkspace(path: path, displayName: displayName.isEmpty ? path : displayName, lastOpened: Date()),
            at: 0
        )
        recents = Array(recents.prefix(20))
        saveRecents()
    }

    private func saveRecents() {
        if let data = try? recentWorkspaceEncoder.encode(recents) {
            userDefaults.set(data, forKey: Self.recentsKey)
        }
        NotificationCenter.default.post(name: .smithersStateChanged, object: nil)
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
