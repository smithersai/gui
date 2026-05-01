import Foundation
import os

// MARK: - Log Level

enum LogLevel: String, Codable, CaseIterable, Comparable {
    case debug, info, warning, error

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warning, .error]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

// MARK: - Log Category

enum LogCategory: String, Codable, CaseIterable {
    case network
    case ui
    case lifecycle
    case performance
    case error
    case agent
    case codex
    case terminal
    case state
}

// MARK: - Log Entry

struct LogEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let metadata: [String: String]?

    init(level: LogLevel, category: LogCategory, message: String, metadata: [String: String]? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
        self.metadata = LogMetadataFormatter.sanitized(metadata)
    }

    var formattedMetadata: String? {
        LogMetadataFormatter.formatted(metadata)
    }

    var renderedMessage: String {
        guard let formattedMetadata else { return message }
        return "\(message) \(formattedMetadata)"
    }
}

private enum LogMetadataFormatter {
    private static let redactedValue = "[redacted]"
    private static let maxValueLength = 500
    private static let exactSensitiveKeys = [
        "api-key",
        "apikey",
        "authorization",
        "bearer",
        "cookie",
        "password",
        "private-key",
        "secret",
        "token",
    ]
    private static let sensitiveKeyFragments = [
        "authorization",
        "api-key",
        "apikey",
        "access-token",
        "auth-token",
        "bearer",
        "cookie",
        "password",
        "private-key",
        "secret",
        "session-token",
    ]

    static func sanitized(_ metadata: [String: String]?) -> [String: String]? {
        guard let metadata, !metadata.isEmpty else { return nil }
        let cleaned = metadata.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = sanitizedValue(pair.value, forKey: key)
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    static func formatted(_ metadata: [String: String]?) -> String? {
        guard let metadata, !metadata.isEmpty else { return nil }
        return metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    private static func sanitizedValue(_ value: String, forKey key: String) -> String {
        guard !isSensitiveKey(key) else { return redactedValue }

        let normalized = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        guard normalized.count > maxValueLength else { return normalized }
        return "\(String(normalized.prefix(maxValueLength)))...(truncated)"
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        return exactSensitiveKeys.contains(normalized) ||
            normalized.hasSuffix("-token") ||
            sensitiveKeyFragments.contains { normalized.contains($0) }
    }
}

struct LogFileStats {
    let fileURL: URL
    let sizeBytes: Int
    let entryCount: Int
    let droppedWriteCount: Int
    let lastWriteError: String?
}

// MARK: - Category Logger

struct CategoryLogger {
    let category: LogCategory
    fileprivate let osLogger: os.Logger
    private static let signposter = OSSignposter(subsystem: "com.smithers.gui", category: "performance")

    func debug(_ message: String, metadata: [String: String]? = nil) {
        log(.debug, message, metadata: metadata)
    }

    func info(_ message: String, metadata: [String: String]? = nil) {
        log(.info, message, metadata: metadata)
    }

    func warning(_ message: String, metadata: [String: String]? = nil) {
        log(.warning, message, metadata: metadata)
    }

    func error(_ message: String, metadata: [String: String]? = nil) {
        log(.error, message, metadata: metadata)
    }

    /// Begin a signpost interval. Call `end()` on the returned state to close it.
    func beginInterval(_ name: StaticString) -> OSSignpostIntervalState {
        Self.signposter.beginInterval(name)
    }

    func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
        Self.signposter.endInterval(name, state)
    }

    private func log(_ level: LogLevel, _ message: String, metadata: [String: String]?) {
        let entry = LogEntry(level: level, category: category, message: message, metadata: metadata)
        osLogger.log(level: level.osLogType, "\(entry.renderedMessage, privacy: .public)")
        Task.detached { await AppLogger.fileWriter.write(entry) }
    }
}

// MARK: - App Logger (Static Facade)

enum AppLogger {
    private static let subsystem = "com.smithers.gui"

    static let network = CategoryLogger(
        category: .network,
        osLogger: os.Logger(subsystem: subsystem, category: "network")
    )
    static let ui = CategoryLogger(
        category: .ui,
        osLogger: os.Logger(subsystem: subsystem, category: "ui")
    )
    static let lifecycle = CategoryLogger(
        category: .lifecycle,
        osLogger: os.Logger(subsystem: subsystem, category: "lifecycle")
    )
    static let performance = CategoryLogger(
        category: .performance,
        osLogger: os.Logger(subsystem: subsystem, category: "performance")
    )
    static let error = CategoryLogger(
        category: .error,
        osLogger: os.Logger(subsystem: subsystem, category: "error")
    )
    static let agent = CategoryLogger(
        category: .agent,
        osLogger: os.Logger(subsystem: subsystem, category: "agent")
    )
    static let codex = CategoryLogger(
        category: .codex,
        osLogger: os.Logger(subsystem: subsystem, category: "codex")
    )
    static let terminal = CategoryLogger(
        category: .terminal,
        osLogger: os.Logger(subsystem: subsystem, category: "terminal")
    )
    static let state = CategoryLogger(
        category: .state,
        osLogger: os.Logger(subsystem: subsystem, category: "state")
    )

