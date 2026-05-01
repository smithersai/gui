// SmithersiOSTests.swift — iOS unit test scaffold (ticket 0121).
//
// Purpose: give the iOS target a real xctest bundle so CI can exercise
// `xcodebuild test` on the iOS simulator. Actual coverage grows as shared
// view-model code lands in 0122.

#if os(iOS)
import XCTest
@testable import SmithersiOS

final class SmithersiOSSmokeTests: XCTestCase {
    func testBundleIdentifierMatchesExpectation() {
        // Sanity check that we are linked into the SmithersiOS target. The
        // bundle id may be nil when tests run in-process; we only assert the
        // test binary itself loads.
        XCTAssertNotNil(Bundle(for: Self.self).bundleIdentifier)
    }

    func testTrueIsTrue() {
        // Keep at least one always-green assertion so the test bundle is
        // obviously wired when `xcodebuild test` runs in CI.
        XCTAssertTrue(true)
    }
}
#endif
