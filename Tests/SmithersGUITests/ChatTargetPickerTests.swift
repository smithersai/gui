import XCTest
@testable import SmithersGUI

final class ChatTargetPickerTests: XCTestCase {

    func testBuildChatTargetsIncludesSmithersAsRecommendedFirstOption() {
        let targets = buildChatTargets(from: [])

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].id, "smithers")
        XCTAssertEqual(targets[0].kind, .smithers)
        XCTAssertTrue(targets[0].recommended)
        XCTAssertTrue(targets[0].usable)
    }

    func testBuildChatTargetsIncludesOnlyUsableExternalAgents() {
        let targets = buildChatTargets(from: [
            SmithersAgent(
                id: "codex",
                name: "Codex",
                command: "codex",
                binaryPath: "/usr/local/bin/codex",
                status: "api-key",
                hasAuth: false,
                hasAPIKey: true,
                usable: true,
                roles: ["coding", "implement"],
                version: nil,
                authExpired: nil
            ),
            SmithersAgent(
                id: "forge",
                name: "Forge",
                command: "forge",
                binaryPath: "",
                status: "unavailable",
                hasAuth: false,
                hasAPIKey: false,
                usable: false,
                roles: ["coding"],
                version: nil,
                authExpired: nil
            ),
        ])

        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets[1].id, "codex")
        XCTAssertEqual(targets[1].kind, .externalAgent)
        XCTAssertEqual(targets[1].binary, "/usr/local/bin/codex")
    }

    func testBuildChatTargetsFallsBackToCommandWhenBinaryPathMissing() {
        let targets = buildChatTargets(from: [
            SmithersAgent(
                id: "opencode",
                name: "OpenCode",
                command: "opencode",
                binaryPath: "",
                status: "binary-only",
                hasAuth: false,
                hasAPIKey: false,
                usable: true,
                roles: ["coding", "chat"],
                version: nil,
                authExpired: nil
            ),
        ])

        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets[1].binary, "opencode")
    }

    func testChatTargetStatusLabelMatchesTUISemantics() {
        XCTAssertEqual(chatTargetStatusLabel("likely-subscription"), "Signed in")
        XCTAssertEqual(chatTargetStatusLabel("api-key"), "API key")
        XCTAssertEqual(chatTargetStatusLabel("binary-only"), "Binary only")
        XCTAssertEqual(chatTargetStatusLabel("other"), "Available")
    }
}