    /// Measure async work duration and log it.
    static func measure<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let signpostState = performance.beginInterval("measure")
        do {
            let result = try await work()
            performance.endInterval("measure", signpostState)
            performance.info("\(label) completed", metadata: durationMetadata(since: start))
            return result
        } catch {
            performance.endInterval("measure", signpostState)
            var metadata = durationMetadata(since: start)
            metadata["error"] = error.localizedDescription
            performance.error("\(label) failed", metadata: metadata)
            throw error
        }
    }

    static let fileWriter = FileLogWriter()

    private static func durationMetadata(since start: CFAbsoluteTime) -> [String: String] {
        ["duration_ms": String(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))]
    }
}

// MARK: - File Log Writer (Actor)

actor FileLogWriter {
    private let logDir: URL
    private let logFile: URL
    private let maxSize = 5_000_000 // 5MB
    private let maxAge: TimeInterval = 7 * 24 * 3600 // 7 days
    private var writeCount = 0
    private let encoder: JSONEncoder
    private var fileHandle: FileHandle?
    private var droppedWriteCount = 0
    private var lastWriteError: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logDir = home.appendingPathComponent("Library/Logs/SmithersGUI")
        logFile = logDir.appendingPathComponent("app.log")

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? fileHandle?.close()
    }

    func write(_ entry: LogEntry) {
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else {
            recordDroppedWrite("failed to encode log entry")
            return
        }
        line += "\n"

        guard let lineData = line.data(using: .utf8) else {
            recordDroppedWrite("failed to encode log line as utf8")
            return
        }

        if fileHandle == nil {
            fileHandle = try? FileHandle(forWritingTo: logFile)
            fileHandle?.seekToEndOfFile()
        }
        guard let fileHandle else {
            recordDroppedWrite("failed to open log file")
            return
        }

        do {
            try fileHandle.write(contentsOf: lineData)
            lastWriteError = nil
        } catch {
            recordDroppedWrite(error.localizedDescription)
            self.fileHandle = nil
            return
        }

        writeCount += 1
        if writeCount % 200 == 0 {
            // Flush periodically
            try? fileHandle.synchronize()
            pruneIfNeeded()
        }
    }

    func readEntries(limit: Int = 1000) -> [LogEntry] {
        // Flush before reading so we get latest
        try? fileHandle?.synchronize()

        guard let data = try? Data(contentsOf: logFile),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let startIndex = max(0, lines.count - limit)
        let recentLines = lines[startIndex...]

        return recentLines.compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(LogEntry.self, from: lineData)
        }
    }

    func entryCount() -> Int {
        try? fileHandle?.synchronize()
        guard let data = try? Data(contentsOf: logFile),
              let content = String(data: data, encoding: .utf8) else { return 0 }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    func logFileSize() -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }

    func stats() -> LogFileStats {
        try? fileHandle?.synchronize()
        return LogFileStats(
            fileURL: logFile,
            sizeBytes: logFileSize(),
            entryCount: entryCount(),
            droppedWriteCount: droppedWriteCount,
            lastWriteError: lastWriteError
        )
    }

    func clearLog() {
        try? fileHandle?.close()
        fileHandle = nil
        do {
            try Data().write(to: logFile, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
        }
        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()
    }

    func exportLog() -> URL? {
        try? fileHandle?.synchronize()
        guard FileManager.default.fileExists(atPath: logFile.path) else { return nil }
        return logFile
    }

    private func recordDroppedWrite(_ reason: String) {
        droppedWriteCount += 1
        lastWriteError = reason
    }

    private func pruneIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? Int,
              size > maxSize else { return }

        try? fileHandle?.close()
        fileHandle = nil

        guard let data = try? Data(contentsOf: logFile),
              let content = String(data: data, encoding: .utf8) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-maxAge)

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Keep lines that are either recent by age, or in the latter half (size-based fallback)
        let keepFrom = lines.count / 2
        let kept = lines.enumerated().compactMap { (idx, line) -> String? in
            // Always keep the latter half
            if idx >= keepFrom { return line }
            // From the first half, keep entries newer than maxAge
            if let lineData = line.data(using: .utf8),
               let entry = try? decoder.decode(LogEntry.self, from: lineData),
               entry.timestamp > cutoff {
                return line
            }
            return nil
        }

        // After age filtering, also enforce a max line count to stay under maxSize.
        // Estimate ~200 bytes per line on average; keep at most maxSize/200 lines from the tail.
        let maxLines = maxSize / 200
        let tailKept = kept.count > maxLines ? Array(kept.suffix(maxLines)) : kept

        let keptContent = tailKept.joined(separator: "\n") + "\n"
        try? keptContent.write(to: logFile, atomically: true, encoding: .utf8)

        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()
    }
}
