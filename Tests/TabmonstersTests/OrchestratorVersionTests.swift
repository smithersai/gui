import XCTest
@testable import SmithersGUI

final class OrchestratorVersionTests: XCTestCase {

    func testRejectsUnknown() {
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion("unknown"))
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion("Unknown"))
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion("UNKNOWN"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion(""))
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion("   "))
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion("\n\t"))
    }

    func testRejectsNonDigitPrefix() {
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion("v1.2.3"))
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion("error: oops"))
        XCTAssertNil(SmithersClient.normalizeOrchestratorVersion("-1.0.0"))
    }

    func testAcceptsDigitPrefixedVersion() {
        XCTAssertEqual(SmithersClient.normalizeOrchestratorVersion("0.16.8"), "0.16.8")
        XCTAssertEqual(SmithersClient.normalizeOrchestratorVersion("1.0.0"), "1.0.0")
        XCTAssertEqual(SmithersClient.normalizeOrchestratorVersion("10.20.30-beta.1"), "10.20.30-beta.1")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(SmithersClient.normalizeOrchestratorVersion("  0.16.8\n"), "0.16.8")
    }
}
