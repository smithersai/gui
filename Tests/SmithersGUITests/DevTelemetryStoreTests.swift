import XCTest
@testable import SmithersGUI

// MARK: - DevTelemetryEvent model tests

final class DevTelemetryEventTests: XCTestCase {

    private func makeEvent(
        id: UInt64 = 1,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        level: LogLevel = .info,
        subsystem: String = "rpc",
        name: String = "call",
        durationMs: Int64? = nil,
        fieldsJSON: String? = nil,
        source: DevTelemetryEvent.Source = .zig
    ) -> DevTelemetryEvent {
        DevTelemetryEvent(
            id: id,
            timestamp: timestamp,
            level: level,
            subsystem: subsystem,
            name: name,
            durationMs: durationMs,
            fieldsJSON: fieldsJSON,
            source: source
        )
    }

    func testOneLinerWithSubsystemAndName() {
        let e = makeEvent(subsystem: "rpc", name: "ping")
        XCTAssertEqual(e.oneLiner, "rpc·ping")
    }

    func testOneLinerWithDuration() {
        let e = makeEvent(subsystem: "rpc", name: "ping", durationMs: 42)
        XCTAssertEqual(e.oneLiner, "rpc·ping 42ms")
    }

    func testOneLinerWithFieldsJSON() {
        let e = makeEvent(subsystem: "rpc", name: "ping", fieldsJSON: "{\"k\":\"v\"}")
        XCTAssertEqual(e.oneLiner, "rpc·ping {\"k\":\"v\"}")
    }

    func testOneLinerWithDurationAndFields() {
        let e = makeEvent(subsystem: "ui", name: "click", durationMs: 7, fieldsJSON: "{\"a\":1}")
        XCTAssertEqual(e.oneLiner, "ui·click 7ms {\"a\":1}")
    }

    func testOneLinerOmitsNilDuration() {
        let e = makeEvent(subsystem: "x", name: "y", durationMs: nil)
        XCTAssertFalse(e.oneLiner.contains("ms"))
    }

