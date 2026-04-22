import Foundation

// MARK: - File system seam

/// Minimal file-system surface used by `ExternalAgentSessionWatcher`.
///
/// The protocol is deliberately small so tests can drive the watcher with a
/// fully in-memory fake instead of real disk I/O.
protocol SessionWatcherFileSystem: Sendable {
    /// Returns `true` when `url` resolves to an existing directory.
    func directoryExists(_ url: URL) -> Bool
    /// Returns the leaf filenames inside `url`. When `url` does not exist or
    /// cannot be listed, returns an empty array.
    func filenames(in url: URL) -> [String]
    /// Returns the creation date for the file at `url`, or `nil` when the file
    /// does not exist or the attribute is unavailable.
    func fileCreationDate(_ url: URL) -> Date?
}

extension SessionWatcherFileSystem where Self == LiveSessionWatcherFileSystem {
    /// The default live implementation backed by `FileManager`.
    static var live: Self { LiveSessionWatcherFileSystem() }
}

/// Live `FileManager`-backed implementation of `SessionWatcherFileSystem`.
struct LiveSessionWatcherFileSystem: SessionWatcherFileSystem {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    func filenames(in url: URL) -> [String] {
        guard directoryExists(url) else { return [] }
        let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        return contents
    }

    func fileCreationDate(_ url: URL) -> Date? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.creationDate] as? Date
    }
}

// MARK: - Clock seam

/// Minimal clock surface used by `ExternalAgentSessionWatcher`.
///
/// Separated from the file system so tests can advance time without actually
/// sleeping and without touching real wall-clock state.
protocol SessionWatcherClock: Sendable {
    /// Returns the current time.
    func now() -> Date
    /// Sleeps for the supplied duration, honoring task cancellation.
    func sleep(seconds: TimeInterval) async throws
}

extension SessionWatcherClock where Self == LiveSessionWatcherClock {
    /// The default live implementation backed by `Date()` and `Task.sleep`.
    static var live: Self { LiveSessionWatcherClock() }
}

/// Live implementation of `SessionWatcherClock` backed by `Date()` and
/// `Task.sleep(nanoseconds:)`.
struct LiveSessionWatcherClock: SessionWatcherClock {
    func now() -> Date { Date() }

