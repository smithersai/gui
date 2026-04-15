import XCTest
@testable import SmithersGUI

final class CodexMCPStatusStoreTests: XCTestCase {
    func testDecodeStatusJSONDecodesStdioServer() throws {
        let json = """
        {
          "ok": false,
          "servers": [
            {
              "name": "filesystem",
              "enabled": true,
              "status": "ready",
              "auth_status": "not_required",
              "auth_label": "No auth",
              "startup_timeout_sec": 3.5,
              "tool_timeout_sec": 11,
              "transport": {
                "type": "stdio",
                "command": "node",
                "args": ["server.js", "--stdio"],
                "cwd": "/tmp/project",
                "env_keys": ["API_TOKEN"],
                "env_vars": ["NODE_ENV"]
              },
              "tools": ["read_file", "write_file"],
              "resources": [
                {"name": "root", "title": "Root", "uri": "file:///tmp/project"}
              ],
              "resource_templates": [
                {"name": "file", "title": null, "uri_template": "file:///{path}"}
              ],
              "errors": ["slow startup"]
            }
          ],
          "errors": ["one server degraded"],
          "error": "top level failure"
        }
        """

        let snapshot = try XCTUnwrap(CodexMCPStatusStore.decodeStatusJSON(json))
        XCTAssertFalse(snapshot.ok)
        XCTAssertEqual(snapshot.errors, ["one server degraded"])
        XCTAssertEqual(snapshot.error, "top level failure")

        let server = try XCTUnwrap(snapshot.servers.first)
        XCTAssertEqual(server.id, "filesystem")
        XCTAssertEqual(server.name, "filesystem")
        XCTAssertTrue(server.enabled)
        XCTAssertEqual(server.status, "ready")
        XCTAssertEqual(server.authStatus, "not_required")
        XCTAssertEqual(server.authLabel, "No auth")
        XCTAssertEqual(server.startupTimeoutSec, 3.5)
        XCTAssertEqual(server.toolTimeoutSec, 11)
        XCTAssertEqual(server.tools, ["read_file", "write_file"])
        XCTAssertEqual(server.resources.first?.id, "file:///tmp/project")
        XCTAssertEqual(server.resourceTemplates.first?.id, "file:///{path}")
        XCTAssertEqual(server.errors, ["slow startup"])

        guard case let .stdio(command, args, cwd, envKeys, envVars) = server.transport else {
            return XCTFail("Expected stdio transport")
        }
        XCTAssertEqual(command, "node")
        XCTAssertEqual(args, ["server.js", "--stdio"])
        XCTAssertEqual(cwd, "/tmp/project")
        XCTAssertEqual(envKeys, ["API_TOKEN"])
        XCTAssertEqual(envVars, ["NODE_ENV"])
    }

    func testDecodeStatusJSONDecodesStreamableHTTPTransportDefaults() throws {
        let json = """
        {
          "ok": true,
          "servers": [
            {
              "name": "linear",
              "enabled": false,
              "status": "disabled",
              "auth_status": "required",
              "auth_label": "Login required",
              "startup_timeout_sec": null,
              "tool_timeout_sec": null,
              "transport": {
                "type": "streamable_http",
                "url": "https://mcp.example.test",
                "env_http_headers": [
                  {"name": "Authorization", "env_var": "LINEAR_TOKEN"}
                ]
              },
              "tools": [],
              "resources": [],
              "resource_templates": [],
              "errors": []
            }
          ],
          "errors": []
        }
        """

        let snapshot = try XCTUnwrap(CodexMCPStatusStore.decodeStatusJSON(json))
        let server = try XCTUnwrap(snapshot.servers.first)
        XCTAssertTrue(snapshot.ok)
        XCTAssertFalse(server.enabled)
        XCTAssertNil(server.startupTimeoutSec)
        XCTAssertNil(server.toolTimeoutSec)

        guard case let .streamableHTTP(url, bearerTokenEnvVar, httpHeaderKeys, envHTTPHeaders) = server.transport else {
            return XCTFail("Expected streamable HTTP transport")
        }
        XCTAssertEqual(url, "https://mcp.example.test")
        XCTAssertNil(bearerTokenEnvVar)
        XCTAssertEqual(httpHeaderKeys, [])
        XCTAssertEqual(envHTTPHeaders, [
            CodexMCPEnvHTTPHeader(name: "Authorization", envVar: "LINEAR_TOKEN"),
        ])
    }

    func testDecodeStatusJSONDecodesUnknownTransportType() throws {
        let json = """
        {
          "ok": true,
          "servers": [
            {
              "name": "custom",
              "enabled": true,
              "status": "ready",
              "auth_status": "unknown",
              "auth_label": "Unknown",
              "transport": {"type": "custom_transport"},
              "tools": [],
              "resources": [],
              "resource_templates": [],
              "errors": []
            }
          ],
          "errors": []
        }
        """

        let snapshot = try XCTUnwrap(CodexMCPStatusStore.decodeStatusJSON(json))
        let server = try XCTUnwrap(snapshot.servers.first)
        XCTAssertEqual(server.transport, .unknown(type: "custom_transport"))
    }

    func testDecodeStatusJSONReturnsNilForInvalidJSON() {
        XCTAssertNil(CodexMCPStatusStore.decodeStatusJSON("{not-json"))
    }

    func testLoadStatusReturnsEmptySnapshotDuringUnitTests() {
        let snapshot = CodexMCPStatusStore.loadStatus(cwd: "/tmp/project")
        XCTAssertEqual(snapshot, .empty)
    }
}
