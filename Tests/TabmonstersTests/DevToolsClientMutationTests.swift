import XCTest
@testable import SmithersGUI

final class DevToolsClientMutationTests: XCTestCase {
    func testAuditRowIDExtractsTopLevelField() {
        let payload: JSONValue = .object([
            "ok": .bool(true),
            "auditRowId": .string("audit_123"),
        ])
        XCTAssertEqual(DevToolsClient.auditRowID(from: payload), "audit_123")
    }

    func testAuditRowIDExtractsNestedEnvelopeField() {
        let payload: JSONValue = .object([
            "data": .object([
                "result": .object([
                    "audit_row_id": .string("audit_nested_456"),
                ]),
            ]),
        ])
        XCTAssertEqual(DevToolsClient.auditRowID(from: payload), "audit_nested_456")
    }

    func testAuditRowIDReturnsNilWhenAbsent() {
        let payload: JSONValue = .object([
            "ok": .bool(true),
            "message": .string("updated"),
        ])
        XCTAssertNil(DevToolsClient.auditRowID(from: payload))
    }

    func testIsUnsupportedRPCErrorMatchesMethodNotFoundMessages() {
        XCTAssertTrue(DevToolsClient.isUnsupportedRPCError(SmithersError.api("method not found: runs.cancel")))
        XCTAssertTrue(DevToolsClient.isUnsupportedRPCError(SmithersError.api("Unknown method runs.resume")))
        XCTAssertTrue(DevToolsClient.isUnsupportedRPCError(SmithersError.api("unsupported method")))
    }

    func testIsUnsupportedRPCErrorIgnoresOperationalErrors() {
        XCTAssertFalse(DevToolsClient.isUnsupportedRPCError(SmithersError.api("permission denied")))
        XCTAssertFalse(DevToolsClient.isUnsupportedRPCError(SmithersError.notFound))
    }
}