    func sleep(seconds: TimeInterval) async throws {
        let clamped = max(seconds, 0)
        let nanos = UInt64(clamped * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

// MARK: - Snapshot helper

/// Helper to snapshot the set of session ids that exist for a given agent in a
/// working directory. The caller records this snapshot BEFORE spawning the CLI
/// so the watcher can ignore any pre-existing files and avoid false matches.
enum ExternalAgentSessionSnapshot {
    static func existingSessionIds(
        kind: ExternalAgentKind,
        workingDirectory: String,
        fileSystem: SessionWatcherFileSystem = .live
    ) -> Set<String> {
        guard let directory = kind.sessionDirectory(forWorkingDirectory: workingDirectory) else {
            return []
        }
        guard fileSystem.directoryExists(directory) else { return [] }
        var ids: Set<String> = []
        for filename in fileSystem.filenames(in: directory) {
            if let id = kind.sessionId(fromFilename: filename) {
                ids.insert(id)
            }
        }
        return ids
    }
}

// MARK: - Watcher

/// Watches the session directory of an external AI CLI (Claude Code, Codex)
/// for a newly-created session file that appears after `launchTime` within
/// `workingDirectory`. When detected, invokes `onDiscover` with the extracted
/// session id. Safe to cancel via `cancel()` (idempotent). Designed to be
/// kicked off from an actor-isolated context; callbacks are delivered on the
/// main actor.
///
/// Sensible defaults for `Configuration` are:
/// - `timeout`: 30 seconds
/// - `pollInterval`: 0.5 seconds
/// - `excludedSessionIds`: caller-provided snapshot taken before spawning the
///   CLI, so simultaneous tabs in the same cwd do not collide.
final class ExternalAgentSessionWatcher: @unchecked Sendable {
    struct Configuration {
        let kind: ExternalAgentKind
        let workingDirectory: String
        let launchTime: Date
        /// Session ids that existed BEFORE launch; ignore matches in this set
        /// to disambiguate when multiple tabs spawn in the same cwd.
        let excludedSessionIds: Set<String>
        /// Max time to keep polling before giving up. Default 30s.
        let timeout: TimeInterval
        /// Poll interval. Default 0.5s.
        let pollInterval: TimeInterval

        init(
            kind: ExternalAgentKind,
            workingDirectory: String,
            launchTime: Date,
            excludedSessionIds: Set<String> = [],
            timeout: TimeInterval = 30,
            pollInterval: TimeInterval = 0.5
        ) {
            self.kind = kind
            self.workingDirectory = workingDirectory
            self.launchTime = launchTime
            self.excludedSessionIds = excludedSessionIds
            self.timeout = timeout
            self.pollInterval = pollInterval
        }
    }

    /// Tolerance applied to `launchTime` when filtering candidates by
    /// creation date. Some filesystems round creation timestamps to the
    /// nearest second, so a small negative tolerance avoids discarding a
    /// file that was actually created by our spawned process.
    static let creationDateTolerance: TimeInterval = 2.0

    private let configuration: Configuration
    private let fileSystem: SessionWatcherFileSystem
    private let clock: SessionWatcherClock
    private let onDiscover: @MainActor (String) -> Void
    private let onTimeout: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var cancelled: Bool = false
    private var task: Task<Void, Never>?

    init(
        configuration: Configuration,
        fileSystem: SessionWatcherFileSystem = .live,
        clock: SessionWatcherClock = .live,
        onDiscover: @MainActor @escaping (String) -> Void,
        onTimeout: (@MainActor () -> Void)? = nil
    ) {
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.clock = clock
        self.onDiscover = onDiscover
        self.onTimeout = onTimeout
    }

    /// Returns `true` when the watcher has a live underlying task and has not
    /// been cancelled.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil && !cancelled
    }

    /// Starts the watch loop. Idempotent: a second call while already running
    /// or after cancellation is a no-op.
    func start() {
        lock.lock()
        if cancelled || task != nil {
            lock.unlock()
            return
        }
        let configuration = self.configuration
        let fileSystem = self.fileSystem
        let clock = self.clock
        let onDiscover = self.onDiscover
        let onTimeout = self.onTimeout

        let newTask = Task { [weak self] in
            await Self.runLoop(
                configuration: configuration,
                fileSystem: fileSystem,
                clock: clock,
                onDiscover: onDiscover,
                onTimeout: onTimeout,
                isCancelled: { self?.isCancelledFlag() ?? true }
            )
        }
        self.task = newTask
        lock.unlock()
    }

    /// Cancels the watcher. Safe to call multiple times and safe to call
    /// before `start()`; after cancellation any pending callbacks are
    /// suppressed.
    func cancel() {
        lock.lock()
        cancelled = true
        let existing = task
        task = nil
        lock.unlock()
        existing?.cancel()
    }

    private func isCancelledFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private static func runLoop(
        configuration: Configuration,
        fileSystem: SessionWatcherFileSystem,
        clock: SessionWatcherClock,
        onDiscover: @MainActor @escaping (String) -> Void,
        onTimeout: (@MainActor () -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) async {
        // CLIs without a session directory (gemini, kimi) time out immediately.
        guard let directory = configuration.kind.sessionDirectory(
            forWorkingDirectory: configuration.workingDirectory
        ) else {
            if !isCancelled() {
                await fire(onTimeout)
            }
            return
        }

        let deadline = configuration.launchTime.addingTimeInterval(configuration.timeout)
        let tolerance = Self.creationDateTolerance
        let minAcceptableCreation = configuration.launchTime.addingTimeInterval(-tolerance)

        while true {
            if isCancelled() { return }

            if clock.now() >= deadline {
                if !isCancelled() {
                    await fire(onTimeout)
                }
                return
            }

            if fileSystem.directoryExists(directory) {
                let filenames = fileSystem.filenames(in: directory)
                var best: (id: String, created: Date)?
                for filename in filenames {
                    guard let id = configuration.kind.sessionId(fromFilename: filename) else {
                        continue
                    }
                    if configuration.excludedSessionIds.contains(id) { continue }
                    let fileURL = directory.appendingPathComponent(filename)
                    guard let created = fileSystem.fileCreationDate(fileURL) else { continue }
                    if created < minAcceptableCreation { continue }
                    if let current = best {
                        if created > current.created {
                            best = (id, created)
                        }
                    } else {
                        best = (id, created)
                    }
                }

                if let match = best {
                    if isCancelled() { return }
                    await fireDiscover(onDiscover, id: match.id)
                    return
                }
            }

            do {
                try await clock.sleep(seconds: configuration.pollInterval)
            } catch {
                return
            }
        }
    }

    private static func fireDiscover(
        _ handler: @MainActor @escaping (String) -> Void,
        id: String
    ) async {
        await MainActor.run { handler(id) }
    }

    private static func fire(_ handler: (@MainActor () -> Void)?) async {
        guard let handler else { return }
        await MainActor.run { handler() }
    }
}
