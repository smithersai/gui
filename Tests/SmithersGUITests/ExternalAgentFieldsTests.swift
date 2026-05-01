import XCTest
@testable import SmithersGUI

// MARK: - ExternalAgent Fields on TerminalWorkspaceRecord

final class ExternalAgentFieldsTests: XCTestCase {

    // MARK: Helpers

    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeRecord(
        agentKind: ExternalAgentKind? = nil,
        agentSessionId: String? = nil
    ) -> TerminalWorkspaceRecord {
        TerminalWorkspaceRecord(
            terminalId: "t-1",
            title: "Claude",
            preview: "claude --resume",
            timestamp: referenceDate,
            createdAt: referenceDate,
            workingDirectory: "/tmp/repo",
            command: "claude",
            backend: .native,
            rootSurfaceId: "surface-1",
            tmuxSocketName: nil,
            tmuxSessionName: nil,
            sessionId: "pty-xyz",
            runId: nil,
            hijack: nil,
            isPinned: false,
            rootKind: .terminal,
            browserURLString: nil,
            agentKind: agentKind,
            agentSessionId: agentSessionId
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    // MARK: Default values

    func testDefaultInitLeavesAgentFieldsNil() {
        let record = TerminalWorkspaceRecord(
            terminalId: "t-1",
            title: "Terminal",
            preview: "",
            timestamp: Self.referenceDate,
            createdAt: Self.referenceDate
        )
        XCTAssertNil(record.agentKind)
        XCTAssertNil(record.agentSessionId)
    }

    func testExplicitInitStoresAgentFields() {
        let record = Self.makeRecord(agentKind: .claude, agentSessionId: "sess-42")
        XCTAssertEqual(record.agentKind, .claude)
        XCTAssertEqual(record.agentSessionId, "sess-42")
    }

    // MARK: Codable round-trips

    func testRoundTripPreservesPopulatedAgentFields() throws {
        let original = Self.makeRecord(agentKind: .codex, agentSessionId: "abc-123")
        let data = try Self.makeEncoder().encode(original)
        let decoded = try Self.makeDecoder().decode(TerminalWorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.agentKind, .codex)
        XCTAssertEqual(decoded.agentSessionId, "abc-123")
        XCTAssertEqual(decoded.terminalId, original.terminalId)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.command, original.command)
    }

    func testRoundTripPreservesNilAgentFields() throws {
        let original = Self.makeRecord()
        let data = try Self.makeEncoder().encode(original)
        let decoded = try Self.makeDecoder().decode(TerminalWorkspaceRecord.self, from: data)
        XCTAssertNil(decoded.agentKind)
        XCTAssertNil(decoded.agentSessionId)
    }

    // MARK: Backward compatibility (legacy JSON)

    func testDecodesLegacyJSONWithoutAgentKeys() throws {
        // Legacy payload predates agentKind/agentSessionId and must still decode.
        let legacyJSON = """
        {
            "terminalId": "t-legacy",
            "title": "Old",
            "preview": "",
            "timestamp": 1700000000000,
            "createdAt": 1700000000000,
            "backend": "tmux",
            "isPinned": false,
            "rootKind": "terminal"
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try Self.makeDecoder().decode(TerminalWorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.terminalId, "t-legacy")
        XCTAssertNil(decoded.agentKind)
        XCTAssertNil(decoded.agentSessionId)
    }

    func testDecodesJSONWithOnlyAgentKindPresent() throws {
        let json = """
        {
            "terminalId": "t-partial-kind",
            "title": "Partial",
            "preview": "",
            "timestamp": 1700000000000,
            "createdAt": 1700000000000,
            "backend": "native",
            "isPinned": false,
            "rootKind": "terminal",
            "agentKind": "gemini"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try Self.makeDecoder().decode(TerminalWorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.agentKind, .gemini)
        XCTAssertNil(decoded.agentSessionId)
    }

    func testDecodesJSONWithOnlyAgentSessionIdPresent() throws {
        let json = """
        {
            "terminalId": "t-partial-session",
            "title": "Partial",
            "preview": "",
            "timestamp": 1700000000000,
            "createdAt": 1700000000000,
            "backend": "native",
            "isPinned": false,
            "rootKind": "terminal",
            "agentSessionId": "orphan-session"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try Self.makeDecoder().decode(TerminalWorkspaceRecord.self, from: data)
        XCTAssertNil(decoded.agentKind)
        XCTAssertEqual(decoded.agentSessionId, "orphan-session")
    }

    // MARK: ExternalAgentKind

    func testAllExternalAgentKindCasesRoundTripThroughCodable() throws {
        let encoder = Self.makeEncoder()
        let decoder = Self.makeDecoder()
        for kind in ExternalAgentKind.allCases {
            let record = Self.makeRecord(agentKind: kind, agentSessionId: "sess-\(kind.rawValue)")
            let data = try encoder.encode(record)
            let decoded = try decoder.decode(TerminalWorkspaceRecord.self, from: data)
            XCTAssertEqual(decoded.agentKind, kind, "kind \(kind) did not round-trip")
            XCTAssertEqual(decoded.agentSessionId, "sess-\(kind.rawValue)")
        }
    }

    func testExternalAgentKindRawValuesAreStable() {
        // Persisted JSON relies on these raw values. Changing them is a
        // breaking change for existing records.
        XCTAssertEqual(ExternalAgentKind.claude.rawValue, "claude")
        XCTAssertEqual(ExternalAgentKind.codex.rawValue, "codex")
        XCTAssertEqual(ExternalAgentKind.gemini.rawValue, "gemini")
        XCTAssertEqual(ExternalAgentKind.kimi.rawValue, "kimi")
    }

    func testExternalAgentKindDecodesFromRawStringInContainer() throws {
        struct Wrapper: Codable {
            let agentKind: ExternalAgentKind
        }
        for raw in ["claude", "codex", "gemini", "kimi"] {
            let json = "{\"agentKind\":\"\(raw)\"}"
            let data = try XCTUnwrap(json.data(using: .utf8))
            let decoded = try Self.makeDecoder().decode(Wrapper.self, from: data)
            XCTAssertEqual(decoded.agentKind.rawValue, raw)
        }
    }

    // MARK: Mutation

    func testMutatingAgentFieldsAfterInit() {
        var record = Self.makeRecord()
        XCTAssertNil(record.agentKind)
        XCTAssertNil(record.agentSessionId)

        record.agentKind = .kimi
        record.agentSessionId = "kimi-session-1"
        XCTAssertEqual(record.agentKind, .kimi)
        XCTAssertEqual(record.agentSessionId, "kimi-session-1")

        // Clearing back to nil.
        record.agentKind = nil
        record.agentSessionId = nil
        XCTAssertNil(record.agentKind)
        XCTAssertNil(record.agentSessionId)
    }

    func testRecordEqualityConsidersAgentFields() {
        let a = Self.makeRecord(agentKind: .claude, agentSessionId: "s1")
        let b = Self.makeRecord(agentKind: .claude, agentSessionId: "s1")
        let c = Self.makeRecord(agentKind: .codex, agentSessionId: "s1")
        let d = Self.makeRecord(agentKind: .claude, agentSessionId: "s2")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    // MARK: SidebarWorkspace propagation

    func testSidebarWorkspaceCanCarryAgentFields() {
        let sidebar = SidebarWorkspace(
            id: "terminal:t-1",
            kind: .terminal,
            runId: nil,
            terminalId: "t-1",
            title: "Claude",
            preview: "claude --resume",
            timestamp: "just now",
            group: "Today",
            sortDate: Self.referenceDate,
            isPinned: false,
            isArchived: false,
            isUnread: false,
            workingDirectory: "/tmp/repo",
            sessionIdentifier: "t-1",
            agentKind: .claude,
            agentSessionId: "cc-session-99"
        )
        XCTAssertEqual(sidebar.agentKind, .claude)
        XCTAssertEqual(sidebar.agentSessionId, "cc-session-99")
    }

    func testSidebarWorkspaceDefaultsAgentFieldsToNil() {
        let sidebar = SidebarWorkspace(
            id: "terminal:t-1",
            kind: .terminal,
            runId: nil,
            terminalId: "t-1",
            title: "Plain",
            preview: "",
            timestamp: "just now",
            group: "Today",
            sortDate: Self.referenceDate
        )
        XCTAssertNil(sidebar.agentKind)
        XCTAssertNil(sidebar.agentSessionId)
    }
}
