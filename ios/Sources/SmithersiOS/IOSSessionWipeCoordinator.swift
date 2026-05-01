#if os(iOS)
import Foundation
import SmithersAuth

@MainActor
protocol IOSSessionResetParticipant: AnyObject {
    func resetForSignOut()
}

@MainActor
final class IOSSessionWipeCoordinator: SessionWipeHandler {
    static let shared = IOSSessionWipeCoordinator()

    private var resetParticipants: [UUID: () -> Void] = [:]
    private var runtimeResetter: (() -> Void)?

    private init() {}

    func registerRuntimeResetter(_ resetter: @escaping () -> Void) {
        runtimeResetter = resetter
    }

    func registerResetParticipant(_ participant: @escaping () -> Void) -> UUID {
        let id = UUID()
        resetParticipants[id] = participant
        return id
    }

    func unregisterResetParticipant(_ id: UUID) {
        resetParticipants[id] = nil
    }

    nonisolated func wipeAfterSignOut() {
        Task { @MainActor in
            runtimeResetter?()
            resetParticipants.values.forEach { $0() }
            try? SettingsLocalCache.resetWithoutActiveRuntime()
        }
    }
}
#endif
