import Combine
import Foundation

enum KeyboardShortcutSettings {
    static let didChangeNotification = Notification.Name("smithers.keyboardShortcutSettingsDidChange")
    static let actionUserInfoKey = "action"

    static var settingsFileStore: KeyboardShortcutSettingsFileStore = .shared {
        didSet {
            notifySettingsFileDidChange()
        }
    }

    static var userDefaults: UserDefaults = .standard

    private static let conflictLock = NSLock()
    private static var lastConflictSignature = ""

    static var defaultTable: [ShortcutAction: StoredShortcut] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    }

    static func current(for action: ShortcutAction) -> StoredShortcut {
        let shortcut = resolvedShortcut(for: action)
        logShortcutConflictsIfNeeded()
        return shortcut
    }

    static func setShortcut(_ shortcut: StoredShortcut, for action: ShortcutAction) {
        guard !isManagedBySettingsFile(action),
              let normalized = action.normalizedRecordedShortcut(shortcut),
              let data = try? JSONEncoder().encode(normalized)
        else {
            return
        }
        userDefaults.set(data, forKey: action.defaultsKey)
        postDidChangeNotification(action: action)
    }

    static func resetShortcut(for action: ShortcutAction) {
        userDefaults.removeObject(forKey: action.defaultsKey)
        postDidChangeNotification(action: action)
    }

    static func resetAll() {
        for action in ShortcutAction.allCases {
            userDefaults.removeObject(forKey: action.defaultsKey)
        }
        postDidChangeNotification()
    }

    static func isManagedBySettingsFile(_ action: ShortcutAction) -> Bool {
        settingsFileStore.isManagedByFile(action)
    }

    static func settingsFileManagedSubtitle(for action: ShortcutAction) -> String? {
        guard isManagedBySettingsFile(action) else { return nil }
        return String(localized: "settings.shortcuts.managedByFile", defaultValue: "Managed in settings.json")
    }

    static func settingsFileURLForEditing() -> URL {
        settingsFileStore.settingsFileURLForEditing()
    }

    static func settingsFileDisplayPath() -> String {
        settingsFileStore.settingsFileDisplayPath()
    }

    static func notifySettingsFileDidChange() {
        postDidChangeNotification()
    }

    private static func resolvedShortcut(for action: ShortcutAction) -> StoredShortcut {
        if let fileOverride = settingsFileStore.override(for: action) {
            return fileOverride
        }
        guard let data = userDefaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data),
              let normalized = action.normalizedRecordedShortcut(shortcut)
        else {
            return action.defaultShortcut
        }
        return normalized
    }

    private static func postDidChangeNotification(
        action: ShortcutAction? = nil,
        center: NotificationCenter = .default
    ) {
        logShortcutConflictsIfNeeded()
        var userInfo: [AnyHashable: Any] = [:]
        if let action {
            userInfo[actionUserInfoKey] = action.rawValue
        }
        center.post(
            name: didChangeNotification,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }

    private static func logShortcutConflictsIfNeeded() {
        var actionsByShortcut: [String: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases where !action.isPrefixOnly {
            let shortcut = resolvedShortcut(for: action)
            let key = action.displayedShortcutString(for: shortcut)
            actionsByShortcut[key, default: []].append(action)
        }

        let conflicts = actionsByShortcut
            .filter { $0.value.count > 1 }
            .map { shortcut, actions in
                "\(shortcut): \(actions.map(\.rawValue).sorted().joined(separator: ","))"
            }
            .sorted()
        let signature = conflicts.joined(separator: "|")

        conflictLock.lock()
        defer { conflictLock.unlock() }
        guard !signature.isEmpty, signature != lastConflictSignature else { return }
        lastConflictSignature = signature
        AppLogger.ui.warning("Keyboard shortcut conflicts detected", metadata: [
            "conflicts": conflicts.joined(separator: "; "),
        ])
    }
}

@MainActor
final class KeyboardShortcutSettingsObserver: ObservableObject {
    static let shared = KeyboardShortcutSettingsObserver()

    @Published private(set) var revision: UInt64 = 0
    private var cancellable: AnyCancellable?

    private init(notificationCenter: NotificationCenter = .default) {
        cancellable = notificationCenter.publisher(for: KeyboardShortcutSettings.didChangeNotification)
            .sink { [weak self] _ in
                self?.revision &+= 1
            }
    }
}
