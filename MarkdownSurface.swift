import Combine
import Foundation
#if os(macOS)
import Darwin
#endif

enum MarkdownFileWatcherState: Equatable, Hashable {
    case stopped
    case watchingFile
    case retrying(attempt: Int)
    case watchingDirectory
}

enum MarkdownFileWatcherEvent: Equatable, Hashable {
    case fileChanged
    case fileTemporarilyUnavailable
    case fileReattached
    case fileUnavailable
}

struct MarkdownFileWatcherRetryPolicy {
    var maxAttempts: Int
    var interval: DispatchTimeInterval
    var pollInterval: DispatchTimeInterval

    static let `default` = MarkdownFileWatcherRetryPolicy(
        maxAttempts: 6,
        interval: .milliseconds(500),
        pollInterval: .milliseconds(1000)
    )
}

final class MarkdownFileWatcher {
    private let path: String
    private let fileManager: FileManager
    private let retryPolicy: MarkdownFileWatcherRetryPolicy
    private let onEvent: (MarkdownFileWatcherEvent) -> Void
    private let onStateChange: (MarkdownFileWatcherState) -> Void
    private let queue = DispatchQueue(label: "com.smithers.gui.markdown-file-watch")
    private let queueKey = DispatchSpecificKey<Bool>()

    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var retryGeneration = 0
    private var stopped = false

    init(
        path: String,
        fileManager: FileManager = .default,
        retryPolicy: MarkdownFileWatcherRetryPolicy = .default,
        onEvent: @escaping (MarkdownFileWatcherEvent) -> Void,
        onStateChange: @escaping (MarkdownFileWatcherState) -> Void = { _ in }
    ) {
        self.path = (path as NSString).standardizingPath
        self.fileManager = fileManager
        self.retryPolicy = retryPolicy
        self.onEvent = onEvent
        self.onStateChange = onStateChange
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.retryGeneration += 1
            self.startLocked()
        }
    }

    func stop() {
        let stopWork = {
            self.stopped = true
            self.retryGeneration += 1
            self.stopSourceLocked()
            self.stopPollTimerLocked()
            self.onStateChange(.stopped)
        }

        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopWork()
        } else {
            queue.sync(execute: stopWork)
        }
    }

    private func startLocked() {
        guard !stopped else { return }
        if fileManager.fileExists(atPath: path) {
            startFileWatcherLocked()
        } else {
            startMissingFileWatcherLocked(notifyUnavailable: true)
        }
    }

    private func startFileWatcherLocked() {
        guard !stopped else { return }
        retryGeneration += 1
        stopSourceLocked()
        stopPollTimerLocked()

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            startMissingFileWatcherLocked(notifyUnavailable: true)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []

            if flags.contains(.delete) || flags.contains(.rename) {
                self.onEvent(.fileTemporarilyUnavailable)
                self.stopSourceLocked()
                self.scheduleRetryLocked(attempt: 1, generation: self.retryGeneration + 1)
                return
            }

            if flags.contains(.write) || flags.contains(.extend) {
                self.onEvent(.fileChanged)
            }
        }
        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        onStateChange(.watchingFile)
        source.resume()
    }

    private func scheduleRetryLocked(attempt: Int, generation: Int) {
        guard !stopped else { return }
        retryGeneration = generation
        onStateChange(.retrying(attempt: attempt))

        queue.asyncAfter(deadline: .now() + retryPolicy.interval) { [weak self] in
            guard let self,
                  !self.stopped,
                  self.retryGeneration == generation
            else {
                return
            }

            if self.fileManager.fileExists(atPath: self.path) {
                self.startFileWatcherLocked()
                self.onEvent(.fileReattached)
                return
            }

            if attempt < self.retryPolicy.maxAttempts {
                self.scheduleRetryLocked(attempt: attempt + 1, generation: generation)
            } else {
                self.startMissingFileWatcherLocked(notifyUnavailable: true)
            }
        }
    }

    private func startMissingFileWatcherLocked(notifyUnavailable: Bool) {
        guard !stopped else { return }
        retryGeneration += 1
        stopSourceLocked()
        startDirectoryWatcherLocked()
        startPollTimerLocked()
        onStateChange(.watchingDirectory)
        if notifyUnavailable {
            onEvent(.fileUnavailable)
        }
    }

    private func startDirectoryWatcherLocked() {
        let directoryPath = (path as NSString).deletingLastPathComponent
        guard !directoryPath.isEmpty,
              fileManager.fileExists(atPath: directoryPath)
        else {
            return
        }

        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.fileManager.fileExists(atPath: self.path) {
                self.startFileWatcherLocked()
                self.onEvent(.fileReattached)
            }
        }
        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        source.resume()
    }

    private func startPollTimerLocked() {
        stopPollTimerLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + retryPolicy.pollInterval,
            repeating: retryPolicy.pollInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self,
                  !self.stopped,
                  self.fileManager.fileExists(atPath: self.path)
            else {
                return
            }
            self.startFileWatcherLocked()
            self.onEvent(.fileReattached)
        }
        pollTimer = timer
        timer.resume()
    }

    private func stopSourceLocked() {
        source?.cancel()
        source = nil
    }

    private func stopPollTimerLocked() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}

