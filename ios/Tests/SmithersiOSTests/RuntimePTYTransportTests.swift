#if os(iOS)
import Combine
import Foundation
import XCTest
@testable import SmithersiOS

@MainActor
final class RuntimePTYTransportTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func test_successfulAttach_setsStateConnected() async {
        let sleeper = ManualSleeper()
        let session = FakeRuntimeSession(
            results: [.success(FakeRuntimePTY())],
            now: { sleeper.elapsedSeconds }
        )
        let transport = RuntimePTYTransport(session: session, sessionID: "session-success", sleeper: sleeper)
        defer { transport.stop() }

        transport.start(onBytes: { _ in }, onClosed: {})

        let connected = await waitUntil(timeout: 1) {
            transport.connectionState == .connected
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.attachCount, 1)
    }

    func test_attachFailure_entersReconnectingAndRetriesAfterOneSecond() async {
        let sleeper = ManualSleeper()
        let session = FakeRuntimeSession(results: [
            .failure(FakeRuntimeError.attachFailed),
            .success(FakeRuntimePTY()),
        ], now: { sleeper.elapsedSeconds })
        let transport = RuntimePTYTransport(session: session, sessionID: "session-retry-once", sleeper: sleeper)
        defer { transport.stop() }

        transport.start(onBytes: { _ in }, onClosed: {})

        let reconnecting = await waitUntil(timeout: 1) {
            transport.connectionState == .reconnecting
        }
        XCTAssertTrue(reconnecting)

        await sleeper.waitForSleepCallCount(1)
        sleeper.advance(bySeconds: 1)

        let retried = await waitUntil(timeout: 1) {
            session.attachCount >= 2
        }
        XCTAssertTrue(retried)

        let connected = await waitUntil(timeout: 1) {
            transport.connectionState == .connected
        }
        XCTAssertTrue(connected)
        guard let firstInterval = session.attachIntervals.first else {
            return XCTFail("Expected one retry interval")
        }
        XCTAssertEqual(firstInterval, 1, accuracy: 0.001)
    }

    func test_fiveFailedRetries_disconnectAndStopRetryingWithoutUserAction() async {
        let sleeper = ManualSleeper()
        var closedCount = 0
        let session = FakeRuntimeSession(
            defaultResult: .failure(FakeRuntimeError.attachFailed),
            now: { sleeper.elapsedSeconds }
        )
        let transport = RuntimePTYTransport(session: session, sessionID: "session-exhaust", sleeper: sleeper)
        defer { transport.stop() }

        transport.start(onBytes: { _ in }, onClosed: { closedCount += 1 })

        await exhaustRetryBudget(sleeper: sleeper)

        let exhausted = await waitUntil(timeout: 1) {
            session.attachCount >= 6 && transport.connectionState == .disconnected
        }
        XCTAssertTrue(exhausted)
        XCTAssertEqual(closedCount, 1)

        let attemptsAfterDisconnect = session.attachCount
        sleeper.advance(bySeconds: 60)
        await Task.yield()
        XCTAssertEqual(session.attachCount, attemptsAfterDisconnect)
    }

    func test_explicitRetryAfterDisconnected_setsConnectingAndResetsRetryBudget() async {
        let sleeper = ManualSleeper()
        let session = FakeRuntimeSession(
            defaultResult: .failure(FakeRuntimeError.attachFailed),
            now: { sleeper.elapsedSeconds }
        )
        let transport = RuntimePTYTransport(session: session, sessionID: "session-manual-retry", sleeper: sleeper)
        var observedStates: [TerminalSurfaceConnectionState] = []
        transport.connectionStatePublisher
            .sink { observedStates.append($0) }
            .store(in: &cancellables)
        defer { transport.stop() }

        transport.start(onBytes: { _ in }, onClosed: {})

        await exhaustRetryBudget(sleeper: sleeper)

        let disconnected = await waitUntil(timeout: 1) {
            transport.connectionState == .disconnected
        }
        XCTAssertTrue(disconnected)
        XCTAssertGreaterThanOrEqual(session.attachCount, 6)

        observedStates.removeAll()
        session.enqueue(results: [
            .failure(FakeRuntimeError.attachFailed),
            .success(FakeRuntimePTY()),
        ])
        transport.reconnect()

        XCTAssertTrue(observedStates.contains(.connecting))
        await sleeper.waitForSleepCallCount(6)
        sleeper.advance(bySeconds: 1)

        let connected = await waitUntil(timeout: 1) {
            transport.connectionState == .connected
        }
        XCTAssertTrue(connected)
    }

    func test_backoffIntervalsFollowOneTwoFourEightSixteenSeconds() async {
        let sleeper = ManualSleeper()
        let session = FakeRuntimeSession(
            defaultResult: .failure(FakeRuntimeError.attachFailed),
            now: { sleeper.elapsedSeconds }
        )
        let transport = RuntimePTYTransport(session: session, sessionID: "session-backoff", sleeper: sleeper)
        defer { transport.stop() }

        transport.start(onBytes: { _ in }, onClosed: {})

        await exhaustRetryBudget(sleeper: sleeper)

        let exhausted = await waitUntil(timeout: 1) {
            session.attachCount >= 6
        }
        XCTAssertTrue(exhausted)
        XCTAssertEqual(session.attachTimes.prefix(6).count, 6)

        let intervals = Array(session.attachIntervals.prefix(5))
        let expected: [TimeInterval] = [1, 2, 4, 8, 16]
        XCTAssertEqual(intervals.count, expected.count)
        for (actual, expectedInterval) in zip(intervals, expected) {
            XCTAssertEqual(actual, expectedInterval, accuracy: 0.001)
        }
        XCTAssertEqual(sleeper.requestedSleepSeconds, expected.map { Int($0) })
    }

    func test_stopDuringRetrySettlesDisconnectedAndCancelsZombieRetry() async {
        let sleeper = ManualSleeper()
        let session = FakeRuntimeSession(
            results: [.failure(FakeRuntimeError.attachFailed)],
            defaultResult: .success(FakeRuntimePTY()),
            now: { sleeper.elapsedSeconds }
        )
        let transport = RuntimePTYTransport(session: session, sessionID: "session-stop-retry", sleeper: sleeper)
        defer { transport.stop() }

        transport.start(onBytes: { _ in }, onClosed: {})

        let reconnecting = await waitUntil(timeout: 1) {
            transport.connectionState == .reconnecting
        }
        XCTAssertTrue(reconnecting)
        XCTAssertEqual(session.attachCount, 1)
        await sleeper.waitForSleepCallCount(1)

        transport.stop()

        let disconnected = await waitUntil(timeout: 1) {
            transport.connectionState == .disconnected
        }
        XCTAssertTrue(disconnected)
        sleeper.advance(bySeconds: 2)
        await Task.yield()
        XCTAssertEqual(session.attachCount, 1)
    }

    func test_unexpectedCloseAfterSuccessfulAttach_entersReconnecting() async {
        let sleeper = ManualSleeper()
        let session = FakeRuntimeSession(
            results: [.success(FakeRuntimePTY())],
            now: { sleeper.elapsedSeconds }
        )
        let transport = RuntimePTYTransport(session: session, sessionID: "session-close", sleeper: sleeper)
        defer { transport.stop() }

        transport.start(onBytes: { _ in }, onClosed: {})

        let connected = await waitUntil(timeout: 1) {
            transport.connectionState == .connected
        }
        XCTAssertTrue(connected)

        session.emit(.ptyClosed(nil))

        let reconnecting = await waitUntil(timeout: 1) {
            transport.connectionState == .reconnecting
        }
        XCTAssertTrue(reconnecting)
    }

    func test_ptyDataForDifferentHandleIsIgnored() async {
        let sleeper = ManualSleeper()
        let session = FakeRuntimeSession(
            results: [.success(FakeRuntimePTY(handle: 11))],
            now: { sleeper.elapsedSeconds }
        )
        let transport = RuntimePTYTransport(session: session, sessionID: "session-data-handle", sleeper: sleeper)
        var received = Data()
        defer { transport.stop() }

        transport.start(onBytes: { received.append($0) }, onClosed: {})

        let connected = await waitUntil(timeout: 1) {
            transport.connectionState == .connected
        }
        XCTAssertTrue(connected)

        session.emit(.ptyData(#"{"handle":22,"bytes":"other"}"#))
        session.emit(.ptyData(#"{"handle":11,"bytes":"owned"}"#))

        let delivered = await waitUntil(timeout: 1) {
            String(data: received, encoding: .utf8) == "owned"
        }
        XCTAssertTrue(delivered)
        XCTAssertEqual(String(data: received, encoding: .utf8), "owned")
    }

    func test_ptyClosedForDifferentHandleDoesNotReconnect() async {
        let sleeper = ManualSleeper()
        let session = FakeRuntimeSession(
            results: [.success(FakeRuntimePTY(handle: 11))],
            now: { sleeper.elapsedSeconds }
        )
        let transport = RuntimePTYTransport(session: session, sessionID: "session-close-handle", sleeper: sleeper)
        defer { transport.stop() }

        transport.start(onBytes: { _ in }, onClosed: {})

        let connected = await waitUntil(timeout: 1) {
            transport.connectionState == .connected
        }
        XCTAssertTrue(connected)

        session.emit(.ptyClosed(#"{"handle":22}"#))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.connectionState, .connected)
        XCTAssertEqual(session.attachCount, 1)

        session.emit(.ptyClosed(#"{"handle":11}"#))

        let reconnecting = await waitUntil(timeout: 1) {
            transport.connectionState == .reconnecting
        }
        XCTAssertTrue(reconnecting)
    }

    private func exhaustRetryBudget(sleeper: ManualSleeper) async {
        for (index, seconds) in [1, 2, 4, 8, 16].enumerated() {
            await sleeper.waitForSleepCallCount(index + 1)
            sleeper.advance(bySeconds: seconds)
        }
    }
}

/// Manually-driven `RuntimePTYSleeper` used by `RuntimePTYTransportTests`.
///
/// Each `sleep(seconds:)` call parks a continuation until the test calls
/// `advance(bySeconds:)` to push the virtual clock past the requested
/// deadline. This keeps backoff/retry assertions wall-clock-free.
private final class ManualSleeper: RuntimePTYSleeper, @unchecked Sendable {
    private struct Sleeper {
        let deadlineSeconds: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentSeconds = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepCallCount = 0
    private var sleepCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var requestedSleepSeconds: [Int] = []

    var elapsedSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return TimeInterval(currentSeconds)
    }

    func sleep(seconds: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediateResult: Result<Void, Error>?
                let readyWaiters: [CheckedContinuation<Void, Never>]
                let deadline: Int

                lock.lock()
                sleepCallCount += 1
                requestedSleepSeconds.append(seconds)
                deadline = currentSeconds + max(0, seconds)
                readyWaiters = removeReadySleepCountWaitersLocked()
                if Task.isCancelled {
                    immediateResult = .failure(CancellationError())
                } else if currentSeconds >= deadline {
                    immediateResult = .success(())
                } else {
                    sleepers[id] = Sleeper(deadlineSeconds: deadline, continuation: continuation)
                }
                lock.unlock()

                readyWaiters.forEach { $0.resume() }

                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            cancelSleep(id: id)
        }
    }

    func advance(bySeconds seconds: Int) {
        var readySleepers: [CheckedContinuation<Void, Error>] = []

        lock.lock()
        currentSeconds += max(0, seconds)
        for (id, sleeper) in sleepers where currentSeconds >= sleeper.deadlineSeconds {
            readySleepers.append(sleeper.continuation)
            sleepers.removeValue(forKey: id)
        }
        lock.unlock()

        readySleepers.forEach { $0.resume() }
    }

    func waitForSleepCallCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            var shouldResume = false

            lock.lock()
            if sleepCallCount >= count {
                shouldResume = true
            } else {
                sleepCountWaiters.append((count: count, continuation: continuation))
            }
            lock.unlock()

            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func cancelSleep(id: UUID) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        continuation = sleepers.removeValue(forKey: id)?.continuation
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func removeReadySleepCountWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        var ready: [CheckedContinuation<Void, Never>] = []
        sleepCountWaiters.removeAll { waiter in
            if sleepCallCount >= waiter.count {
                ready.append(waiter.continuation)
                return true
            }
            return false
        }
        return ready
    }
}

private enum FakeRuntimeError: Error {
    case attachFailed
}

private final class FakeRuntimePTY: RuntimePTYHandle {
    let handle: UInt64?
    private(set) var writes: [Data] = []
    private(set) var resizes: [(cols: UInt16, rows: UInt16)] = []
    private(set) var detachCount = 0

    init(handle: UInt64? = nil) {
        self.handle = handle
    }

    func write(_ bytes: Data) throws {
        writes.append(bytes)
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        resizes.append((cols, rows))
    }

    func detach() {
        detachCount += 1
    }
}

private final class FakeRuntimeSession: RuntimePTYSessionProviding {
    enum AttachResult {
        case success(FakeRuntimePTY)
        case failure(Error)
    }

    private var results: [AttachResult]
    private let defaultResult: AttachResult
    private let now: () -> TimeInterval
    private var listeners: [UUID: (RuntimeEvent) -> Void] = [:]
    private(set) var attachTimes: [TimeInterval] = []
    private(set) var removedListenerTokens: [UUID] = []

    init(
        results: [AttachResult] = [],
        defaultResult: AttachResult = .failure(FakeRuntimeError.attachFailed),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.results = results
        self.defaultResult = defaultResult
        self.now = now
    }

    var attachCount: Int {
        attachTimes.count
    }

    var attachIntervals: [TimeInterval] {
        zip(attachTimes.dropFirst(), attachTimes).map { later, earlier in
            later - earlier
        }
    }

    func enqueue(results newResults: [AttachResult]) {
        results.append(contentsOf: newResults)
    }

    @discardableResult
    func addEventListener(_ handler: @escaping (RuntimeEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        return token
    }

    func removeEventListener(_ token: UUID) {
        listeners.removeValue(forKey: token)
        removedListenerTokens.append(token)
    }

    func attachRuntimePTY(sessionID: String) throws -> any RuntimePTYHandle {
        _ = sessionID
        attachTimes.append(now())
        let result = results.isEmpty ? defaultResult : results.removeFirst()
        switch result {
        case .success(let pty):
            return pty
        case .failure(let error):
            throw error
        }
    }

    func emit(_ event: RuntimeEvent) {
        for listener in listeners.values {
            listener(event)
        }
    }
}
#endif
