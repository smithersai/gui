#if os(macOS)
import Foundation
import XCTest

private struct MacE2EApprovalsContext {
    let bearer: String
    let baseURL: URL
    let owner: String
    let repoName: String
    let seededApprovalID: String

    static func load() throws -> MacE2EApprovalsContext {
        try MacE2ETestSupport.requireSeeded(
            "approvals scenarios require PLUE_E2E_SEEDED=1"
        )
        let baseURLString = try MacE2ETestSupport.requireEnv(MacE2ELaunchKey.baseURL)
        guard let baseURL = URL(string: baseURLString) else {
            throw XCTSkip("macOS approvals e2e requires a valid \(MacE2ELaunchKey.baseURL)")
        }
        return MacE2EApprovalsContext(
            bearer: try MacE2ETestSupport.requireEnv(MacE2ELaunchKey.bearer),
            baseURL: baseURL,
            owner: try MacE2ETestSupport.requireEnv(MacE2ESeedKey.repoOwner),
            repoName: try MacE2ETestSupport.requireEnv(MacE2ESeedKey.repoName),
            seededApprovalID: try MacE2ETestSupport.requireEnv(MacE2ESeedKey.approvalID)
        )
    }

    var approvalsListURL: URL {
        baseURL.appendingPathComponent("api/repos/\(owner)/\(repoName)/approvals")
    }

    func decideURL(approvalID: String) -> URL {
        approvalsListURL
            .appendingPathComponent(approvalID)
            .appendingPathComponent("decide")
    }
}

private struct MacE2EApprovalRow {
    let id: String
    let rawStatus: String

