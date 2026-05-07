import XCTest
@testable import SmithersGUI

// MARK: - Fakes

/// In-memory fake file system. Not thread-safe by design: tests mutate it from
/// the main actor between polls, protected by an internal lock so the watcher
/// task can safely read concurrently.
final class FakeFileSystem: SessionWatcherFileSystem, @unchecked Sendable {
    struct Entry {
        var created: Date
    }

    private let lock = NSLock()
    private var directories: Set<String> = []
    private var files: [String: Entry] = [:]

    func addDirectory(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        directories.insert(url.path)
    }

    func removeDirectory(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        directories.remove(url.path)
    }

    func addFile(_ url: URL, created: Date) {
        lock.lock(); defer { lock.unlock() }
        directories.insert(url.deletingLastPathComponent().path)
        files[url.path] = Entry(created: created)
    }

    func removeFile(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: url.path)
    }

    func directoryExists(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return directories.contains(url.path)
    }

    func filenames(in url: URL) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard directories.contains(url.path) else { return [] }
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var out: [String] = []
        for key in files.keys where key.hasPrefix(prefix) {
            let rest = String(key.dropFirst(prefix.count))
            if !rest.contains("/") { out.append(rest) }
        }
        return out
    }

    func fileCreationDate(_ url: URL) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return files[url.path]?.created
    }
}

/// Deterministic clock. `advance(by:)` moves time forward and wakes any sleeper
/// whose deadline has elapsed. `sleep` honors `Task.isCancelled`.
final class FakeClock: SessionWatcherClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var waiters: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = waiters.filter { $0.deadline <= current }
        waiters.removeAll { $0.deadline <= current }
        lock.unlock()
        for w in due { w.continuation.resume(returning: ()) }
    }

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let deadline: Date = {
            lock.lock(); defer { lock.unlock() }
            return current.addingTimeInterval(seconds)
        }()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if current >= deadline {
                    lock.unlock()
                    cont.resume(returning: ())
                    return
                }
                waiters.append((deadline, cont))
                lock.unlock()
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cancelled = self.waiters
            self.waiters.removeAll()
            self.lock.unlock()
            for w in cancelled {
                w.continuation.resume(throwing: CancellationError())
            }
        }
    }
}

// MARK: - Test helpers

@MainActor
final class CallbackRecorder {
    var discovered: [String] = []
    var timeouts: Int = 0
}

private func uuid(_ s: String) -> String { s }

// Known-good UUIDs we reuse across tests.
private let uuidA = "11111111-1111-4111-8111-111111111111"
private let uuidB = "22222222-2222-4222-8222-222222222222"
private let uuidC = "33333333-3333-4333-8333-333333333333"
private let uuidD = "44444444-4444-4444-8444-444444444444"

@MainActor
final class ExternalAgentSessionWatcherTests: XCTestCase {

    // MARK: Fixtures

    /// Working directory used by all tests. The exact path doesn't matter as
    /// long as `ExternalAgentKind.sessionDirectory` deterministically produces
    /// a URL we can also build ourselves for the fake FS.
    private let cwd = "/tmp/fake-proj"

    private func claudeDirectory() -> URL {
        // Stream 2 owns the mapping; we defer to it so tests match production.
        let url = ExternalAgentKind.claude.sessionDirectory(forWorkingDirectory: cwd)
        return url ?? URL(fileURLWithPath: "/tmp/fake-claude-session-dir")
    }

    private func codexDirectory() -> URL {
        let url = ExternalAgentKind.codex.sessionDirectory(forWorkingDirectory: cwd)
        return url ?? URL(fileURLWithPath: "/tmp/fake-codex-session-dir")
    }

    private func makeConfig(
        kind: ExternalAgentKind = .claude,
        launchTime: Date,
        excluded: Set<String> = [],
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.1
    ) -> ExternalAgentSessionWatcher.Configuration {
        ExternalAgentSessionWatcher.Configuration(
            kind: kind,
            workingDirectory: cwd,
            launchTime: launchTime,
            excludedSessionIds: excluded,
            timeout: timeout,
            pollInterval: pollInterval
        )
    }

    /// Drive the fake clock forward in small ticks until `until()` returns
    /// `true` or we exceed `maxTicks`. Yields in between so the watcher task
    /// observes each step.
    private func tick(
        _ clock: FakeClock,
        by seconds: TimeInterval = 0.1,
        maxTicks: Int = 200,
        until: () -> Bool
    ) async {
        for _ in 0..<maxTicks {
            if until() { return }
            clock.advance(by: seconds)
            await Task.yield()
            await Task.yield()
        }
    }

    private func claudeFilename(_ id: String) -> String { "\(id).jsonl" }
    private func codexFilename(_ id: String, ts: String = "2026-04-21T12-00-00") -> String {
        "rollout-\(ts)-\(id).jsonl"
    }

