import Foundation
#if os(macOS)
import Darwin
#endif

final class KeyboardShortcutSettingsFileStore {
    static let shared = KeyboardShortcutSettingsFileStore()

    static var defaultSettingsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("smithers", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private let settingsFileURL: URL
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var watcher: KeyboardShortcutSettingsFileWatcher?
    private var overridesByAction: [ShortcutAction: StoredShortcut] = [:]

    init(
        settingsFileURL: URL = KeyboardShortcutSettingsFileStore.defaultSettingsFileURL,
        fileManager: FileManager = .default,
        startWatching: Bool = true
    ) {
        self.settingsFileURL = settingsFileURL
        self.fileManager = fileManager

        ensureSettingsDirectoryExists()
        reload(notify: false)

        if startWatching {
            watcher = KeyboardShortcutSettingsFileWatcher(
                path: settingsFileURL.path,
                fileManager: fileManager
            ) { [weak self] in
                self?.reload()
            }
        }
    }

    deinit {
        watcher?.stop()
    }

    func reload(notify: Bool = true) {
        let previous = overrides
        let next = loadOverrides()
        stateLock.lock()
        overridesByAction = next
        stateLock.unlock()

        if notify && previous != next {
            KeyboardShortcutSettings.notifySettingsFileDidChange()
        }
    }

    func override(for action: ShortcutAction) -> StoredShortcut? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return overridesByAction[action]
    }

    func isManagedByFile(_ action: ShortcutAction) -> Bool {
        override(for: action) != nil
    }

    func settingsFileURLForEditing() -> URL {
        ensureSettingsDirectoryExists()
        return settingsFileURL
    }

    func settingsFileDisplayPath() -> String {
        (settingsFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    var overrides: [ShortcutAction: StoredShortcut] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return overridesByAction
    }

    private func ensureSettingsDirectoryExists() {
        let directoryURL = settingsFileURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            NSLog("[KeyboardShortcutSettingsFileStore] failed to create settings directory %@: %@", directoryURL.path, String(describing: error))
        }
    }

    private func loadOverrides() -> [ShortcutAction: StoredShortcut] {
        guard fileManager.fileExists(atPath: settingsFileURL.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: settingsFileURL)
            guard !data.isEmpty else { return [:] }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let shortcutsSection = root["shortcuts"] as? [String: Any]
            else {
                return [:]
            }

            var rawBindings = shortcutsSection["bindings"] as? [String: Any] ?? [:]
            for (key, value) in shortcutsSection where key != "bindings" {
                rawBindings[key] = value
            }

            var resolved: [ShortcutAction: StoredShortcut] = [:]
            let decoder = JSONDecoder()
            for (rawAction, rawValue) in rawBindings {
                guard let action = ShortcutAction(rawValue: rawAction) else {
                    NSLog("[KeyboardShortcutSettingsFileStore] ignoring unknown shortcut action '%@'", rawAction)
                    continue
                }
                guard JSONSerialization.isValidJSONObject(rawValue),
                      let shortcutData = try? JSONSerialization.data(withJSONObject: rawValue),
                      let decoded = try? decoder.decode(StoredShortcut.self, from: shortcutData),
                      let normalized = action.normalizedRecordedShortcut(decoded)
                else {
                    NSLog("[KeyboardShortcutSettingsFileStore] ignoring invalid shortcut binding for '%@'", rawAction)
                    continue
                }
                resolved[action] = normalized
            }
            return resolved
        } catch {
            NSLog("[KeyboardShortcutSettingsFileStore] failed to load %@: %@", settingsFileURL.path, String(describing: error))
            return [:]
        }
    }
}

private final class KeyboardShortcutSettingsFileWatcher {
    private let path: String
    private let fileManager: FileManager
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.smithers.gui.keyboard-shortcut-settings-file-watch")
    private var source: DispatchSourceFileSystemObject?

    init(path: String, fileManager: FileManager, onChange: @escaping () -> Void) {
        self.path = path
        self.fileManager = fileManager
        self.onChange = onChange
        start()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func start() {
        stop()

        if fileManager.fileExists(atPath: path) {
            startFileWatcher()
        } else {
            startDirectoryWatcher()
        }
    }

    private func startFileWatcher() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            startDirectoryWatcher()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.start()
            }
            DispatchQueue.main.async {
                self.onChange()
            }
        }
        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        source.resume()
    }

    private func startDirectoryWatcher() {
        let directoryPath = (path as NSString).deletingLastPathComponent
        guard fileManager.fileExists(atPath: directoryPath) else { return }

        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.fileManager.fileExists(atPath: self.path) {
                self.start()
            }
            DispatchQueue.main.async {
                self.onChange()
            }
        }
        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        source.resume()
    }
}
