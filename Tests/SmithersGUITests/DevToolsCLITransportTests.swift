import XCTest
@testable import SmithersGUI

final class DevToolsInputValidatorTests: XCTestCase {
    func testValidRunIdPasses() throws {
        XCTAssertNoThrow(try DevToolsInputValidator.validate(runId: "run-1776372721752"))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(runId: "abc_XYZ-123"))
    }

    func testEmptyRunIdRejected() {
        XCTAssertThrowsError(try DevToolsInputValidator.validate(runId: "")) { err in
            XCTAssertEqual(err as? DevToolsClientError, .invalidRunId(""))
        }
    }

    func testRunIdWithSpecialCharsRejected() {
        XCTAssertThrowsError(try DevToolsInputValidator.validate(runId: "abc;rm -rf /"))
        XCTAssertThrowsError(try DevToolsInputValidator.validate(runId: "a'b"))
        XCTAssertThrowsError(try DevToolsInputValidator.validate(runId: "a/b"))
    }

    func testValidNodeIdPasses() throws {
        XCTAssertNoThrow(try DevToolsInputValidator.validate(nodeId: "s10:implement"))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(nodeId: "node:review:0"))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(nodeId: "task_1-alt"))
    }

    func testNodeIdWithSpaceRejected() {
        XCTAssertThrowsError(try DevToolsInputValidator.validate(nodeId: "bad node id"))
    }

    func testIterationValidation() throws {
        XCTAssertNoThrow(try DevToolsInputValidator.validate(iteration: 0))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(iteration: 42))
        XCTAssertThrowsError(try DevToolsInputValidator.validate(iteration: -1)) { err in
            XCTAssertEqual(err as? DevToolsClientError, .invalidIteration(-1))
        }
    }

    func testFrameNoValidation() throws {
        XCTAssertNoThrow(try DevToolsInputValidator.validate(frameNo: 0))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(frameNo: 9999))
        XCTAssertThrowsError(try DevToolsInputValidator.validate(frameNo: -1))
    }
}

final class DevToolsSQLEscapeTests: XCTestCase {
    func testBasicQuote() {
        XCTAssertEqual(DevToolsSQL.quote("abc"), "'abc'")
    }

    func testEscapesApostrophes() {
        XCTAssertEqual(DevToolsSQL.quote("O'Brien"), "'O''Brien'")
        XCTAssertEqual(DevToolsSQL.quote("';DROP TABLE users--"), "''';DROP TABLE users--'")
    }
}

final class DevToolsTreeBuilderTests: XCTestCase {
    private func decodeXML(_ json: String) throws -> DevToolsFrameXMLNode {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(DevToolsFrameXMLNode.self, from: data)
    }

    func testSimpleWorkflowConverts() throws {
        let json = """
        {"kind":"element","tag":"smithers:workflow","props":{"name":"main"},"children":[
          {"kind":"element","tag":"smithers:sequence","props":{},"children":[
            {"kind":"element","tag":"smithers:task","props":{"id":"main"},"children":[]}
          ]}
        ]}
        """
        let xml = try decodeXML(json)
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [])
        XCTAssertEqual(tree.type, .workflow)
        XCTAssertEqual(tree.name, "main")
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children[0].type, .sequence)
        XCTAssertEqual(tree.children[0].children.count, 1)
        XCTAssertEqual(tree.children[0].children[0].type, .task)
        XCTAssertEqual(tree.children[0].children[0].name, "main")
    }

    func testTaskIndexHoisted() throws {
        let json = """
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"s10:implement"},"children":[]}
        ]}
        """
        let xml = try decodeXML(json)
        let idx: [DevToolsTaskIndexEntry] = {
            let data = Data("""
            [{"nodeId":"s10:implement","ordinal":0,"iteration":0,"outputTableName":"implement"}]
            """.utf8)
            return (try? JSONDecoder().decode([DevToolsTaskIndexEntry].self, from: data)) ?? []
        }()
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: idx)
        let task = tree.children[0]
        XCTAssertNotNil(task.task)
        XCTAssertEqual(task.task?.nodeId, "s10:implement")
        XCTAssertEqual(task.task?.outputTableName, "implement")
    }

    func testAssignsUniqueIds() throws {
        let json = """
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},
          {"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]}
        ]}
        """
        let xml = try decodeXML(json)
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [])
        var seen = Set<Int>()
        func walk(_ node: DevToolsNode) {
            seen.insert(node.id)
            for c in node.children { walk(c) }
        }
        walk(tree)
        XCTAssertEqual(seen.count, 3, "root + 2 tasks should each get a unique id")
    }
}

