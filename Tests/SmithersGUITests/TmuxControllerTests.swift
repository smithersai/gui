import Foundation
import XCTest
@testable import SmithersGUI

final class TmuxControllerTests: XCTestCase {
    private func makeFakeTmuxExecutable() throws -> URL {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let executableURL = tempDirectory.appendingPathComponent("tmux")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        return executableURL
    }

    func testAttachCommandUsesQuotedExecutableAndArguments() throws {
        let executableURL = try makeFakeTmuxExecutable()

        let command = TmuxController.attachCommand(
            socketName: "smithers-socket",
            sessionName: "smithers-session",
            environment: ["PATH": executableURL.deletingLastPathComponent().path]
        )

        XCTAssertEqual(
            command,
            "'\(executableURL.path)' -L 'smithers-socket' attach-session -t 'smithers-session'"
        )
    }

    func testAttachCommandEscapesSingleQuotes() throws {
        let executableURL = try makeFakeTmuxExecutable()

        let command = TmuxController.attachCommand(
            socketName: "sock'et",
            sessionName: "sess'ion",
            environment: ["PATH": executableURL.deletingLastPathComponent().path]
        )

        XCTAssertEqual(
            command,
            "'\(executableURL.path)' -L 'sock'\\''et' attach-session -t 'sess'\\''ion'"
        )
    }

    func testAttachCommandReturnsNilWhenInputsAreMissing() throws {
        let executableURL = try makeFakeTmuxExecutable()
        let environment = ["PATH": executableURL.deletingLastPathComponent().path]

        XCTAssertNil(TmuxController.attachCommand(socketName: nil, sessionName: "session", environment: environment))
        XCTAssertNil(TmuxController.attachCommand(socketName: "socket", sessionName: nil, environment: environment))
        XCTAssertNil(TmuxController.attachCommand(socketName: "   ", sessionName: "session", environment: environment))
        XCTAssertNil(TmuxController.attachCommand(socketName: "socket", sessionName: "\n", environment: environment))
    }

    func testSocketNameIsStableForSameWorkingDirectory() {
        let first = TmuxController.socketName(for: "/tmp/project")
        let second = TmuxController.socketName(for: "/tmp/project")
        XCTAssertEqual(first, second)
    }

    func testSocketNameDiffersForDifferentWorkingDirectories() {
        let first = TmuxController.socketName(for: "/tmp/project-a")
        let second = TmuxController.socketName(for: "/tmp/project-b")
        XCTAssertNotEqual(first, second)
    }

    func testRootSurfaceIDUsesTerminalIDSuffix() {
        XCTAssertEqual(TmuxController.rootSurfaceId(for: "term-123"), "term-123-root")
    }

    func testSessionNameSanitizesSurfaceID() {
        let session = TmuxController.sessionName(for: "My Surface#1")
        XCTAssertEqual(session, "smt-my-surface-1")
    }

    func testSessionNameFallsBackToHashWhenIdentifierHasNoValidCharacters() {
        let session = TmuxController.sessionName(for: "!!!")
        XCTAssertTrue(session.hasPrefix("smt-"))
        XCTAssertFalse(session.contains("!"))
        XCTAssertGreaterThan(session.count, 4)
    }
}
