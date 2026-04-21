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
        private var eventStream: EventStream?

        var unsafeCValue: smithers_session_t? {
            session
        }

        init(app: App, kind: Kind, workspacePath: String? = nil, targetID: String? = nil) {
            self.app = app
            self.kind = kind
            self.title = kind.rawValue

            #if !SMITHERS_STUB
            guard let cApp = app.app else { return }
            var created: smithers_session_t?
            workspacePath.withOptionalCString { workspacePtr in
                targetID.withOptionalCString { targetPtr in
                    var options = smithers_session_options_s(
                        kind: kind.cValue,
                        workspace_path: workspacePtr,
                        target_id: targetPtr,
                        userdata: Unmanaged.passUnretained(self).toOpaque()
                    )
                    created = smithers_session_new(cApp, options)
                }
            }
            session = created
            refresh()
            #endif
        }

        deinit {
            #if !SMITHERS_STUB
            if let session {
                smithers_session_free(session)
            }
            #endif
        }

        func refresh() {
            #if !SMITHERS_STUB
            guard let session else { return }
            kind = Kind(cValue: smithers_session_kind(session))
            title = Smithers.string(from: smithers_session_title(session))
            #endif
        }

        func sendText(_ text: String) {
            #if !SMITHERS_STUB
            guard let session else { return }
            text.withCString { ptr in
                smithers_session_send_text(session, ptr, text.utf8.count)
            }
            #endif
        }

        func events() -> AsyncStream<Event> {
            #if SMITHERS_STUB
            return AsyncStream { continuation in continuation.finish() }
            #else
            guard let session else {
                return AsyncStream { continuation in continuation.finish() }
            }
            let stream = EventStream(smithers_session_events(session))
            eventStream = stream
            return AsyncStream { continuation in
                let task = Task {
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
            #endif
        }
    }
}
