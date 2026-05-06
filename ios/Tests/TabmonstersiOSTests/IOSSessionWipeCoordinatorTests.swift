#if os(iOS)
import Foundation
import XCTest
@testable import TabmonstersiOS

@MainActor
final class IOSSessionWipeCoordinatorTests: XCTestCase {
    func test_tokenManagerLocalSignOut_callsWipeHandler() async throws {
        let client = OAuth2Client(config: OAuth2ClientConfig(
            baseURL: URL(string: "https://example.test")!,
            clientID: "ios-tests",
            redirectURI: "smithers://oauth2/callback",
            scopes: ["read:user"]
        ))
        let tokens = OAuth2Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        let store = InMemoryTokenStore(initial: tokens)
        let wipe = CountingWipeHandler()
        let manager = TokenManager(client: client, store: store, wipeHandler: wipe)

        await manager.localSignOut()

        XCTAssertEqual(wipe.count, 1)
    }

    func test_wipeCoordinator_resetsRuntimeAndUserScopedState() async throws {
        let coordinator = IOSSessionWipeCoordinator.shared
        let runtimeStopped = LockedBox(false)
        let resetCount = LockedBox(0)

        coordinator.registerRuntimeResetter {
            runtimeStopped.withValue { $0 = true }
        }
        let token = coordinator.registerResetParticipant {
            resetCount.withValue { $0 += 1 }
        }

        coordinator.wipeAfterSignOut()
        let completed = await waitUntil(timeout: 1) {
            runtimeStopped.withValue { $0 } && resetCount.withValue { $0 == 1 }
        }

        XCTAssertTrue(completed)
        coordinator.unregisterResetParticipant(token)
    }

    func test_wipeCoordinator_clearsStaleRowsForNextSyntheticUser() async throws {
        let coordinator = IOSSessionWipeCoordinator.shared
        let rows = LockedBox(["ws-user-a-1", "ws-user-a-2"])

        let token = coordinator.registerResetParticipant {
            rows.withValue { $0.removeAll() }
        }

        coordinator.wipeAfterSignOut()

        let cleared = await waitUntil(timeout: 1) {
            rows.withValue { $0.isEmpty }
        }
        XCTAssertTrue(cleared)

        rows.withValue { $0 = ["ws-user-b-1"] }
        XCTAssertEqual(rows.withValue { $0 }, ["ws-user-b-1"])
        coordinator.unregisterResetParticipant(token)
    }

    func test_wipeCoordinator_withActiveTransport_stopsBeforeClearingParticipants() async throws {
        let coordinator = IOSSessionWipeCoordinator.shared
        let events = LockedBox<[String]>([])

        coordinator.registerRuntimeResetter {
            events.withValue { $0.append("transportStopped") }
        }
        let token = coordinator.registerResetParticipant {
            events.withValue { $0.append("stateCleared") }
        }

        coordinator.wipeAfterSignOut()

        let completed = await waitUntil(timeout: 1) {
            events.withValue { $0.count >= 2 }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(events.withValue { $0.prefix(2).map { $0 } }, ["transportStopped", "stateCleared"])
        coordinator.unregisterResetParticipant(token)
    }

    func test_wipeCoordinator_removesRuntimeCacheArtifacts() async throws {
        let cacheDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("SmithersRuntime", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let staleFile = cacheDirectory.appendingPathComponent("stale-row.json")
        try Data("stale".utf8).write(to: staleFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleFile.path))

        IOSSessionWipeCoordinator.shared.wipeAfterSignOut()

        let completed = await waitUntil(timeout: 1) {
            !FileManager.default.fileExists(atPath: staleFile.path) &&
                FileManager.default.fileExists(atPath: cacheDirectory.path)
        }
        XCTAssertTrue(completed)
    }
}

private final class CountingWipeHandler: SessionWipeHandler {
    private(set) var count: Int = 0

    func wipeAfterSignOut() {
        count += 1
    }
}
#endif
