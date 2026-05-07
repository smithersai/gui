import XCTest
@testable import SmithersGUI

final class ElapsedTimeFormatTests: XCTestCase {

    func testZeroSeconds() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 0), "00:00")
    }

    func test59Seconds() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 59), "00:59")
    }

    func test60Seconds() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 60), "01:00")
    }

    func test3599Seconds() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 3599), "59:59")
    }

    func test3600SecondsShowsHours() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 3600), "01:00:00")
    }

    func test3601Seconds() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 3601), "01:00:01")
    }

    func test86401SecondsOver24Hours() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 86401), "24:00:01")
    }

    func testNegativeReturnsClamped() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: -5), "00:00")
    }

    func testNegativeLargeReturnsClamped() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: -9999), "00:00")
    }

    func test1Second() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 1), "00:01")
    }

    func test90Seconds() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 90), "01:30")
    }

    func test100Hours() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 360_000), "100:00:00")
    }

    func testMiddleOfHour() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 5025), "01:23:45")
    }
}
