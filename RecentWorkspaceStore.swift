import Foundation

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

final class RecentWorkspaceStore {
    static let shared = RecentWorkspaceStore()

    private let key = "com.smithers.gui.recentWorkspaces"
    private let maxEntries = 20
    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func load() -> [RecentWorkspace] {
        guard let data = userDefaults.data(forKey: key),
              let entries = try? decoder.decode([RecentWorkspace].self, from: data) else {
            return []
        }
        return entries.sorted { $0.lastOpened > $1.lastOpened }
    }

    func save(_ entries: [RecentWorkspace]) {
        guard let data = try? encoder.encode(Array(entries.prefix(maxEntries))) else { return }
        userDefaults.set(data, forKey: key)
    }

    @discardableResult
    func upsert(path: String, at date: Date = Date()) -> [RecentWorkspace] {
        let normalized = (path as NSString).standardizingPath
        var entries = load().filter { $0.path != normalized }
        let name = (normalized as NSString).lastPathComponent
        entries.insert(
            RecentWorkspace(path: normalized, displayName: name, lastOpened: date),
            at: 0
        )
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
        return entries
    }

    @discardableResult
    func remove(path: String) -> [RecentWorkspace] {
        let normalized = (path as NSString).standardizingPath
        let entries = load().filter { $0.path != normalized }
        save(entries)
        return entries
    }

    func clear() {
        userDefaults.removeObject(forKey: key)
    }
}
