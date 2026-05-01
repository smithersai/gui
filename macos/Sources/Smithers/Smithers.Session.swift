import Foundation

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
        }

        let id = UUID()
        @Published private(set) var title: String
        @Published private(set) var kind: Kind

        private let app: App
        private let workspacePath: String?
        private let targetID: String?

        init(app: App, kind: Kind, workspacePath: String? = nil, targetID: String? = nil) {
            self.app = app
            self.kind = kind
            self.workspacePath = workspacePath
            self.targetID = targetID
            self.title = Self.defaultTitle(kind: kind, targetID: targetID)
        }

        func refresh() {
            title = Self.defaultTitle(kind: kind, targetID: targetID)
        }

        func sendText(_ text: String) {
            _ = text
        }

        func events() -> AsyncStream<Event> {
            AsyncStream { continuation in continuation.finish() }
        }

        private static func defaultTitle(kind: Kind, targetID: String?) -> String {
            switch (kind, targetID?.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case (.chat, let id?) where !id.isEmpty: return "Chat \(id)"
            case (.runInspect, let id?) where !id.isEmpty: return "Run \(id)"
            case (.workflow, let id?) where !id.isEmpty: return "Workflow \(id)"
            case (.terminal, _): return "Terminal"
            case (.memory, _): return "Memory"
            case (.dashboard, _): return "Dashboard"
            default: return kind.rawValue
            }
        }
    }
}
