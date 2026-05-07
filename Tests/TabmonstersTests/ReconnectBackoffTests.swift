import XCTest
@testable import SmithersGUI

final class ReconnectBackoffTests: XCTestCase {

    func testInitialDelay() {
        let backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.currentDelay, 1.0)
        XCTAssertEqual(backoff.attempt, 0)
    }

    func testFirstFailureDelay() {
        var backoff = ReconnectBackoff()
        backoff.recordFailure()
        XCTAssertEqual(backoff.attempt, 1)
        XCTAssertEqual(backoff.currentDelay, 1.0, accuracy: 0.01)
    }

    func testExponentialBackoffSequence() {
        var backoff = ReconnectBackoff()
        let expectedDelays: [TimeInterval] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0]

        for (index, expected) in expectedDelays.enumerated() {
            backoff.recordFailure()
            XCTAssertEqual(backoff.currentDelay, expected, accuracy: 0.01,
                           "Attempt \(index + 1): expected \(expected)s, got \(backoff.currentDelay)s")
        }
    }

    func testCapAt30Seconds() {
        var backoff = ReconnectBackoff()
        for _ in 0..<20 {
            backoff.recordFailure()
        }
        XCTAssertEqual(backoff.currentDelay, 30.0, accuracy: 0.01)
    }

    func testResetAfterSuccess() {
        var backoff = ReconnectBackoff()
        backoff.recordFailure()
        backoff.recordFailure()
        backoff.recordFailure()
        XCTAssertEqual(backoff.attempt, 3)
        XCTAssertEqual(backoff.currentDelay, 4.0, accuracy: 0.01)

        backoff.reset()
        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertEqual(backoff.currentDelay, 1.0, accuracy: 0.01)

        backoff.recordFailure()
        XCTAssertEqual(backoff.currentDelay, 1.0, accuracy: 0.01)
    }

    func testSequentialFailuresThenResetThenFailure() {
        var backoff = ReconnectBackoff()
        backoff.recordFailure() // 1s
        backoff.recordFailure() // 2s
        backoff.recordFailure() // 4s
        backoff.recordFailure() // 8s
        backoff.recordFailure() // 16s
        XCTAssertEqual(backoff.currentDelay, 16.0, accuracy: 0.01)

        backoff.reset()
        backoff.recordFailure()
        XCTAssertEqual(backoff.currentDelay, 1.0, accuracy: 0.01,
                       "After reset, next failure should start at 1s")
    }

    func testMultipleResetsAreIdempotent() {
        var backoff = ReconnectBackoff()
        backoff.recordFailure()
        backoff.reset()
        backoff.reset()
        backoff.reset()
        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertEqual(backoff.currentDelay, 1.0)
    }
}