    func testEquatable() {
        let a = makeEvent(id: 1)
        let b = makeEvent(id: 1)
        let c = makeEvent(id: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testSourceRawValues() {
        XCTAssertEqual(DevTelemetryEvent.Source.zig.rawValue, "zig")
        XCTAssertEqual(DevTelemetryEvent.Source.swift.rawValue, "swift")
    }
}

// MARK: - DevTelemetryMethodStat model tests

final class DevTelemetryMethodStatTests: XCTestCase {

    private func makeStat(
        id: String = "rpc.ping",
        count: UInt64 = 1,
        errors: UInt64 = 0,
        lastMs: Int64 = 0,
        maxMs: Int64 = 0,
        avgMs: Double = 0
    ) -> DevTelemetryMethodStat {
        DevTelemetryMethodStat(
            id: id,
            count: count,
            errors: errors,
            lastMs: lastMs,
            maxMs: maxMs,
            avgMs: avgMs,
            buckets: [],
            bucketUpperMs: []
        )
    }

    func testKeyMirrorsId() {
        let s = makeStat(id: "rpc.x")
        XCTAssertEqual(s.key, "rpc.x")
        XCTAssertEqual(s.id, s.key)
    }

    func testErrorRateZeroWhenCountZero() {
        let s = makeStat(count: 0, errors: 0)
        XCTAssertEqual(s.errorRate, 0)
    }

    func testErrorRateZeroWhenNoErrors() {
        let s = makeStat(count: 100, errors: 0)
        XCTAssertEqual(s.errorRate, 0)
    }

    func testErrorRateHalf() {
        let s = makeStat(count: 10, errors: 5)
        XCTAssertEqual(s.errorRate, 0.5, accuracy: 1e-9)
    }

    func testErrorRateAllErrors() {
        let s = makeStat(count: 4, errors: 4)
        XCTAssertEqual(s.errorRate, 1.0, accuracy: 1e-9)
    }

    func testErrorRateGuardWithErrorsButZeroCount() {
        // Pathological but the guard should prevent division by zero.
        let s = makeStat(count: 0, errors: 7)
        XCTAssertEqual(s.errorRate, 0)
    }

    func testEquatable() {
        let a = makeStat(id: "k", count: 1)
        let b = makeStat(id: "k", count: 1)
        let c = makeStat(id: "k", count: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - DevTelemetrySnapshot model tests

final class DevTelemetrySnapshotTests: XCTestCase {

    func testEmptyDefaults() {
        let s = DevTelemetrySnapshot.empty
        XCTAssertEqual(s.capturedAt, .distantPast)
        XCTAssertEqual(s.startedAtMs, 0)
        XCTAssertEqual(s.nowMs, 0)
        XCTAssertEqual(s.totalEventSeq, 0)
        XCTAssertEqual(s.droppedEvents, 0)
        XCTAssertEqual(s.ringCapacity, 0)
        XCTAssertEqual(s.minLevel, 1)
        XCTAssertTrue(s.counters.isEmpty)
        XCTAssertTrue(s.methods.isEmpty)
    }

    func testEqualityIgnoresNowMsAndStartedAtMs() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = DevTelemetrySnapshot(
            capturedAt: now, startedAtMs: 1, nowMs: 100,
            totalEventSeq: 5, droppedEvents: 0, ringCapacity: 1024,
            minLevel: 1, counters: [("c", 1)], methods: []
        )
        let b = DevTelemetrySnapshot(
            capturedAt: now, startedAtMs: 999, nowMs: 12345,
            totalEventSeq: 5, droppedEvents: 0, ringCapacity: 9999,
            minLevel: 1, counters: [("c", 1)], methods: []
        )
        // Custom == ignores startedAtMs, nowMs, ringCapacity, minLevel.
        XCTAssertEqual(a, b)
    }

    func testEqualityComparesCountersInOrder() {
        let now = Date()
        let a = DevTelemetrySnapshot(
            capturedAt: now, startedAtMs: 0, nowMs: 0,
            totalEventSeq: 0, droppedEvents: 0, ringCapacity: 0,
            minLevel: 0, counters: [("a", 1), ("b", 2)], methods: []
        )
        let b = DevTelemetrySnapshot(
            capturedAt: now, startedAtMs: 0, nowMs: 0,
            totalEventSeq: 0, droppedEvents: 0, ringCapacity: 0,
            minLevel: 0, counters: [("b", 2), ("a", 1)], methods: []
        )
        XCTAssertNotEqual(a, b)
    }

    func testInequalityDifferentTotalSeq() {
        let now = Date()
        let a = DevTelemetrySnapshot(
            capturedAt: now, startedAtMs: 0, nowMs: 0,
            totalEventSeq: 1, droppedEvents: 0, ringCapacity: 0,
            minLevel: 0, counters: [], methods: []
        )
        let b = DevTelemetrySnapshot(
            capturedAt: now, startedAtMs: 0, nowMs: 0,
            totalEventSeq: 2, droppedEvents: 0, ringCapacity: 0,
            minLevel: 0, counters: [], methods: []
        )
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - LogLevel ↔ obsLevel mapping

final class LogLevelObsLevelMappingTests: XCTestCase {

    func testObsLevelForward() {
        XCTAssertEqual(LogLevel.debug.obsLevel, 1)
        XCTAssertEqual(LogLevel.info.obsLevel, 2)
        XCTAssertEqual(LogLevel.warning.obsLevel, 3)
        XCTAssertEqual(LogLevel.error.obsLevel, 4)
    }

    func testObsLevelInitTrace() {
        XCTAssertEqual(LogLevel(obsLevel: 0), .debug)
    }

    func testObsLevelInitDebug() {
        XCTAssertEqual(LogLevel(obsLevel: 1), .debug)
    }

    func testObsLevelInitInfo() {
        XCTAssertEqual(LogLevel(obsLevel: 2), .info)
    }

    func testObsLevelInitWarning() {
        XCTAssertEqual(LogLevel(obsLevel: 3), .warning)
    }

    func testObsLevelInitError() {
        XCTAssertEqual(LogLevel(obsLevel: 4), .error)
    }

    func testObsLevelInitOutOfRangeMapsToError() {
        XCTAssertEqual(LogLevel(obsLevel: 99), .error)
        XCTAssertEqual(LogLevel(obsLevel: -5), .error)
    }

    func testObsLevelRoundTripForKnownLevels() {
        for level in [LogLevel.debug, .info, .warning, .error] {
            let round = LogLevel(obsLevel: level.obsLevel)
            XCTAssertEqual(level, round)
        }
    }
}

// MARK: - DevTelemetryStore tests

@MainActor
final class DevTelemetryStoreTests: XCTestCase {

    private func makeStore() -> DevTelemetryStore {
        // Fresh, isolated instance — avoids polluting `.shared`.
        DevTelemetryStore()
    }

    // Initial state -------------------------------------------------------

    func testInitialEmptyState() {
        let s = makeStore()
        XCTAssertTrue(s.events.isEmpty)
        XCTAssertFalse(s.isPolling)
        XCTAssertNil(s.lastPollError)
        // The default snapshot should equal `.empty` (capturedAt = distantPast).
        XCTAssertEqual(s.snapshot.capturedAt, .distantPast)
        XCTAssertEqual(s.snapshot.totalEventSeq, 0)
    }

    func testSharedSingletonIsStable() {
        let a = DevTelemetryStore.shared
        let b = DevTelemetryStore.shared
        XCTAssertTrue(a === b)
    }

    // emit() ingest -------------------------------------------------------

    func testEmitSingleEventAppendsLocally() {
        let s = makeStore()
        s.emit(level: .info, subsystem: "test", name: "single")
        XCTAssertEqual(s.events.count, 1)
        let e = s.events[0]
        XCTAssertEqual(e.subsystem, "test")
        XCTAssertEqual(e.name, "single")
        XCTAssertEqual(e.source, .swift)
        XCTAssertEqual(e.level, .info)
        XCTAssertNil(e.durationMs)
    }

    func testEmitMultipleEvents() {
        let s = makeStore()
        for i in 0..<5 {
            s.emit(subsystem: "sys", name: "n\(i)")
        }
        XCTAssertEqual(s.events.count, 5)
        XCTAssertEqual(s.events.map(\.name), ["n0", "n1", "n2", "n3", "n4"])
    }

    func testEmitWithDurationAndFields() {
        let s = makeStore()
        s.emit(
            level: .warning,
            subsystem: "rpc",
            name: "withFields",
            durationMs: 123,
            fields: ["b": "2", "a": "1"]
        )
        XCTAssertEqual(s.events.count, 1)
        let e = s.events[0]
        XCTAssertEqual(e.durationMs, 123)
        XCTAssertEqual(e.level, .warning)
        // Sorted-keys JSON encoding -> "a" before "b".
        XCTAssertEqual(e.fieldsJSON, #"{"a":"1","b":"2"}"#)
    }

    func testEmitNilFieldsProducesNilJSON() {
        let s = makeStore()
        s.emit(subsystem: "x", name: "y", fields: nil)
        XCTAssertNil(s.events[0].fieldsJSON)
    }

    func testEmitEmptyFieldsProducesEmptyObjectJSON() {
        let s = makeStore()
        s.emit(subsystem: "x", name: "y", fields: [:])
        XCTAssertEqual(s.events[0].fieldsJSON, "{}")
    }

    func testEmitAllLogLevels() {
        let s = makeStore()
        for level in [LogLevel.debug, .info, .warning, .error] {
            s.emit(level: level, subsystem: "lvl", name: level.rawValue)
        }
        XCTAssertEqual(s.events.count, 4)
        XCTAssertEqual(s.events.map(\.level), [.debug, .info, .warning, .error])
    }

    func testEmitSentinelIDsAreDistinct() {
        let s = makeStore()
        s.emit(subsystem: "a", name: "1")
        s.emit(subsystem: "a", name: "2")
        s.emit(subsystem: "a", name: "3")
        let ids = Set(s.events.map(\.id))
        XCTAssertEqual(ids.count, 3, "Sentinel IDs should be distinct between local mirrors")
    }

    func testEmitMirrorIDsAreInUpperRange() {
        // Documented sentinel: UInt64.max - count, never collides with zig seq.
        let s = makeStore()
        s.emit(subsystem: "x", name: "y")
        XCTAssertGreaterThan(s.events[0].id, UInt64.max / 2)
    }

    func testEmitMirrorTimestampIsRecent() {
        let s = makeStore()
        let before = Date()
        s.emit(subsystem: "x", name: "y")
        let after = Date()
        let ts = s.events[0].timestamp
        XCTAssertGreaterThanOrEqual(ts, before)
        XCTAssertLessThanOrEqual(ts, after)
    }

    func testEmitSourceIsSwift() {
        let s = makeStore()
        s.emit(subsystem: "a", name: "b")
        XCTAssertEqual(s.events[0].source, .swift)
    }

    // Buffer / ringbuffer behavior ---------------------------------------

    func testBufferAtCapacityKeepsAllEvents() {
        let s = makeStore()
        let cap = 1000 // matches private bufferLimit
        for i in 0..<cap {
            s.emit(subsystem: "buf", name: "e\(i)")
        }
        XCTAssertEqual(s.events.count, cap)
        XCTAssertEqual(s.events.first?.name, "e0")
        XCTAssertEqual(s.events.last?.name, "e\(cap - 1)")
    }

    func testBufferCapacityPlusOneDropsOldest() {
        let s = makeStore()
        let cap = 1000
        for i in 0...cap { // cap + 1 events
            s.emit(subsystem: "buf", name: "e\(i)")
        }
        XCTAssertEqual(s.events.count, cap)
        // First event ("e0") was evicted, "e1" is the new head.
        XCTAssertEqual(s.events.first?.name, "e1")
        XCTAssertEqual(s.events.last?.name, "e\(cap)")
    }

    func testBufferTwiceCapacityRetainsLatestWindow() {
        let s = makeStore()
        let cap = 1000
        for i in 0..<(cap * 2) {
            s.emit(subsystem: "buf", name: "e\(i)")
        }
        XCTAssertEqual(s.events.count, cap)
        XCTAssertEqual(s.events.first?.name, "e\(cap)")
        XCTAssertEqual(s.events.last?.name, "e\((cap * 2) - 1)")
    }

    // clearLocalBuffer ---------------------------------------------------

    func testClearLocalBufferEmptiesEvents() {
        let s = makeStore()
        s.emit(subsystem: "x", name: "1")
        s.emit(subsystem: "x", name: "2")
        XCTAssertEqual(s.events.count, 2)
        s.clearLocalBuffer()
        XCTAssertTrue(s.events.isEmpty)
    }

    func testClearLocalBufferIdempotent() {
        let s = makeStore()
        s.clearLocalBuffer()
        s.clearLocalBuffer()
        XCTAssertTrue(s.events.isEmpty)
    }

    func testClearLocalBufferDoesNotResetIsPolling() {
        let s = makeStore()
        s.start()
        s.clearLocalBuffer()
        XCTAssertTrue(s.isPolling)
        s.stop()
    }

    // Polling lifecycle --------------------------------------------------

    func testStartTogglesIsPolling() {
        let s = makeStore()
        XCTAssertFalse(s.isPolling)
        s.start()
        XCTAssertTrue(s.isPolling)
        s.stop()
    }

    func testStopWhileNotStartedIsNoOp() {
        let s = makeStore()
        XCTAssertFalse(s.isPolling)
        s.stop()
        XCTAssertFalse(s.isPolling)
    }

    func testDoubleStartIsIdempotent() {
        let s = makeStore()
        s.start()
        s.start()
        XCTAssertTrue(s.isPolling)
        s.stop()
    }

    func testStartStopRoundTrip() {
        let s = makeStore()
        s.start()
        s.stop()
        XCTAssertFalse(s.isPolling)
        s.start()
        XCTAssertTrue(s.isPolling)
        s.stop()
        XCTAssertFalse(s.isPolling)
    }

    func testStopAfterStartClearsTimer() {
        let s = makeStore()
        s.start()
        s.stop()
        // Re-start should still work after stop.
        s.start()
        XCTAssertTrue(s.isPolling)
        s.stop()
    }

    // setPollInterval ---------------------------------------------------

    func testSetPollIntervalWhileStoppedDoesNotStartPolling() {
        let s = makeStore()
        s.setPollInterval(1.0)
        XCTAssertFalse(s.isPolling)
    }

    func testSetPollIntervalWhileRunningRestartsPoll() {
        let s = makeStore()
        s.start()
        s.setPollInterval(1.0)
        XCTAssertTrue(s.isPolling, "Setting interval while running should stop+start, leaving polling on")
        s.stop()
    }

    func testSetPollIntervalClampsBelowHalfSecond() {
        // Internal clamp: max(0.5, seconds). We can only verify by behavior:
        // calling with 0 (or negative) shouldn't crash and the store should
        // continue working.
        let s = makeStore()
        s.setPollInterval(0)
        s.setPollInterval(-100)
        s.setPollInterval(0.1)
        XCTAssertFalse(s.isPolling)
    }

    func testSetPollIntervalLargeValueAcceptable() {
        let s = makeStore()
        s.setPollInterval(60)
        s.start()
        s.setPollInterval(300)
        XCTAssertTrue(s.isPolling)
        s.stop()
    }

    // poll() invocation --------------------------------------------------

    func testPollIsSafeWhenNotPolling() {
        let s = makeStore()
        s.poll()
        // Either the snapshot was updated to a real one, or it stayed `.empty`
        // (if FFI returned no data). Either way, no crash, no error.
        XCTAssertNotNil(s.snapshot)
    }

    func testPollUpdatesSnapshotCapturedAtWhenFFIYieldsData() {
        let s = makeStore()
        // Drive the FFI by emitting first, which forwards into libsmithers.
        s.emit(subsystem: "poll", name: "warmup")
        s.poll()
        // After emit + poll, the snapshot should at least be readable.
        // We don't assert specific seq because state is shared with the
        // process-global obs runtime, but the call must not error.
        XCTAssertNil(s.lastPollError, "poll should not produce a decode error against the real FFI")
    }

    // recordMethod / incrementCounter -----------------------------------
    // These forward straight into FFI; we verify they don't crash and
    // can be called repeatedly.

    func testRecordMethodSmoke() {
        let s = makeStore()
        s.recordMethod("rpc.test", durationMs: 10, isError: false)
        s.recordMethod("rpc.test", durationMs: 30, isError: false)
        s.recordMethod("rpc.test", durationMs: 5, isError: true)
        // No state observable from here; FFI accumulates in libsmithers.
        // Sanity: poll should still succeed.
        s.poll()
        XCTAssertNil(s.lastPollError)
    }

    func testRecordMethodWithExtremeDurations() {
        let s = makeStore()
        s.recordMethod("k", durationMs: 0, isError: false)
        s.recordMethod("k", durationMs: Int64.max, isError: false)
        s.recordMethod("k", durationMs: -1, isError: true)
        s.poll()
        XCTAssertNil(s.lastPollError)
    }

    func testIncrementCounterDefault() {
        let s = makeStore()
        s.incrementCounter("c.one")
        s.incrementCounter("c.one")
        s.poll()
        XCTAssertNil(s.lastPollError)
    }

    func testIncrementCounterWithDelta() {
        let s = makeStore()
        s.incrementCounter("c.delta", by: 100)
        s.incrementCounter("c.delta", by: 0)
        s.poll()
        XCTAssertNil(s.lastPollError)
    }

    // Concurrent ingest --------------------------------------------------

    func testConcurrentEmitsViaTaskGroupRespectBufferLimit() async {
        let s = makeStore()
        let totalTasks = 50
        let perTask = 40 // 2000 events total -> exceeds the 1000 buffer cap.

        await withTaskGroup(of: Void.self) { group in
            for t in 0..<totalTasks {
                group.addTask { @MainActor in
                    for i in 0..<perTask {
                        s.emit(subsystem: "race", name: "t\(t)-e\(i)")
                    }
                }
            }
        }

        // Total emitted = totalTasks * perTask = 2000; buffer cap = 1000.
        XCTAssertLessThanOrEqual(s.events.count, 1000)
        XCTAssertGreaterThan(s.events.count, 0)
    }

    func testConcurrentRecordMethodsDoNotCrash() async {
        let s = makeStore()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<32 {
                group.addTask { @MainActor in
                    for j in 0..<25 {
                        s.recordMethod("mm.\(i % 4)", durationMs: Int64(j), isError: j % 7 == 0)
                    }
                }
            }
        }
        s.poll()
        XCTAssertNil(s.lastPollError)
    }

    // Edge cases / boundary ----------------------------------------------

    func testEmitWithEmptySubsystemAndName() {
        let s = makeStore()
        s.emit(subsystem: "", name: "")
        XCTAssertEqual(s.events.count, 1)
        XCTAssertEqual(s.events[0].subsystem, "")
        XCTAssertEqual(s.events[0].name, "")
    }

    func testEmitWithUnicodeAndControlChars() {
        let s = makeStore()
        s.emit(
            subsystem: "✨",
            name: "naïve\nname",
            fields: ["café": "líne1\nlíne2", "🔑": "value"]
        )
        XCTAssertEqual(s.events.count, 1)
        let e = s.events[0]
        XCTAssertEqual(e.subsystem, "✨")
        XCTAssertEqual(e.name, "naïve\nname")
        // JSON should be valid (even if the raw bytes contain escapes).
        if let json = e.fieldsJSON?.data(using: .utf8) {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: json))
        } else {
            XCTFail("fieldsJSON should be encodable as UTF-8")
        }
    }

    func testEmitWithVeryLongStrings() {
        let s = makeStore()
        let long = String(repeating: "x", count: 10_000)
        s.emit(subsystem: "long", name: long, fields: ["k": long])
        XCTAssertEqual(s.events.count, 1)
        XCTAssertEqual(s.events[0].name.count, 10_000)
    }

    func testEmitNegativeDurationPreserved() {
        let s = makeStore()
        s.emit(subsystem: "x", name: "y", durationMs: -1)
        XCTAssertEqual(s.events[0].durationMs, -1)
    }

    func testStartStopMultipleCyclesStability() {
        let s = makeStore()
        for _ in 0..<5 {
            s.start()
            s.stop()
        }
        XCTAssertFalse(s.isPolling)
    }

    func testPollAfterClearDoesNotResurrectEvents() {
        let s = makeStore()
        s.emit(subsystem: "x", name: "1")
        s.clearLocalBuffer()
        s.poll() // drains zig events newer than lastSeqDrained=0
        // We can't assert events.count == 0 because the FFI ring may legitimately
        // surface other events from prior tests in the same process. But the
        // call must not error.
        XCTAssertNil(s.lastPollError)
    }
}
