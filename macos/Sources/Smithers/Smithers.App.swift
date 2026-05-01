import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import UserNotifications
#endif

extension Notification.Name {
    static let smithersStateChanged = Notification.Name("smithers.stateChanged")
    static let smithersAction = Notification.Name("smithers.action")
}

final class SmithersLocalAppHandle {}

final class SessionPersistence {
    private let url: URL
    private let lock = NSLock()

    init?(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        url = URL(fileURLWithPath: expanded)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            AppLogger.ui.warning("Failed to create session persistence directory", metadata: [
                "path": expanded,
                "error": "\(error)",
            ])
            return nil
        }
    }

    func loadSessions(workspacePath: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return readStore()[workspacePath] ?? "[]"
    }

    func saveSessions(workspacePath: String, json: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var store = readStore()
        store[workspacePath] = json
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: [.atomic])
    }

    private func readStore() -> [String: String] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

extension Smithers {
    @MainActor
    class App: ObservableObject {
        @Published var readiness: Readiness = .loading
        @Published private(set) var app: SmithersLocalAppHandle?

        private let persistenceStore: SessionPersistence?

        init(
            databasePath: String? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            let dbPath = Self.resolveAppDatabasePath(override: databasePath, environment: environment)
            persistenceStore = dbPath.flatMap(SessionPersistence.init(path:))
            app = SmithersLocalAppHandle()
            readiness = .ready
        }

        func persistence() -> SessionPersistence? {
            persistenceStore
        }

        func tick() {}

        func setColorScheme(_ scheme: ColorScheme) {
            _ = scheme
        }

        private static func resolveAppDatabasePath(
            override: String? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> String? {
            let fm = FileManager.default
            if let override {
                let expanded = (override as NSString).expandingTildeInPath
                return prepareDatabasePath(at: URL(fileURLWithPath: expanded))
            }
            if let supportOverride = environment["SMITHERS_APP_SUPPORT"], !supportOverride.isEmpty {
                let expanded = (supportOverride as NSString).expandingTildeInPath
                let dir = URL(fileURLWithPath: expanded, isDirectory: true)
                return prepareDatabasePath(at: dir.appendingPathComponent("app.sqlite"))
            }
            guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let dir = base.appendingPathComponent("Smithers", isDirectory: true)
            return prepareDatabasePath(at: dir.appendingPathComponent("app.sqlite"))
        }

        private static func prepareDatabasePath(at url: URL) -> String? {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                return url.path
            } catch {
                AppLogger.ui.warning("Failed to create app support directory", metadata: ["error": "\(error)"])
                return nil
            }
        }

        @MainActor
        static func perform(action: Action) {
            #if os(macOS)
            switch action.kind {
            case .toast, .desktopNotification:
                let content = UNMutableNotificationContent()
                content.title = action.title ?? "Smithers"
                content.body = action.body ?? ""
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                )
            case .clipboardWrite:
                if let text = action.value {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case .openURL:
                if let value = action.value, let url = URL(string: value) {
                    NSWorkspace.shared.open(url)
                }
            case .newSession, .none:
                break
            }
            #endif
        }
    }
}
