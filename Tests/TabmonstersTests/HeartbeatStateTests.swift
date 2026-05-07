import XCTest
@testable import SmithersGUI

final class HeartbeatStateTests: XCTestCase {

    private let now = Date()

    // MARK: - Nil / missing events

    func testNilLastEventAtReturnsRed() {
        let result = HeartbeatState.color(now: now, lastEventAt: nil, heartbeatMs: 1000)
        XCTAssertEqual(result, .red)
    }

    // MARK: - Green region (elapsed <= heartbeatMs * 2)

    func testZeroElapsedReturnsGreen() {
        let result = HeartbeatState.color(now: now, lastEventAt: now, heartbeatMs: 1000)
        XCTAssertEqual(result, .green)
    }

    func testWithinTwoHeartbeatsReturnsGreen() {
        let lastEvent = now.addingTimeInterval(-1.5)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .green)
    }

    func testExactlyAtTwoHeartbeatsBoundaryReturnsGreen() {
        let lastEvent = now.addingTimeInterval(-2.0)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .green, "Boundary at 2x is inclusive → green")
    }

    // MARK: - Amber region (heartbeatMs * 2 < elapsed < heartbeatMs * 5)

    func testJustAboveTwoHeartbeatsReturnsAmber() {
        let lastEvent = now.addingTimeInterval(-2.001)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .amber)
    }

    func testThreeHeartbeatsReturnsAmber() {
        let lastEvent = now.addingTimeInterval(-3.0)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .amber)
    }

    func testJustBelowFiveHeartbeatsReturnsAmber() {
        let lastEvent = now.addingTimeInterval(-4.999)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .amber)
    }

    // MARK: - Red region (elapsed >= heartbeatMs * 5)

    func testExactlyAtFiveHeartbeatsBoundaryReturnsRed() {
        let lastEvent = now.addingTimeInterval(-5.0)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .red, "Boundary at 5x → red")
    }

    func testBeyondFiveHeartbeatsReturnsRed() {
        let lastEvent = now.addingTimeInterval(-10.0)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .red)
    }

    // MARK: - Degenerate heartbeatMs

    func testZeroHeartbeatMsReturnsRed() {
        let result = HeartbeatState.color(now: now, lastEventAt: now, heartbeatMs: 0)
        XCTAssertEqual(result, .red)
    }

    func testNegativeHeartbeatMsReturnsRed() {
        let result = HeartbeatState.color(now: now, lastEventAt: now, heartbeatMs: -100)
        XCTAssertEqual(result, .red)
    }

    // MARK: - Large heartbeatMs (overflow safety)

    func testVeryLargeHeartbeatMsHandlesGracefully() {
        let lastEvent = now.addingTimeInterval(-3600)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 86_400_000)
        XCTAssertEqual(result, .green, "1h elapsed is within 2x of 24h interval")
    }

    // MARK: - Clock skew

    func testClockSkewFutureEventReturnsGreen() {
        let futureEvent = now.addingTimeInterval(5.0)
        let result = HeartbeatState.color(now: now, lastEventAt: futureEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .green)
    }

    // MARK: - Fast heartbeat (100ms)

    func testFastHeartbeat100msGreen() {
        let lastEvent = now.addingTimeInterval(-0.15)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 100)
        XCTAssertEqual(result, .green)
    }

    func testFastHeartbeat100msAmber() {
        let lastEvent = now.addingTimeInterval(-0.3)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 100)
        XCTAssertEqual(result, .amber)
    }

    func testFastHeartbeat100msRed() {
        let lastEvent = now.addingTimeInterval(-0.6)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 100)
        XCTAssertEqual(result, .red)
    }

    // MARK: - Slow heartbeat (60,000ms)

    func testSlowHeartbeat60sGreen() {
        let lastEvent = now.addingTimeInterval(-90)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 60_000)
        XCTAssertEqual(result, .green)
    }

    func testSlowHeartbeat60sAmber() {
        let lastEvent = now.addingTimeInterval(-200)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 60_000)
        XCTAssertEqual(result, .amber)
    }

    func testSlowHeartbeat60sRed() {
        let lastEvent = now.addingTimeInterval(-400)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 60_000)
        XCTAssertEqual(result, .red)
    }

    // MARK: - Transition sequences

    func testGreenToAmberToRedTransition() {
        let heartbeatMs = 1000
        let green = HeartbeatState.color(now: now, lastEventAt: now.addingTimeInterval(-1.0), heartbeatMs: heartbeatMs)
        let amber = HeartbeatState.color(now: now, lastEventAt: now.addingTimeInterval(-3.0), heartbeatMs: heartbeatMs)
        let red = HeartbeatState.color(now: now, lastEventAt: now.addingTimeInterval(-6.0), heartbeatMs: heartbeatMs)

        XCTAssertEqual(green, .green)
        XCTAssertEqual(amber, .amber)
        XCTAssertEqual(red, .red)
    }

    func testRecoveryRedToGreen() {
        let heartbeatMs = 1000
        let red = HeartbeatState.color(now: now, lastEventAt: now.addingTimeInterval(-10.0), heartbeatMs: heartbeatMs)
        let green = HeartbeatState.color(now: now, lastEventAt: now, heartbeatMs: heartbeatMs)

        XCTAssertEqual(red, .red)
        XCTAssertEqual(green, .green)
    }

    // MARK: - Events at 500ms intervals (input-boundary test)

    func testEventsEvery500msWithDefaultHeartbeat() {
        let lastEvent = now.addingTimeInterval(-0.5)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .green, "500ms < 2000ms threshold")
    }

    // MARK: - Events every 10s with heartbeatMs=1000 (input-boundary test)

    func testEventsEvery10sWithHeartbeat1000ms() {
        let lastEvent = now.addingTimeInterval(-10.0)
        let result = HeartbeatState.color(now: now, lastEventAt: lastEvent, heartbeatMs: 1000)
        XCTAssertEqual(result, .red, "10s = 10x heartbeat → red")
    }
}
