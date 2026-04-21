import Foundation
import CSmithersKit

extension Smithers {
    @MainActor
    final class Session: ObservableObject, Identifiable {
        enum Kind: String, Codable, Hashable {
            case terminal
            case chat
            case runInspect
            case workflow
            case memory
            case dashboard

            var cValue: smithers_session_kind_e {
                switch self {
                case .terminal: return SMITHERS_SESSION_KIND_TERMINAL
                case .chat: return SMITHERS_SESSION_KIND_CHAT
                case .runInspect: return SMITHERS_SESSION_KIND_RUN_INSPECT
                case .workflow: return SMITHERS_SESSION_KIND_WORKFLOW
                case .memory: return SMITHERS_SESSION_KIND_MEMORY
                case .dashboard: return SMITHERS_SESSION_KIND_DASHBOARD
                }
            }

            init(cValue: smithers_session_kind_e) {
                switch cValue {
                case SMITHERS_SESSION_KIND_CHAT: self = .chat
                case SMITHERS_SESSION_KIND_RUN_INSPECT: self = .runInspect
                case SMITHERS_SESSION_KIND_WORKFLOW: self = .workflow
                case SMITHERS_SESSION_KIND_MEMORY: self = .memory
                case SMITHERS_SESSION_KIND_DASHBOARD: self = .dashboard
                default: self = .terminal
                }
            }
        }

        let id = UUID()
        @Published private(set) var title: String
        @Published private(set) var kind: Kind

        private let app: App
        private var session: smithers_session_t?
        nonisolated(unsafe) private let sessionHandle = MainThreadSessionHandle()

        var unsafeCValue: smithers_session_t? {
            session
        }

        init(app: App, kind: Kind, workspacePath: String? = nil, targetID: String? = nil) {
            self.app = app
            self.kind = kind
            self.title = kind.rawValue

            guard let cApp = app.app else { return }
            var created: smithers_session_t?
            workspacePath.withOptionalCString { workspacePtr in
                targetID.withOptionalCString { targetPtr in
                    let options = smithers_session_options_s(
                        kind: kind.cValue,
                        workspace_path: workspacePtr,
                        target_id: targetPtr,
                        userdata: Unmanaged.passUnretained(self).toOpaque()
                    )
                    created = smithers_session_new(cApp, options)
                }
            }
            session = created
            sessionHandle.replace(created)
            refresh()
        }

        deinit {
            sessionHandle.replace(nil)
        }

        func refresh() {
            guard let session else { return }
            kind = Kind(cValue: smithers_session_kind(session))
            title = Smithers.string(from: smithers_session_title(session))
        }

        func sendText(_ text: String) {
            guard let session else { return }
            text.withCString { ptr in
                smithers_session_send_text(session, ptr, text.utf8.count)
            }
        }

        func events() -> AsyncStream<Event> {
            guard let session else {
                return AsyncStream { continuation in continuation.finish() }
            }
            let stream = EventStream(smithers_session_events(session))
            return AsyncStream { continuation in
                let task = Task.detached {
                    while !Task.isCancelled {
                        let event = stream.next()
                        switch event.tag {
                        case .none:
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        case .end:
                            continuation.finish()
                            return
                        default:
                            continuation.yield(event)
                        }
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

private final class MainThreadSessionHandle {
    private var session: smithers_session_t?

    func replace(_ newValue: smithers_session_t?) {
        if let session {
            Self.free(session)
        }
        session = newValue
    }

    deinit {
        if let session {
            Self.free(session)
        }
    }

    private static func free(_ session: smithers_session_t) {
        if Thread.isMainThread {
            smithers_session_free(session)
        } else {
            DispatchQueue.main.sync {
                smithers_session_free(session)
            }
        }
    }
}
