import XCTest
@testable import SmithersGUI

final class ChatTargetPickerTests: XCTestCase {
    func testBuildChatTargetsIncludesRecommendedSmithersFirst() {
        let targets = buildChatTargets(from: [])

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].id, "smithers")
        XCTAssertEqual(targets[0].kind, .smithers)
        XCTAssertTrue(targets[0].recommended)
        XCTAssertTrue(targets[0].usable)
    }

    func testBuildChatTargetsIncludesOnlyUsableAgents() {
        let targets = buildChatTargets(from: [
            SmithersAgent(
                id: "codex",
                name: "Codex",
                command: "codex",
                binaryPath: "/usr/local/bin/codex",
                status: "binary-only",
                hasAuth: false,
                hasAPIKey: false,
                usable: true,
                roles: ["coding"],
                version: nil,
                authExpired: nil
            ),
            SmithersAgent(
                id: "gemini",
                name: "Gemini",
                command: "gemini",
                binaryPath: "",
                status: "unavailable",
                hasAuth: false,
                hasAPIKey: false,
                usable: false,
                roles: ["research"],
                version: nil,
                authExpired: nil
            ),
        ])

        XCTAssertEqual(targets.map(\.id), ["smithers", "codex"])
        XCTAssertFalse(targets.contains(where: { $0.id == "gemini" }))
    }

    func testBuildChatTargetsFallsBackToCommandWhenBinaryPathMissing() {
        let targets = buildChatTargets(from: [
            SmithersAgent(
                id: "codex",
                name: "Codex",
                command: "codex",
                binaryPath: "",
                status: "binary-only",
                hasAuth: false,
                hasAPIKey: false,
                usable: true,
                roles: ["coding"],
                version: nil,
                authExpired: nil
            ),
        ])

        XCTAssertEqual(targets[1].binary, "codex")
    }

    func testChatTargetStatusLabelMatchesExpectedValues() {
        XCTAssertEqual(chatTargetStatusLabel("likely-subscription"), "Signed in")
        XCTAssertEqual(chatTargetStatusLabel("api-key"), "API key")
        XCTAssertEqual(chatTargetStatusLabel("binary-only"), "Binary only")
        XCTAssertEqual(chatTargetStatusLabel("other"), "Available")
    }
}
