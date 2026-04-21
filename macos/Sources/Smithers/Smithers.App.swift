import Foundation
import SwiftUI
import CSmithersKit

#if os(macOS)
import AppKit
import UserNotifications
#endif

extension Notification.Name {
    static let smithersStateChanged = Notification.Name("smithers.stateChanged")
    static let smithersAction = Notification.Name("smithers.action")
}

extension Smithers {
    class App: ObservableObject {
        @Published var readiness: Readiness = .loading
        @Published var app: smithers_app_t? {
            didSet {
                #if !SMITHERS_STUB
                if let oldValue {
                    smithers_app_free(oldValue)
                }
                #endif
            }
        }

        init() {
            #if SMITHERS_STUB
            readiness = .ready
            #else
            var config = smithers_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                wakeup: { userdata in App.wakeup(userdata) },
                action: { app, target, action in
                    guard let app else { return false }
                    return App.action(app, target: target, action: action)
                },
                read_clipboard: { userdata, out in App.readClipboard(userdata, out: out) },
                write_clipboard: { userdata, text in App.writeClipboard(userdata, text: text) },
                state_changed: { userdata in App.stateChanged(userdata) },
                log: { userdata, level, message in App.log(userdata, level: level, message: message) }
            )
            guard let created = smithers_app_new(&config) else {
                readiness = .error
                return
            }
            app = created
            readiness = .ready
            #endif
        }

        deinit {
            #if !SMITHERS_STUB
            if let app {
                smithers_app_free(app)
            }
            #endif
        }

        func tick() {
            #if !SMITHERS_STUB
            guard let app else { return }
            smithers_app_tick(app)
            #endif
        }

        func setColorScheme(_ scheme: ColorScheme) {
            #if !SMITHERS_STUB
            guard let app else { return }
            smithers_app_set_color_scheme(app, scheme.cValue)
            #endif
        }

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata else { return }
            let state = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { state.tick() }
        }

        static func action(_ app: smithers_app_t, target: smithers_action_target_s, action: smithers_action_s) -> Bool {
            let wrapped = Action(cValue: action)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .smithersAction,
                    object: nil,
                    userInfo: ["action": wrapped]
                )
            }

            #if os(macOS)
            switch action.tag {
            case SMITHERS_ACTION_CLIPBOARD_WRITE:
                if let text = wrapped.value {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    return true
                }
            case SMITHERS_ACTION_OPEN_URL:
                if let value = wrapped.value, let url = URL(string: value) {
                    NSWorkspace.shared.open(url)
                    return true
                }
            case SMITHERS_ACTION_DESKTOP_NOTIFY:
                let content = UNMutableNotificationContent()
                content.title = wrapped.title ?? "Smithers"
                content.body = wrapped.body ?? ""
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request)
                return true
            default:
                break
            }
            #endif

            return false
        }

        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            out: UnsafeMutablePointer<smithers_string_s>?
        ) -> Bool {
            #if os(macOS)
            guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
                return false
            }
            // The ABI does not currently define a host-owned string free callback,
            // so avoid handing transient Swift storage to the core.
            _ = value
            return false
            #else
            return false
            #endif
        }

        static func writeClipboard(_ userdata: UnsafeMutableRawPointer?, text: UnsafePointer<CChar>?) {
            #if os(macOS)
            guard let text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: text), forType: .string)
            #endif
        }

        static func stateChanged(_ userdata: UnsafeMutableRawPointer?) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .smithersStateChanged, object: nil)
            }
        }

        static func log(_ userdata: UnsafeMutableRawPointer?, level: Int32, message: UnsafePointer<CChar>?) {
            guard let message else { return }
            AppLogger.network.debug("libsmithers", metadata: [
                "level": String(level),
                "message": String(cString: message),
            ])
        }
    }
}
