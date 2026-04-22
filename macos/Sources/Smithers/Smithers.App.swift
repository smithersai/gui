import Foundation
import SwiftUI
import CSmithersKit

#if os(macOS)
import AppKit
import UserNotifications

private let clipboardReadBuffer = ClipboardReadBuffer()

private final class ClipboardReadBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []

    func write(_ string: String, into out: UnsafeMutablePointer<smithers_string_s>) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        storage = Array(string.utf8) + [0]
        guard !storage.isEmpty else {
            return false
        }

        return storage.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            out.pointee = smithers_string_s(
                ptr: UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CChar.self),
                len: string.utf8.count
            )
            return true
        }
    }
}
#endif

extension Notification.Name {
    static let smithersStateChanged = Notification.Name("smithers.stateChanged")
    static let smithersAction = Notification.Name("smithers.action")
}

extension Smithers {
    @MainActor
    class App: ObservableObject {
        @Published var readiness: Readiness = .loading
        @Published private(set) var app: smithers_app_t?

        nonisolated(unsafe) private let appHandle = MainThreadAppHandle()
        nonisolated(unsafe) private let persistenceHandle = PersistenceHandle()

        init(
            databasePath: String? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            let dbPath = Self.resolveAppDatabasePath(override: databasePath, environment: environment)
            let userdata = Unmanaged.passUnretained(self).toOpaque()

            func makeConfig(dbCStr: UnsafePointer<CChar>?) -> smithers_runtime_config_s {
                smithers_runtime_config_s(
                    userdata: userdata,
                    wakeup: { userdata in App.wakeup(userdata) },
                    action: { app, target, action in
                        guard let app else { return false }
                        return App.action(app, target: target, action: action)
                    },
                    read_clipboard: { userdata, out in App.readClipboard(userdata, out: out) },
                    write_clipboard: { userdata, text in App.writeClipboard(userdata, text: text) },
                    state_changed: { userdata in App.stateChanged(userdata) },
                    log: { userdata, level, message in App.log(userdata, level: level, message: message) },
                    recents_db_path: dbCStr
                )
            }

            let created: smithers_app_t? = {
                if let dbPath {
                    return dbPath.withCString { ptr in
                        var config = makeConfig(dbCStr: ptr)
                        return smithers_app_new(&config)
                    }
                }
                var config = makeConfig(dbCStr: nil)
                return smithers_app_new(&config)
            }()

            guard let created else {
                readiness = .error
                return
            }
            appHandle.replace(created)
            app = created
            if let dbPath {
                var openError = smithers_error_s(code: 0, msg: nil)
                let persistence = dbPath.withCString { smithers_persistence_open($0, &openError) }
                if let message = Smithers.message(from: openError) {
                    AppLogger.ui.warning("Failed to open session persistence", metadata: [
                        "dbPath": dbPath,
                        "error": message,
                    ])
                }
                persistenceHandle.replace(persistence)
            }
            readiness = .ready
        }

        func persistence() -> smithers_persistence_t? {
            persistenceHandle.value
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
            let fm = FileManager.default
            let dir = url.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                AppLogger.ui.warning("Failed to create app support directory", metadata: ["error": "\(error)"])
                return nil
            }
            return url.path
        }

        deinit {
            appHandle.replace(nil)
            persistenceHandle.replace(nil)
        }

        func tick() {
            guard let app else { return }
            smithers_app_tick(app)
        }

        func setColorScheme(_ scheme: ColorScheme) {
            guard let app else { return }
            smithers_app_set_color_scheme(app, scheme.cValue)
        }

        nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata else { return }
            let state = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in state.tick() }
        }

        nonisolated static func action(_ app: smithers_app_t, target: smithers_action_target_s, action: smithers_action_s) -> Bool {
            switch target.tag {
            case SMITHERS_ACTION_TARGET_APP, SMITHERS_ACTION_TARGET_SESSION:
                break
            default:
                AppLogger.network.warning("libsmithers unknown action target", metadata: ["target": String(target.tag.rawValue)])
                return false
            }

            let wrapped = Action(cValue: action)
            let shouldPostAction = action.tag != SMITHERS_ACTION_NEW_SESSION || target.tag == SMITHERS_ACTION_TARGET_APP
            if shouldPostAction {
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: .smithersAction,
                        object: nil,
                        userInfo: ["action": wrapped]
                    )
                }
            }

            switch action.tag {
            case SMITHERS_ACTION_NONE:
                return true
            case SMITHERS_ACTION_SHOW_TOAST,
                 SMITHERS_ACTION_DESKTOP_NOTIFY,
                 SMITHERS_ACTION_CLIPBOARD_WRITE,
                 SMITHERS_ACTION_OPEN_URL:
                Task { @MainActor in perform(action: wrapped) }
                return true
            case SMITHERS_ACTION_NEW_SESSION:
                return true
            case SMITHERS_ACTION_OPEN_WORKSPACE,
                 SMITHERS_ACTION_CLOSE_WORKSPACE,
                 SMITHERS_ACTION_CLOSE_SESSION,
                 SMITHERS_ACTION_FOCUS_SESSION,
                 SMITHERS_ACTION_PRESENT_COMMAND_PALETTE,
                 SMITHERS_ACTION_DISMISS_COMMAND_PALETTE,
                 SMITHERS_ACTION_RUN_STARTED,
                 SMITHERS_ACTION_RUN_FINISHED,
                 SMITHERS_ACTION_RUN_STATE_CHANGED,
                 SMITHERS_ACTION_APPROVAL_REQUESTED,
                 SMITHERS_ACTION_CONFIG_CHANGED:
                AppLogger.network.warning("libsmithers action is not handled by macOS shell", metadata: ["tag": String(action.tag.rawValue)])
                return false
            default:
                AppLogger.network.warning("libsmithers unknown action", metadata: ["tag": String(action.tag.rawValue)])
                return false
            }
        }

        @MainActor
        private static func perform(action: Action) {
            #if os(macOS)
            switch action.tag {
            case SMITHERS_ACTION_SHOW_TOAST:
                let content = UNMutableNotificationContent()
                content.title = action.title ?? "Smithers"
                content.body = action.body ?? ""
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request)
            case SMITHERS_ACTION_CLIPBOARD_WRITE:
                if let text = action.value {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case SMITHERS_ACTION_OPEN_URL:
                if let value = action.value, let url = URL(string: value) {
                    NSWorkspace.shared.open(url)
                }
            case SMITHERS_ACTION_DESKTOP_NOTIFY:
                let content = UNMutableNotificationContent()
                content.title = action.title ?? "Smithers"
                content.body = action.body ?? ""
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request)
            default:
                break
            }
            #endif
        }

        nonisolated static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            out: UnsafeMutablePointer<smithers_string_s>?
        ) -> Bool {
            _ = userdata
            #if os(macOS)
            guard let out else {
                return false
            }

            let string: String? = if Thread.isMainThread {
                NSPasteboard.general.string(forType: .string)
            } else {
                DispatchQueue.main.sync {
                    NSPasteboard.general.string(forType: .string)
                }
            }
            guard let string else {
                return false
            }

            return clipboardReadBuffer.write(string, into: out)
            #else
            _ = out
            return false
            #endif
        }

        nonisolated static func writeClipboard(_ userdata: UnsafeMutableRawPointer?, text: UnsafePointer<CChar>?) {
            _ = userdata
            #if os(macOS)
            guard let text else { return }
            let value = String(cString: text)
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            #endif
        }

        nonisolated static func stateChanged(_ userdata: UnsafeMutableRawPointer?) {
            _ = userdata
            Task { @MainActor in
                NotificationCenter.default.post(name: .smithersStateChanged, object: nil)
            }
        }

        nonisolated static func log(_ userdata: UnsafeMutableRawPointer?, level: Int32, message: UnsafePointer<CChar>?) {
            _ = userdata
            guard let message else { return }
            AppLogger.network.debug("libsmithers", metadata: [
                "level": String(level),
                "message": String(cString: message),
            ])
        }
    }
}

private final class MainThreadAppHandle {
    private var app: smithers_app_t?

    func replace(_ newValue: smithers_app_t?) {
        if let app {
            Self.free(app)
        }
        app = newValue
    }

    deinit {
        if let app {
            Self.free(app)
        }
    }

    private static func free(_ app: smithers_app_t) {
        if Thread.isMainThread {
            smithers_app_free(app)
        } else {
            DispatchQueue.main.sync {
                smithers_app_free(app)
            }
        }
    }
}

private final class PersistenceHandle {
    private var persistence: smithers_persistence_t?

    var value: smithers_persistence_t? {
        persistence
    }

    func replace(_ newValue: smithers_persistence_t?) {
        if let persistence {
            smithers_persistence_close(persistence)
        }
        persistence = newValue
    }

    deinit {
        if let persistence {
            smithers_persistence_close(persistence)
        }
    }
}