final class DevToolsFrameApplierTests: XCTestCase {
    private func decodeXML(_ json: String) throws -> DevToolsFrameXMLNode {
        try JSONDecoder().decode(DevToolsFrameXMLNode.self, from: Data(json.utf8))
    }

    private func decodeDelta(_ json: String) throws -> DevToolsFrameDelta {
        try JSONDecoder().decode(DevToolsFrameDelta.self, from: Data(json.utf8))
    }

    func testEmptyDeltasLeaveTreeUnchanged() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[]}
        """)
        let delta = try decodeDelta("""
        {"version":1,"ops":[]}
        """)
        let result = try DevToolsFrameApplier.apply(deltas: [delta], toKeyframe: xml)
        XCTAssertEqual(result.tag, "smithers:workflow")
        XCTAssertEqual(result.children.count, 0)
    }

    func testSetPropagatesText() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[
            {"kind":"text","text":"old"}
          ]}
        ]}
        """)
        // Deltas in real data target the text child's "text" prop via:
        //   ["children", 0, "children", 0, "text"]
        let delta = try decodeDelta("""
        {"version":1,"ops":[
          {"op":"set","path":["children",0,"children",0,"text"],"value":"new text"}
        ]}
        """)
        let result = try DevToolsFrameApplier.apply(deltas: [delta], toKeyframe: xml)
        let taskChild = result.children[0]
        let textChild = taskChild.children[0]
        XCTAssertEqual(textChild.text, "new text")
    }

    func testInsertAppendsChild() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:sequence","props":{},"children":[]}
        ]}
        """)
        let delta = try decodeDelta("""
        {"version":1,"ops":[
          {"op":"insert","path":["children",0,"children",0],
           "value":{"kind":"element","tag":"smithers:task","props":{"id":"new"},"children":[]}}
        ]}
        """)
        let result = try DevToolsFrameApplier.apply(deltas: [delta], toKeyframe: xml)
        XCTAssertEqual(result.children[0].children.count, 1)
        XCTAssertEqual(result.children[0].children[0].props["id"], "new")
    }

    func testRemoveDeletesChild() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:sequence","props":{},"children":[
            {"kind":"element","tag":"smithers:task","props":{"id":"doomed"},"children":[]}
          ]}
        ]}
        """)
        let delta = try decodeDelta("""
        {"version":1,"ops":[
          {"op":"remove","path":["children",0,"children",0]}
        ]}
        """)
        let result = try DevToolsFrameApplier.apply(deltas: [delta], toKeyframe: xml)
        XCTAssertEqual(result.children[0].children.count, 0)
    }
}

/// Smoke-tests that require `/usr/bin/sqlite3` and a real smithers.db file.
/// These run only when the environment variable `SMITHERS_DEVTOOLS_TEST_DB` points
/// at a valid database path, to keep the suite hermetic by default.
@MainActor
final class DevToolsCLITransportIntegrationTests: XCTestCase {
    private var dbPath: String? {
        ProcessInfo.processInfo.environment["SMITHERS_DEVTOOLS_TEST_DB"]
    }

    func testInvalidRunIdThrowsWithoutReachingDisk() async {
        let client = SmithersClient()
        do {
            _ = try await client.getDevToolsSnapshot(runId: "bad id", frameNo: nil)
            XCTFail("Expected invalidRunId")
        } catch let err as DevToolsClientError {
            XCTAssertEqual(err, .invalidRunId("bad id"))
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testSnapshotReturnsDataFromRealDB() async throws {
        guard let dbPath, FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Set SMITHERS_DEVTOOLS_TEST_DB to run this test.")
        }
        // Pick a runId known to exist in the DB.
        let runId = ProcessInfo.processInfo.environment["SMITHERS_DEVTOOLS_TEST_RUN_ID"] ?? "run-1776372721752"

        setenv("SMITHERS_DB_PATH", dbPath, 1)
        defer { unsetenv("SMITHERS_DB_PATH") }

        let client = SmithersClient(cwd: (dbPath as NSString).deletingLastPathComponent)
        let snap = try await client.getDevToolsSnapshot(runId: runId, frameNo: nil)
        XCTAssertEqual(snap.runId, runId)
        XCTAssertGreaterThan(snap.frameNo, 0)
        XCTAssertEqual(snap.root.type, .workflow)
    }
}
