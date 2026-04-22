import XCTest
@testable import SmithersGUI

@MainActor
final class SessionStoreForkTests: XCTestCase {
    func testLaunchExternalAgentTabStampsClaudeKind() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.launchExternalAgentTab(name: "Claude", command: "claude")

        let tab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == terminalId })
        XCTAssertEqual(tab.agentKind, .claude)
        XCTAssertNil(tab.agentSessionId)
    }

    func testLaunchExternalAgentTabStampsCodexKind() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.launchExternalAgentTab(name: "Codex", command: "codex")

        let tab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == terminalId })
        XCTAssertEqual(tab.agentKind, .codex)
    }

    func testLaunchExternalAgentTabStampsGeminiKind() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.launchExternalAgentTab(name: "Gemini", command: "gemini")

        let tab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == terminalId })
        XCTAssertEqual(tab.agentKind, .gemini)
    }

    func testLaunchExternalAgentTabStampsKimiKind() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.launchExternalAgentTab(name: "Kimi", command: "kimi")

        let tab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == terminalId })
        XCTAssertEqual(tab.agentKind, .kimi)
    }

    func testLaunchExternalAgentTabWithUnknownCommandLeavesKindNil() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.launchExternalAgentTab(name: "Shell", command: "bash")

        let tab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == terminalId })
        XCTAssertNil(tab.agentKind)
    }

    func testCanForkReturnsFalseForMissingTerminal() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        XCTAssertFalse(store.canForkTerminalTab("does-not-exist"))
    }

    func testCanForkReturnsFalseWhenSessionIdMissing() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.launchExternalAgentTab(name: "Claude", command: "claude")
        XCTAssertFalse(store.canForkTerminalTab(terminalId))
    }

    func testCanForkReturnsFalseForGeminiEvenWithSessionId() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.launchExternalAgentTab(name: "Gemini", command: "gemini")
        if let idx = store.terminalTabs.firstIndex(where: { $0.terminalId == terminalId }) {
            store.terminalTabs[idx].agentSessionId = "any-id"
        }
        XCTAssertFalse(store.canForkTerminalTab(terminalId))
    }

    func testCanForkReturnsTrueForClaudeWithSessionId() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.launchExternalAgentTab(name: "Claude", command: "claude")
        let idx = try XCTUnwrap(store.terminalTabs.firstIndex(where: { $0.terminalId == terminalId }))
        store.terminalTabs[idx].agentSessionId = "11111111-2222-3333-4444-555555555555"

        XCTAssertTrue(store.canForkTerminalTab(terminalId))
    }

    func testForkTerminalTabProducesNewTabWithResumeFlagForClaude() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let originalId = store.launchExternalAgentTab(name: "Claude", command: "claude")
        let sessionId = "11111111-2222-3333-4444-555555555555"
        let idx = try XCTUnwrap(store.terminalTabs.firstIndex(where: { $0.terminalId == originalId }))
        store.terminalTabs[idx].agentSessionId = sessionId

        let forkedId = try XCTUnwrap(store.forkTerminalTab(originalId))
        XCTAssertNotEqual(forkedId, originalId)

        let forkedTab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == forkedId })
        XCTAssertEqual(forkedTab.agentKind, .claude)
        XCTAssertNotNil(forkedTab.command)
        XCTAssertTrue(forkedTab.command?.contains("--resume") == true)
        XCTAssertTrue(forkedTab.command?.contains(sessionId) == true)
    }

    func testForkTerminalTabProducesNewTabForCodex() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let originalId = store.launchExternalAgentTab(name: "Codex", command: "codex")
        let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let idx = try XCTUnwrap(store.terminalTabs.firstIndex(where: { $0.terminalId == originalId }))
        store.terminalTabs[idx].agentSessionId = sessionId

        let forkedId = try XCTUnwrap(store.forkTerminalTab(originalId))
        let forkedTab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == forkedId })
        XCTAssertEqual(forkedTab.agentKind, .codex)
        XCTAssertTrue(forkedTab.command?.contains("resume") == true)
        XCTAssertTrue(forkedTab.command?.contains(sessionId) == true)
    }

    func testForkTerminalTabReturnsNilWhenNoSessionId() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let originalId = store.launchExternalAgentTab(name: "Claude", command: "claude")

        XCTAssertNil(store.forkTerminalTab(originalId))
    }

    func testForkTerminalTabReturnsNilForGemini() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let originalId = store.launchExternalAgentTab(name: "Gemini", command: "gemini")
        if let idx = store.terminalTabs.firstIndex(where: { $0.terminalId == originalId }) {
            store.terminalTabs[idx].agentSessionId = "present-but-unusable"
        }

        XCTAssertNil(store.forkTerminalTab(originalId))
    }

    func testForkTerminalTabReturnsNilForKimi() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let originalId = store.launchExternalAgentTab(name: "Kimi", command: "kimi")
        if let idx = store.terminalTabs.firstIndex(where: { $0.terminalId == originalId }) {
            store.terminalTabs[idx].agentSessionId = "present-but-unusable"
        }

        XCTAssertNil(store.forkTerminalTab(originalId))
    }

    func testForkTerminalTabReturnsNilForMissingTerminal() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        XCTAssertNil(store.forkTerminalTab("nonexistent-id"))
    }

    func testForkTerminalTabReturnsNilForNonAgentTab() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let terminalId = store.addTerminalTab(
            title: "Plain",
            workingDirectory: context.workspacePath,
            command: "zsh"
        )

        XCTAssertNil(store.forkTerminalTab(terminalId))
    }

    func testForkedTabAppearsAheadOfOriginalInList() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let originalId = store.launchExternalAgentTab(name: "Claude", command: "claude")
        let idx = try XCTUnwrap(store.terminalTabs.firstIndex(where: { $0.terminalId == originalId }))
        store.terminalTabs[idx].agentSessionId = "11111111-2222-3333-4444-555555555555"

        let forkedId = try XCTUnwrap(store.forkTerminalTab(originalId))
        let forkedPosition = try XCTUnwrap(store.terminalTabs.firstIndex(where: { $0.terminalId == forkedId }))
        let originalPosition = try XCTUnwrap(store.terminalTabs.firstIndex(where: { $0.terminalId == originalId }))
        XCTAssertLessThan(forkedPosition, originalPosition)
    }

    func testForkReusesOriginalTitle() throws {
        let context = try makeStoreContext()
        defer { context.cleanup() }

        let store = context.makeStore()
        let originalId = store.launchExternalAgentTab(name: "My Claude", command: "claude")
        let idx = try XCTUnwrap(store.terminalTabs.firstIndex(where: { $0.terminalId == originalId }))
        store.terminalTabs[idx].agentSessionId = "11111111-2222-3333-4444-555555555555"

        let forkedId = try XCTUnwrap(store.forkTerminalTab(originalId))
        let forkedTab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == forkedId })
        XCTAssertEqual(forkedTab.title, "My Claude")
    }

    // MARK: - Context

    private func makeStoreContext() throws -> StoreContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreForkTests-\(UUID().uuidString)", isDirectory: true)
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
