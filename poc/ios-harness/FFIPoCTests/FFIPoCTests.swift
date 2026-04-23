// XCTest: 1000 rapid ticks → 1000 ordered main-thread updates, no drops, no
// reorders. Under TSan/ASan (simulator-gated) there should be no warnings.

import XCTest
@testable import FFIPoC

final class FFIPoCTests: XCTestCase {

    func testRapidTicksDeliverOrderedNoDrops() throws {
        let N: UInt64 = 1000
        guard let session = ffi_new_session() else {
            XCTFail("ffi_new_session failed")
            return
        }
        defer { ffi_close_session(session) }

        let collector = Collector()
        let box = Unmanaged.passRetained(CollectorBox(collector: collector))
        defer { box.release() }
        let raw = UnsafeMutableRawPointer(box.toOpaque())

        let handle = ffi_subscribe(session, testCollectorCallback, raw)
        XCTAssertNotEqual(handle, 0, "subscribe failed")
        defer { ffi_unsubscribe(session, handle) }

        // Fire 1000 ticks from a background queue.
        let queue = DispatchQueue.global(qos: .userInitiated)
        let done = expectation(description: "ticks fired")
        queue.async {
            for _ in 0..<N {
                _ = ffi_tick(session)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)

        // Wait until N updates reach main.
        let receivedAll = expectation(description: "all updates received on main")
        let started = Date()
        func poll() {
            if collector.count == Int(N) {
                receivedAll.fulfill()
                return
            }
            if Date().timeIntervalSince(started) > 10.0 {
                XCTFail("timeout waiting for updates; got \(collector.count)/\(N)")
                receivedAll.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
        wait(for: [receivedAll], timeout: 15.0)

        // Invariants.
        XCTAssertEqual(collector.count, Int(N), "expected \(N) updates")
        // Ordered + no gaps.
        for (i, v) in collector.values.enumerated() {
            XCTAssertEqual(v, UInt64(i + 1), "out of order at index \(i)")
        }
        XCTAssertTrue(collector.allOnMain, "not all callbacks dispatched to main")
    }

    func testUnsubscribeStopsCallbacks() {
        guard let session = ffi_new_session() else {
            XCTFail("session")
            return
        }
        defer { ffi_close_session(session) }

        let collector = Collector()
        let box = Unmanaged.passRetained(CollectorBox(collector: collector))
        defer { box.release() }
        let raw = UnsafeMutableRawPointer(box.toOpaque())

        let handle = ffi_subscribe(session, testCollectorCallback, raw)
        _ = ffi_tick(session)
        // Allow one delivery.
        let first = expectation(description: "first")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { first.fulfill() }
        wait(for: [first], timeout: 1.0)

        let before = collector.count
        ffi_unsubscribe(session, handle)
        _ = ffi_tick(session)
        _ = ffi_tick(session)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)
        XCTAssertEqual(collector.count, before, "callbacks arrived after unsubscribe")
    }

    func testCloseWithLiveSubscriberDoesNotCrash() {
        guard let session = ffi_new_session() else {
            XCTFail("session")
            return
        }
        let collector = Collector()
        let box = Unmanaged.passRetained(CollectorBox(collector: collector))
        defer { box.release() }
        let raw = UnsafeMutableRawPointer(box.toOpaque())
        _ = ffi_subscribe(session, testCollectorCallback, raw)
        _ = ffi_tick(session)
        ffi_close_session(session)
        // If we got here, we didn't crash.
    }
}

final class Collector {
    private let lock = NSLock()
    private var _values: [UInt64] = []
    private var _allOnMain: Bool = true

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _values.count
    }

    var values: [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    var allOnMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return _allOnMain
    }

    func record(_ v: UInt64, onMain: Bool) {
        lock.lock()
        _values.append(v)
        if !onMain { _allOnMain = false }
        lock.unlock()
    }
}

final class CollectorBox {
    let collector: Collector
    init(collector: Collector) { self.collector = collector }
}

// Called on Zig loop thread; we hop to main and then record.
@_cdecl("testCollectorCallback")
func testCollectorCallback(counter: UInt64, userData: UnsafeMutableRawPointer?) {
    guard let ud = userData else { return }
    let box = Unmanaged<CollectorBox>.fromOpaque(ud).takeUnretainedValue()
    DispatchQueue.main.async {
        box.collector.record(counter, onMain: Thread.isMainThread)
    }
}
