import XCTest
@testable import SmithersGUI

final class LiveRunLayoutModeTests: XCTestCase {
    func testModeUsesWideAtBreakpoint() {
        XCTAssertEqual(LiveRunLayoutMode.forWidth(800, breakpoint: 800), .wide)
    }

    func testModeUsesNarrowBelowBreakpoint() {
        XCTAssertEqual(LiveRunLayoutMode.forWidth(799.9, breakpoint: 800), .narrow)
    }

    func testModeUsesWideAboveBreakpoint() {
        XCTAssertEqual(LiveRunLayoutMode.forWidth(1400, breakpoint: 800), .wide)
    }
}