enum MarkdownSurfaceAvailability: Equatable, Hashable {
    case loading
    case available
    case retrying
    case unavailable(String)
}

@MainActor
final class MarkdownSurfaceModel: ObservableObject {
    let surfaceId: String
    let filePath: String

    @Published private(set) var content: String = ""
    @Published private(set) var availability: MarkdownSurfaceAvailability = .loading
    @Published private(set) var watcherState: MarkdownFileWatcherState = .stopped
    @Published private(set) var lastLoadedAt: Date?

    private let fileManager: FileManager
    private let retryPolicy: MarkdownFileWatcherRetryPolicy
    private var watcher: MarkdownFileWatcher?

    init(
        surfaceId: String,
        filePath: String,
        fileManager: FileManager = .default,
        retryPolicy: MarkdownFileWatcherRetryPolicy = .default,
        startWatching: Bool = true
    ) {
        self.surfaceId = surfaceId
        self.filePath = (filePath as NSString).standardizingPath
        self.fileManager = fileManager
        self.retryPolicy = retryPolicy

        reloadContent(markUnavailableWhenMissing: true)
        if startWatching {
            start()
        }
    }

    deinit {
        watcher?.stop()
    }

    var displayPath: String {
        (filePath as NSString).abbreviatingWithTildeInPath
    }

    var isUnavailable: Bool {
        if case .unavailable = availability {
            return true
        }
        return false
    }

    func start() {
        watcher?.stop()
        watcher = MarkdownFileWatcher(
            path: filePath,
            fileManager: fileManager,
            retryPolicy: retryPolicy,
            onEvent: { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleWatcherEvent(event)
                }
            },
            onStateChange: { [weak self] state in
                DispatchQueue.main.async {
                    self?.watcherState = state
                }
            }
        )
        watcher?.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        watcherState = .stopped
    }

    func reload() {
        reloadContent(markUnavailableWhenMissing: true)
    }

    private func handleWatcherEvent(_ event: MarkdownFileWatcherEvent) {
        switch event {
        case .fileChanged, .fileReattached:
            reloadContent(markUnavailableWhenMissing: true)
        case .fileTemporarilyUnavailable:
            availability = .retrying
            reloadContent(markUnavailableWhenMissing: false)
        case .fileUnavailable:
            reloadContent(markUnavailableWhenMissing: true)
        }
    }

    private func reloadContent(markUnavailableWhenMissing: Bool) {
        guard fileManager.fileExists(atPath: filePath) else {
            if markUnavailableWhenMissing {
                content = ""
                availability = .unavailable("File unavailable")
            } else if availability != .available {
                availability = .retrying
            }
            return
        }

        do {
            content = try String(contentsOfFile: filePath, encoding: .utf8)
            availability = .available
            lastLoadedAt = Date()
        } catch {
            availability = .unavailable(error.localizedDescription)
        }
    }
}

@MainActor
final class MarkdownSurfaceRegistry {
    static let shared = MarkdownSurfaceRegistry()

    private var models: [String: MarkdownSurfaceModel] = [:]

    private init() {}

    func model(for surfaceId: String, filePath: String) -> MarkdownSurfaceModel {
        let normalizedPath = (filePath as NSString).standardizingPath
        if let existing = models[surfaceId], existing.filePath == normalizedPath {
            return existing
        }

        remove(surfaceId: surfaceId)
        let model = MarkdownSurfaceModel(surfaceId: surfaceId, filePath: normalizedPath)
        models[surfaceId] = model
        return model
    }

    func remove(surfaceId: String) {
        models.removeValue(forKey: surfaceId)?.stop()
        MarkdownWebViewRegistry.shared.remove(surfaceId: surfaceId)
    }

    func contains(surfaceId: String) -> Bool {
        models[surfaceId] != nil
    }
}
