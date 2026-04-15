import XCTest
@testable import SmithersGUI

final class DeveloperDebugModeTests: XCTestCase {
    func testEnvironmentTrueEnablesDebugMode() {
        XCTAssertTrue(
            DeveloperDebugMode.isEnabled(
                environment: [DeveloperDebugMode.environmentKey: "1"],
                arguments: ["SmithersGUI"],
                isDebugBuild: false
            )
        )
    }

    func testEnvironmentFalseDisablesDebugBuildDefault() {
        XCTAssertFalse(
            DeveloperDebugMode.isEnabled(
                environment: [DeveloperDebugMode.environmentKey: "false"],
                arguments: ["SmithersGUI"],
                isDebugBuild: true
            )
        )
    }

    func testLaunchArgumentEnablesDebugMode() {
        XCTAssertTrue(
            DeveloperDebugMode.isEnabled(
                environment: [:],
                arguments: ["SmithersGUI", "--developer-debug"],
                isDebugBuild: false
            )
        )
    }

    func testDisableArgumentWins() {
        XCTAssertFalse(
            DeveloperDebugMode.isEnabled(
                environment: [DeveloperDebugMode.environmentKey: "1"],
                arguments: ["SmithersGUI", "--no-developer-debug"],
                isDebugBuild: true
            )
        )
    }
}

@MainActor
final class DeveloperDebugSnapshotTests: XCTestCase {
    func testSnapshotCapturesRuntimeStoreAndLogState() {
        let store = SessionStore()
        let smithers = SmithersClient(cwd: "/tmp/smithers-debug")
        let activeId = store.activeSessionId

        store.sessions[0].title = "Debug Session"
        store.sessions[0].preview = "Investigate debug panel state"
        store.sessions[0].agent.messages = [
            ChatMessage(
                id: "m1",
                type: .user,
                content: "Inspect current state",
                timestamp: "just now",
                command: nil,
                diff: nil
            ),
        ]
        store.addRunTab(runId: "run-123456789", title: "Deploy Preview", preview: "running")

        let stats = LogFileStats(
            fileURL: URL(fileURLWithPath: "/tmp/smithers-debug.log"),
            sizeBytes: 2048,
            entryCount: 12,
            droppedWriteCount: 1,
            lastWriteError: "disk full"
        )

        let snapshot = DeveloperDebugSnapshot.capture(
            store: store,
            smithers: smithers,
            destination: .liveRun(runId: "run-123456789", nodeId: "node-a"),
            logStats: stats,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(snapshot.destinationLabel, "Live Run")
        XCTAssertEqual(snapshot.destinationDetails, "liveRun run=run-123456789 node=node-a")
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].id, activeId!)
        XCTAssertEqual(snapshot.sessions[0].title, "Debug Session")
        XCTAssertEqual(snapshot.sessions[0].messageCount, 1)
        XCTAssertEqual(snapshot.runTabs.count, 1)
        XCTAssertEqual(snapshot.runTabs[0].id, "run-123456789")
        XCTAssertEqual(snapshot.recentMessages.map(\.preview), ["Inspect current state"])
        XCTAssertTrue(snapshot.logRows.contains { $0.label == "Entries" && $0.value == "12" })
        XCTAssertTrue(snapshot.logRows.contains { $0.label == "Size" && $0.value == "2 KB" })
        XCTAssertTrue(snapshot.logRows.contains { $0.label == "Dropped writes" && $0.tone == .danger })
    }
}
