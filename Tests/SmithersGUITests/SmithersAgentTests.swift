import XCTest
@testable import SmithersGUI

final class SmithersAgentTests: XCTestCase {

    func testDecodesFullAgent() throws {
        let json = """
        {
            "id": "agent1",
            "name": "Claude",
            "command": "claude",
            "binaryPath": "/usr/bin/claude",
            "status": "likely-subscription",
            "hasAuth": true,
            "hasAPIKey": false,
            "usable": true,
            "roles": ["coder", "reviewer"],
            "version": "1.0.0",
            "authExpired": false
        }
        """.data(using: .utf8)!
        let agent = try JSONDecoder().decode(SmithersAgent.self, from: json)
        XCTAssertEqual(agent.id, "agent1")
        XCTAssertEqual(agent.name, "Claude")
        XCTAssertEqual(agent.roles, ["coder", "reviewer"])
        XCTAssertTrue(agent.usable)
        XCTAssertEqual(agent.version, "1.0.0")
        XCTAssertEqual(agent.authExpired, false)
    }

    func testDecodesMinimalAgent() throws {
        let json = """
        {
            "id": "a2",
            "name": "Codex",
            "command": "codex",
            "binaryPath": "/bin/codex",
            "status": "unavailable",
            "hasAuth": false,
            "hasAPIKey": true,
            "usable": false,
            "roles": []
        }
        """.data(using: .utf8)!
        let agent = try JSONDecoder().decode(SmithersAgent.self, from: json)
        XCTAssertEqual(agent.id, "a2")
        XCTAssertNil(agent.version)
        XCTAssertNil(agent.authExpired)
        XCTAssertFalse(agent.usable)
    }
}

// MARK: - SmithersPrompt Tests

final class SmithersPromptTests: XCTestCase {

    func testDecodePrompt() throws {
        let json = """
        {"id":"p1","entryFile":"prompt.md","source":"local","inputs":[{"name":"topic","type":"string"}]}
        """.data(using: .utf8)!
        let prompt = try JSONDecoder().decode(SmithersPrompt.self, from: json)
        XCTAssertEqual(prompt.id, "p1")
        XCTAssertEqual(prompt.entryFile, "prompt.md")
        XCTAssertEqual(prompt.inputs?.count, 1)
    }

    func testDecodeMinimalPrompt() throws {
        let json = """
        {"id":"p2"}
        """.data(using: .utf8)!
        let prompt = try JSONDecoder().decode(SmithersPrompt.self, from: json)
        XCTAssertEqual(prompt.id, "p2")
        XCTAssertNil(prompt.entryFile)
        XCTAssertNil(prompt.inputs)
    }
}

// MARK: - RunTask Additional Tests

final class RunTaskAdditionalTests: XCTestCase {

    func testRunTaskIdWithoutIteration() {
        let json = """
        {"nodeId":"task1","state":"running"}
        """.data(using: .utf8)!
        let task = try! JSONDecoder().decode(RunTask.self, from: json)
        XCTAssertEqual(task.id, "task1")
    }

    func testRunTaskIdWithIteration() {
        let json = """
        {"nodeId":"task1","state":"running","iteration":2}
        """.data(using: .utf8)!
        let task = try! JSONDecoder().decode(RunTask.self, from: json)
        XCTAssertEqual(task.id, "task1-2")
    }
}

// MARK: - RunInspection Additional Tests

final class RunInspectionAdditionalTests: XCTestCase {

    func testDecodeRunInspection() throws {
        let json = """
        {
            "run": {"runId":"r1","status":"running"},
            "tasks": [{"nodeId":"n1","state":"pending"}]
        }
        """.data(using: .utf8)!
        let inspection = try JSONDecoder().decode(RunInspection.self, from: json)
        XCTAssertEqual(inspection.run.id, "r1")
        XCTAssertEqual(inspection.tasks.count, 1)
    }
}
