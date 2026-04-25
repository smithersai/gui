import Foundation

/// Keeps per-run live inspector state alive across view mount/unmount cycles.
///
/// Run tabs can be backgrounded while another workspace is focused. If we tied
/// streaming state to `LiveRunView` lifetime, switching tabs would tear down
/// the stream and defeat cursor-based reconnect semantics.
@MainActor
final class LiveRunSessionRegistry {
    struct Session {
        let client: DevToolsClient
        let store: DevToolsStore
        let lastLogStore: LastLogPerNodeStore
    }

    static let shared = LiveRunSessionRegistry()

    private var sessions: [String: Session] = [:]
    private var pinnedRunTabs: Set<String> = []

    private init() {}

    func pinRunTab(runId: String) {
        guard !runId.isEmpty else { return }
        pinnedRunTabs.insert(runId)
    }

    func unpinRunTab(runId: String) {
        guard !runId.isEmpty else { return }
        pinnedRunTabs.remove(runId)
        teardownSession(runId: runId)
    }

    func isPinned(runId: String) -> Bool {
        pinnedRunTabs.contains(runId)
    }

    func session(for runId: String, smithers: SmithersClient) -> Session {
        if let existing = sessions[runId] {
            return existing
        }

        let client = DevToolsClient(smithers: smithers)
        let store = DevToolsStore(streamProvider: client)
        let lastLogStore = LastLogPerNodeStore(
            streamProvider: smithers,
            historyProvider: smithers
        )

        let created = Session(
            client: client,
            store: store,
            lastLogStore: lastLogStore
        )
        sessions[runId] = created
        return created
    }

    func releaseIfUnpinned(runId: String) {
        guard !isPinned(runId: runId) else { return }
        teardownSession(runId: runId)
    }

    func resetForTests() {
        let runIds = Set(sessions.keys).union(pinnedRunTabs)
        for runId in runIds {
            teardownSession(runId: runId)
        }
        pinnedRunTabs.removeAll()
    }

    private func teardownSession(runId: String) {
        guard let existing = sessions.removeValue(forKey: runId) else { return }
        existing.store.disconnect()
        existing.lastLogStore.disconnect()
    }
}
