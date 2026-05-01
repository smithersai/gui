import XCTest
@testable import SmithersGUI

final class ScrubberDebounceTests: XCTestCase {
    func testTenEventsInsideWindowEmitOnce() {
        let queue = DispatchQueue(label: "scrubber.debounce.once")
        let debouncer = FrameScrubDebouncer(intervalMs: 50, queue: queue)
        defer { debouncer.cancel() }

        let lock = NSLock()
        var fired: [Int] = []

        for value in 0..<10 {
            debouncer.schedule(frameNo: value) { frame in
                lock.lock()
                fired.append(frame)
                lock.unlock()
            }
        }

        let exp = expectation(description: "debounce flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.last, 9)
    }

    func testSteadyDragAtHundredEventsPerSecondEmitsRoughlyTwentyRPCs() {
        let queue = DispatchQueue(label: "scrubber.debounce.steady")
        let debouncer = FrameScrubDebouncer(intervalMs: 50, queue: queue)
        defer { debouncer.cancel() }

        let lock = NSLock()
        var fireCount = 0

        let producerDone = expectation(description: "producer done")
        DispatchQueue.global().async {
            for value in 0..<100 {
                debouncer.schedule(frameNo: value) { _ in
                    lock.lock()
                    fireCount += 1
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            producerDone.fulfill()
        }

        wait(for: [producerDone], timeout: 3.0)

        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            settle.fulfill()
        }
        wait(for: [settle], timeout: 1.0)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertGreaterThanOrEqual(fireCount, 15)
        XCTAssertLessThanOrEqual(fireCount, 30)
    }

    func testTrailingEdgeDeliversFinalFrame() {
        let queue = DispatchQueue(label: "scrubber.debounce.trailing")
        let debouncer = FrameScrubDebouncer(intervalMs: 50, queue: queue)
        defer { debouncer.cancel() }

        let lock = NSLock()
        var fired: [Int] = []

        debouncer.schedule(frameNo: 3) { frame in
            lock.lock()
            fired.append(frame)
            lock.unlock()
        }

        Thread.sleep(forTimeInterval: 0.01)
        debouncer.schedule(frameNo: 7) { frame in
            lock.lock()
            fired.append(frame)
            lock.unlock()
        }

        Thread.sleep(forTimeInterval: 0.01)
        debouncer.schedule(frameNo: 9) { frame in
            lock.lock()
            fired.append(frame)
            lock.unlock()
        }

        let exp = expectation(description: "trailing flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(fired.last, 9)
    }
}