    // MARK: Tests

    func testDirectoryMissingThenAppearsDiscoversId() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 30),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        // Let the watcher observe a missing directory first - a few poll
        // cycles, not enough to trip the timeout.
        await tick(clock, by: 0.1, maxTicks: 5, until: { false })
        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 0)

        // Now create the directory and drop a file dated after launch.
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(0.5))

        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidA])
        XCTAssertEqual(rec.timeouts, 0)
        watcher.cancel()
    }

    func testDirectoryMissingForeverTriggersTimeout() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 2, pollInterval: 0.1),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        await tick(clock, by: 0.5, until: { rec.timeouts > 0 })
        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 1)
        watcher.cancel()
    }

    func testSingleMatchingFileDiscoversAndStops() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(0.1))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidA])

        // Add a second file; the watcher must have stopped already.
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidB)),
                   created: launch.addingTimeInterval(0.2))
        await tick(clock, by: 0.2, maxTicks: 20, until: { false })
        XCTAssertEqual(rec.discovered, [uuidA])
        watcher.cancel()
    }

    func testMultipleNewFilesPicksNewestByCreationDate() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(0.1))
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidB)),
                   created: launch.addingTimeInterval(0.9))
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidC)),
                   created: launch.addingTimeInterval(0.4))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidB])
        watcher.cancel()
    }

    func testFileInExcludedSetIsIgnoredEvenIfNewest() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        // uuidA is newest but excluded; uuidB should win.
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(5))
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidB)),
                   created: launch.addingTimeInterval(1))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, excluded: [uuidA]),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidB])
        watcher.cancel()
    }

    func testFileOlderThanLaunchTimeIsIgnored() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        // Created well before launch - should be ignored (outside tolerance).
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(-60))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 1),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        await tick(clock, by: 0.3, until: { rec.timeouts > 0 })
        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 1)
        watcher.cancel()
    }

    func testFileWithInvalidUUIDPatternIsIgnored() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        // Non-UUID filename - ExternalAgentKind.sessionId should return nil.
        fs.addFile(dir.appendingPathComponent("notes.txt"),
                   created: launch.addingTimeInterval(0.1))
        fs.addFile(dir.appendingPathComponent("garbage.jsonl"),
                   created: launch.addingTimeInterval(0.2))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 1),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        await tick(clock, by: 0.3, until: { rec.timeouts > 0 })
        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 1)
        watcher.cancel()
    }

    func testMultipleCandidatesOneExcludedPicksCorrectOne() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(0.3))
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidB)),
                   created: launch.addingTimeInterval(0.5))
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidC)),
                   created: launch.addingTimeInterval(0.7))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, excluded: [uuidC]),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidB])
        watcher.cancel()
    }

    func testCancelBeforeStartIsNoOp() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: clock.now()),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.cancel()
        watcher.start() // should be no-op after cancel
        XCTAssertFalse(watcher.isRunning)

        await tick(clock, by: 1, maxTicks: 5, until: { false })
        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 0)
    }

    func testCancelMidPollStopsWithoutInvokingCallbacks() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 10),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        await tick(clock, by: 0.1, maxTicks: 10, until: { false })
        watcher.cancel()

        // Drop a matching file post-cancel; nothing should fire.
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(0.5))
        await tick(clock, by: 0.5, maxTicks: 20, until: { false })

        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 0)
    }

    func testStartCalledTwiceIsNoOp() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(0.1))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        watcher.start() // second call must be ignored

        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidA])
        watcher.cancel()
    }

    func testKindWithoutSessionDirectoryTimesOutImmediately() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()

        // gemini/kimi have no session directory per Stream 2 contract.
        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(kind: .gemini, launchTime: launch, timeout: 60),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        await tick(clock, by: 0.1, maxTicks: 50, until: { rec.timeouts > 0 })
        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 1)
        watcher.cancel()
    }

    func testKimiKindHasNoSessionDirectoryAndTimesOut() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(kind: .kimi, launchTime: launch, timeout: 60),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        await tick(clock, by: 0.1, maxTicks: 50, until: { rec.timeouts > 0 })
        XCTAssertEqual(rec.timeouts, 1)
        XCTAssertEqual(rec.discovered.count, 0)
        watcher.cancel()
    }

    func testCodexFilenamePatternExtractsId() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = codexDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(codexFilename(uuidA)),
                   created: launch.addingTimeInterval(0.1))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(kind: .codex, launchTime: launch),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidA])
        watcher.cancel()
    }

    func testClaudeFilenamePatternExtractsId() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidD)),
                   created: launch.addingTimeInterval(0.1))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(kind: .claude, launchTime: launch),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidD])
        watcher.cancel()
    }

    func testTimeoutAtExactBoundaryFires() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 1, pollInterval: 0.25),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()

        // Advance exactly to timeout boundary.
        await tick(clock, by: 0.25, until: { rec.timeouts > 0 })
        XCTAssertEqual(rec.timeouts, 1)
        XCTAssertEqual(rec.discovered.count, 0)
        watcher.cancel()
    }

    func testSnapshotEmptyDirReturnsEmptySet() {
        let fs = FakeFileSystem()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        let ids = ExternalAgentSessionSnapshot.existingSessionIds(
            kind: .claude,
            workingDirectory: cwd,
            fileSystem: fs
        )
        XCTAssertEqual(ids, [])
    }

    func testSnapshotIgnoresNonMatchingFiles() {
        let fs = FakeFileSystem()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        let now = Date()
        fs.addFile(dir.appendingPathComponent("README.md"), created: now)
        fs.addFile(dir.appendingPathComponent("not-a-uuid.jsonl"), created: now)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)), created: now)

        let ids = ExternalAgentSessionSnapshot.existingSessionIds(
            kind: .claude,
            workingDirectory: cwd,
            fileSystem: fs
        )
        XCTAssertEqual(ids, [uuidA])
    }

    func testSnapshotReturnsAllIdsPresent() {
        let fs = FakeFileSystem()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        let now = Date()
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)), created: now)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidB)), created: now)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidC)), created: now)

        let ids = ExternalAgentSessionSnapshot.existingSessionIds(
            kind: .claude,
            workingDirectory: cwd,
            fileSystem: fs
        )
        XCTAssertEqual(ids, [uuidA, uuidB, uuidC])
    }

    func testSnapshotWithMissingDirectoryReturnsEmpty() {
        let fs = FakeFileSystem()
        let ids = ExternalAgentSessionSnapshot.existingSessionIds(
            kind: .claude,
            workingDirectory: cwd,
            fileSystem: fs
        )
        XCTAssertEqual(ids, [])
    }

    func testSnapshotForKindWithoutSessionDirReturnsEmpty() {
        let fs = FakeFileSystem()
        let ids = ExternalAgentSessionSnapshot.existingSessionIds(
            kind: .gemini,
            workingDirectory: cwd,
            fileSystem: fs
        )
        XCTAssertEqual(ids, [])
    }

    func testFileAppearsAfterCancelCallbackNotFired() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 10),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        await tick(clock, by: 0.1, maxTicks: 5, until: { false })
        watcher.cancel()

        // File appears post-cancel.
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(0.5))
        await tick(clock, by: 0.5, maxTicks: 20, until: { false })

        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 0)
    }

    func testOnTimeoutOptionalNilDoesNotCrashOnTimeout() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 1),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: nil
        )
        watcher.start()
        await tick(clock, by: 0.3, maxTicks: 30, until: { false })
        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 0)
        watcher.cancel()
    }

    func testIsRunningFlagLifecycle() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let launch = clock.now()

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 10),
            fileSystem: fs,
            clock: clock,
            onDiscover: { _ in },
            onTimeout: nil
        )
        XCTAssertFalse(watcher.isRunning)
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.cancel()
        XCTAssertFalse(watcher.isRunning)
    }

    func testFileWithinCreationDateToleranceAccepted() async {
        // Files created slightly before launchTime (within 2s tolerance) should
        // still be accepted, since some FS round creation times to the second.
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(-1.0))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        await tick(clock, until: { rec.discovered.count > 0 })
        XCTAssertEqual(rec.discovered, [uuidA])
        watcher.cancel()
    }

    func testFileBeyondToleranceRejected() async {
        // 3s before launch is outside the 2s tolerance - should be rejected.
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let rec = CallbackRecorder()
        let launch = clock.now()
        let dir = claudeDirectory()
        fs.addDirectory(dir)
        fs.addFile(dir.appendingPathComponent(claudeFilename(uuidA)),
                   created: launch.addingTimeInterval(-3.0))

        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: launch, timeout: 1),
            fileSystem: fs,
            clock: clock,
            onDiscover: { rec.discovered.append($0) },
            onTimeout: { rec.timeouts += 1 }
        )
        watcher.start()
        await tick(clock, by: 0.3, until: { rec.timeouts > 0 })
        XCTAssertEqual(rec.discovered.count, 0)
        XCTAssertEqual(rec.timeouts, 1)
        watcher.cancel()
    }

    func testDoubleCancelIsIdempotent() async {
        let fs = FakeFileSystem()
        let clock = FakeClock()
        let watcher = ExternalAgentSessionWatcher(
            configuration: makeConfig(launchTime: clock.now()),
            fileSystem: fs,
            clock: clock,
            onDiscover: { _ in },
            onTimeout: nil
        )
        watcher.start()
        watcher.cancel()
        watcher.cancel() // must not crash
        XCTAssertFalse(watcher.isRunning)
    }
}
