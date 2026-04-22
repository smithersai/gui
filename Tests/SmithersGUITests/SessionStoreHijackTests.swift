import XCTest
@testable import SmithersGUI

#if os(macOS)
import AppKit
#endif

@MainActor
final class SessionStoreHijackTests: XCTestCase {
    func testAddTerminalTabWithRunIdAndHijackCreatesChatSession() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let hijack = makeHijack()
        let terminalId = store.addTerminalTab(
            title: "Hijacked Run",
            workingDirectory: context.workspacePath,
            command: "smithers hijack --resume",
            runId: "run-123",
            hijack: hijack
        )

        XCTAssertEqual(store.sessionKind(forTerminalId: terminalId), .chat)
        XCTAssertEqual(store.terminalTab(forRunId: "run-123")?.terminalId, terminalId)
        XCTAssertEqual(store.terminalTab(forRunId: "run-123")?.hijack, hijack)

        let workspace = store.ensureTerminalWorkspace(terminalId)
        XCTAssertEqual(workspace.orderedSurfaces.first?.runId, "run-123")
    }

    func testTerminalTabForRunIdReturnsBoundTab() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        _ = store.addTerminalTab(title: "Plain Terminal", workingDirectory: context.workspacePath, command: "zsh")
        let hijackedId = store.addTerminalTab(
            title: "Bound Terminal",
            workingDirectory: context.workspacePath,
            command: "smithers hijack --resume",
            runId: "run-lookup",
            hijack: makeHijack(agent: "codex", autoHijacked: true, resumeToken: nil)
        )

        let tab = try XCTUnwrap(store.terminalTab(forRunId: "run-lookup"))
        XCTAssertEqual(tab.terminalId, hijackedId)
        XCTAssertEqual(tab.runId, "run-lookup")
        XCTAssertNil(store.terminalTab(forRunId: "missing-run"))
    }

    func testTerminalWorkspaceRecordCodableRoundTripPreservesHijackFields() throws {
        let date = Date(timeIntervalSince1970: 1_735_171_200)
        let record = TerminalWorkspaceRecord(
            terminalId: "terminal-1",
            title: "Hijacked Run",
            preview: "smithers hijack --resume",
            timestamp: date,
            createdAt: date,
            workingDirectory: "/tmp/workspace",
            command: "smithers hijack --resume",
            backend: .native,
            rootSurfaceId: "surface-1",
            tmuxSocketName: nil,
            tmuxSessionName: nil,
            sessionId: "session-1",
            runId: "run-123",
            hijack: makeHijack(),
            isPinned: true,
            rootKind: .terminal,
            browserURLString: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(TerminalWorkspaceRecord.self, from: data)

        XCTAssertEqual(decoded.terminalId, record.terminalId)
        XCTAssertEqual(decoded.runId, "run-123")
        XCTAssertEqual(decoded.hijack, record.hijack)
        XCTAssertEqual(decoded.sessionId, "session-1")
        XCTAssertEqual(decoded.timestamp, date)
        XCTAssertEqual(decoded.createdAt, date)
    }

    func testTerminalWorkspaceRecordDecodesLegacyPayloadWithoutHijackFields() throws {
        let data = """
        {
          "terminalId": "terminal-legacy",
          "title": "Legacy",
          "preview": "zsh",
          "timestamp": 1735171200000,
          "createdAt": 1735171200000,
          "workingDirectory": "/tmp/workspace",
          "command": "zsh",
          "backend": "native",
          "rootSurfaceId": "surface-legacy",
          "isPinned": false,
          "rootKind": "terminal"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(TerminalWorkspaceRecord.self, from: data)

        XCTAssertEqual(decoded.terminalId, "terminal-legacy")
        XCTAssertNil(decoded.runId)
        XCTAssertNil(decoded.hijack)
        XCTAssertNil(decoded.sessionId)
    }

    #if os(macOS)
    func testPersistedHijackedTerminalRestoresChatSessionKind() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let firstStore = context.makeStore()
        let hijack = makeHijack(agent: "claude", autoHijacked: false, resumeToken: "resume-restore")
        let terminalId = firstStore.addTerminalTab(
            title: "Persisted Hijack",
            workingDirectory: context.workspacePath,
            command: "smithers hijack --resume",
            runId: "run-persisted",
            hijack: hijack
        )

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let reloadedStore = context.makeStore()
        let restoredTab = try XCTUnwrap(reloadedStore.terminalTab(forRunId: "run-persisted"))
        XCTAssertEqual(restoredTab.terminalId, terminalId)
        XCTAssertEqual(restoredTab.hijack, hijack)
        XCTAssertEqual(reloadedStore.sessionKind(forTerminalId: terminalId), .chat)
    }
    #endif

    private func makeHijack(
        agent: String = "claude",
        autoHijacked: Bool = false,
        resumeToken: String? = "resume-123"
    ) -> TerminalWorkspaceRecord.HijackBinding {
        TerminalWorkspaceRecord.HijackBinding(
            agent: agent,
            autoHijacked: autoHijacked,
            resumeToken: resumeToken
        )
    }

    private func makeStoreContext() throws -> StoreContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreHijackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        return StoreContext(
            root: root,
            workspacePath: workspaceURL.path,
            databasePath: root.appendingPathComponent("app.sqlite").path
        )
    }
}

private struct StoreContext {
    let root: URL
    let workspacePath: String
    let databasePath: String

    @MainActor
    func makeStore() -> SessionStore {
        SessionStore(
            workingDirectory: workspacePath,
            app: Smithers.App(databasePath: databasePath)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