    var normalizedStatus: String {
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approve", "approved":
            return "approved"
        case "deny", "denied", "reject", "rejected":
            return "denied"
        case "pending":
            return "pending"
        default:
            return rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

final class SmithersMacOSE2EApprovalsTests: XCTestCase {
    private let http = MacE2EHTTPClient()
    private static let seedScriptPath = "/Users/williamcory/gui/ios/scripts/seed-e2e-data.sh"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_approvals_inbox_lists_pending() throws {
        let context = try readyContext()
        _ = try reseedPrimaryApproval(context)

        let rows = try fetchApprovals(context: context)
        let seeded = try findApproval(id: context.seededApprovalID, in: rows)

        XCTAssertEqual(seeded.normalizedStatus, "pending", "seeded approval should be pending in the macOS approvals inbox")
        XCTAssertNotEqual(seeded.normalizedStatus, "approved", "seeded approval should not already be approved")
        XCTAssertNotEqual(seeded.normalizedStatus, "denied", "seeded approval should not already be denied")
    }

    func test_approvals_inbox_approve_transitions_to_approved() throws {
        let context = try readyContext()
        let approvalID = try reseedPrimaryApproval(context)
        try assertApprovalStatus(id: approvalID, expected: "pending", context: context)

        let decide = try http.request(
            url: context.decideURL(approvalID: approvalID),
            method: "POST",
            bearer: context.bearer,
            jsonBody: ["decision": "approved"]
        )

        XCTAssertEqual(decide.statusCode, 200, "approve should succeed: \(decide.text)")
        try assertApprovalStatus(id: approvalID, expected: "approved", context: context)
    }

    func test_approvals_inbox_deny_transitions_to_denied() throws {
        let context = try readyContext()
        let approvalID = try reseedPrimaryApproval(context)
        try assertApprovalStatus(id: approvalID, expected: "pending", context: context)

        let decide = try http.request(
            url: context.decideURL(approvalID: approvalID),
            method: "POST",
            bearer: context.bearer,
            jsonBody: ["decision": "rejected"]
        )

        XCTAssertEqual(decide.statusCode, 200, "deny/reject should succeed: \(decide.text)")
        try assertApprovalStatus(id: approvalID, expected: "denied", context: context)
    }

    private func readyContext() throws -> MacE2EApprovalsContext {
        let context = try MacE2EApprovalsContext.load()
        let flags = try fetchFeatureFlags(context: context)
        guard flags["approvals_flow_enabled"] == true else {
            throw XCTSkip("approvals_flow_enabled=false on \(context.baseURL.absoluteString)")
        }
        return context
    }

    private func fetchFeatureFlags(context: MacE2EApprovalsContext) throws -> [String: Bool] {
        let response = try http.request(
            baseURL: context.baseURL,
            pathComponents: ["api", "feature-flags"],
            method: "GET"
        )
        XCTAssertEqual(response.statusCode, 200, "GET /api/feature-flags should return 200: \(response.text)")
        let object = try http.jsonDictionary(response)
        return object["flags"] as? [String: Bool] ?? [:]
    }

    private func fetchApprovals(context: MacE2EApprovalsContext) throws -> [MacE2EApprovalRow] {
        let response = try http.request(
            url: context.approvalsListURL,
            method: "GET",
            bearer: context.bearer
        )
        XCTAssertEqual(response.statusCode, 200, "GET approvals should return 200: \(response.text)")
        XCTAssertNotEqual(response.statusCode, 401, "GET approvals must not fail auth with the seeded bearer")
        return try approvalRows(from: response)
    }

    private func assertApprovalStatus(
        id: String,
        expected: String,
        context: MacE2EApprovalsContext
    ) throws {
        let row = try findApproval(id: id, in: fetchApprovals(context: context))
        XCTAssertEqual(row.normalizedStatus, expected, "approval \(id) should be \(expected), got \(row.rawStatus)")
    }

    private func approvalRows(from response: MacE2EHTTPResponse) throws -> [MacE2EApprovalRow] {
        guard !response.data.isEmpty else {
            return []
        }
        let object = try JSONSerialization.jsonObject(with: response.data, options: [])
        let rows = flattenApprovalRows(object)
        if rows.isEmpty {
            throw MacE2EHTTPError.invalidJSON("unable to decode approvals payload: \(response.text)")
        }
        return rows
    }

    private func flattenApprovalRows(_ value: Any) -> [MacE2EApprovalRow] {
        if let array = value as? [Any] {
            return array.compactMap { element in
                guard let object = element as? [String: Any] else { return nil }
                return approvalRow(from: object)
            }
        }
        if let object = value as? [String: Any] {
            if let direct = approvalRow(from: object) {
                return [direct]
            }
            for key in ["approvals", "items", "results", "data"] {
                if let nested = object[key] {
                    let rows = flattenApprovalRows(nested)
                    if !rows.isEmpty {
                        return rows
                    }
                }
            }
        }
        return []
    }

    private func approvalRow(from object: [String: Any]) -> MacE2EApprovalRow? {
        guard let id = stringValue(object["id"]) ?? stringValue(object["approval_id"]) else {
            return nil
        }
        guard let status = stringValue(object["status"]) ?? stringValue(object["state"]) else {
            return nil
        }
        return MacE2EApprovalRow(id: id, rawStatus: status)
    }

    private func findApproval(id: String, in rows: [MacE2EApprovalRow]) throws -> MacE2EApprovalRow {
        if let row = rows.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return row
        }
        throw MacE2EHTTPError.invalidJSON("approval \(id) missing from approvals payload")
    }

    private func reseedPrimaryApproval(_ context: MacE2EApprovalsContext) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment[MacE2ELaunchKey.bearer] = context.bearer
        let output = try runHostShell(
            "cd \(shellQuote("/Users/williamcory/gui")) && \(shellQuote(Self.seedScriptPath))",
            environment: environment
        )
        let values = parseKeyValueOutput(output)
        let approvalID = values[MacE2ESeedKey.approvalID] ?? context.seededApprovalID
        XCTAssertEqual(
            approvalID.lowercased(),
            context.seededApprovalID.lowercased(),
            "reseed should preserve the stable seeded approval id"
        )
        return approvalID
    }

    private func runHostShell(_ command: String, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.environment = environment.merging([
            "PATH": "/opt/homebrew/opt/libpq/bin:/opt/homebrew/bin:/usr/local/bin:\(environment["PATH"] ?? "")",
        ]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "smithers.macos.e2e.approvals.seed",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "seed script failed with exit \(process.terminationStatus)\nstdout:\n\(out)\nstderr:\n\(err)"]
            )
        }
        return out
    }

    private func parseKeyValueOutput(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return values
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func shellQuote(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
#endif
