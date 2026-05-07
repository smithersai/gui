import XCTest
@testable import SmithersGUI

// MARK: - LogLevel Tests

final class LogLevelTests: XCTestCase {

    func testLogLevelComparableOrdering() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
        XCTAssertFalse(LogLevel.error < LogLevel.debug)
    }

    func testLogLevelAllCasesCount() {
        XCTAssertEqual(LogLevel.allCases.count, 4)
    }

    func testLogLevelRawValues() {
        XCTAssertEqual(LogLevel.debug.rawValue, "debug")
        XCTAssertEqual(LogLevel.info.rawValue, "info")
        XCTAssertEqual(LogLevel.warning.rawValue, "warning")
        XCTAssertEqual(LogLevel.error.rawValue, "error")
    }

    func testLogLevelCodable() throws {
        let json = Data(#""warning""#.utf8)
        let decoded = try JSONDecoder().decode(LogLevel.self, from: json)
        XCTAssertEqual(decoded, .warning)

        let encoded = try JSONEncoder().encode(LogLevel.error)
        let str = String(data: encoded, encoding: .utf8)
        XCTAssertEqual(str, #""error""#)
    }

    func testLogLevelSorted() {
        let levels = LogLevel.allCases.sorted()
        XCTAssertEqual(levels, [.debug, .info, .warning, .error])
    }

    func testLogLevelEqualNotLessThan() {
        XCTAssertFalse(LogLevel.info < LogLevel.info)
    }
}

// MARK: - LogCategory Tests

final class LogCategoryTests: XCTestCase {

    func testLogCategoryAllCases() {
        XCTAssertEqual(LogCategory.allCases.count, 9)
        let expected: Set<String> = ["network", "ui", "lifecycle", "performance", "error", "agent", "codex", "terminal", "state"]
        XCTAssertEqual(Set(LogCategory.allCases.map(\.rawValue)), expected)
    }

    func testLogCategoryCodable() throws {
        let json = Data(#""codex""#.utf8)
        let decoded = try JSONDecoder().decode(LogCategory.self, from: json)
        XCTAssertEqual(decoded, .codex)
    }
}

// MARK: - LogEntry Tests

final class LogEntryTests: XCTestCase {

    func testLogEntryInitSetsFields() {
        let entry = LogEntry(level: .info, category: .network, message: "hello")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.category, .network)
        XCTAssertEqual(entry.message, "hello")
        XCTAssertNil(entry.metadata)
    }

    func testLogEntryRenderedMessageWithoutMetadata() {
        let entry = LogEntry(level: .debug, category: .ui, message: "test msg")
        XCTAssertEqual(entry.renderedMessage, "test msg")
    }

    func testLogEntryRenderedMessageWithMetadata() {
        let entry = LogEntry(level: .info, category: .ui, message: "test", metadata: ["key": "val"])
        XCTAssertTrue(entry.renderedMessage.contains("key=val"))
        XCTAssertTrue(entry.renderedMessage.hasPrefix("test "))
    }

    func testLogEntryFormattedMetadataNilWhenNoMetadata() {
        let entry = LogEntry(level: .debug, category: .ui, message: "x")
        XCTAssertNil(entry.formattedMetadata)
    }

    func testLogEntryCodableRoundTrip() throws {
        let entry = LogEntry(level: .warning, category: .performance, message: "slow", metadata: ["duration_ms": "42"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LogEntry.self, from: data)

        XCTAssertEqual(decoded.level, .warning)
        XCTAssertEqual(decoded.category, .performance)
        XCTAssertEqual(decoded.message, "slow")
        XCTAssertEqual(decoded.metadata?["duration_ms"], "42")
    }

    func testLogEntryIdIsUnique() {
        let a = LogEntry(level: .info, category: .ui, message: "a")
        let b = LogEntry(level: .info, category: .ui, message: "b")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testLogEntryTimestampIsRecent() {
        let before = Date()
        let entry = LogEntry(level: .info, category: .ui, message: "t")
        let after = Date()
        XCTAssertTrue(entry.timestamp >= before)
        XCTAssertTrue(entry.timestamp <= after)
    }

    func testSensitiveKeysAreRedacted() {
        let entry = LogEntry(level: .info, category: .network, message: "req", metadata: [
            "authorization": "Bearer secret123",
            "api_key": "sk-abc",
            "normal": "visible",
        ])
        XCTAssertEqual(entry.metadata?["authorization"], "[redacted]")
        XCTAssertEqual(entry.metadata?["api_key"], "[redacted]")
        XCTAssertEqual(entry.metadata?["normal"], "visible")
    }

    func testSensitiveKeysCaseInsensitive() {
        let entry = LogEntry(level: .info, category: .network, message: "req", metadata: [
            "Authorization": "Bearer xyz",
        ])
        XCTAssertEqual(entry.metadata?["Authorization"], "[redacted]")
    }

    func testAllSensitiveKeyVariants() {
        let keys = ["access-token", "access_token", "auth-token", "auth_token",
                     "session-token", "session_token", "private-key", "private_key",
                     "password", "secret", "bearer", "cookie", "token", "apikey"]
        for key in keys {
            let entry = LogEntry(level: .info, category: .network, message: "x", metadata: [key: "val"])
            XCTAssertEqual(entry.metadata?[key], "[redacted]", "Key '\(key)' should be redacted")
        }
    }

    func testLongMetadataValueTruncated() {
        let longValue = String(repeating: "x", count: 600)
        let entry = LogEntry(level: .info, category: .ui, message: "x", metadata: ["big": longValue])
        let val = entry.metadata?["big"] ?? ""
        XCTAssertTrue(val.hasSuffix("...(truncated)"))
        XCTAssertTrue(val.count < 600)
    }

    func testMetadataNewlinesEscaped() {
        let entry = LogEntry(level: .info, category: .ui, message: "x", metadata: ["msg": "line1\nline2\ttab\rret"])
        let val = entry.metadata?["msg"] ?? ""
        XCTAssertFalse(val.contains("\n"))
        XCTAssertFalse(val.contains("\t"))
        XCTAssertFalse(val.contains("\r"))
        XCTAssertTrue(val.contains("\\n"))
        XCTAssertTrue(val.contains("\\t"))
        XCTAssertTrue(val.contains("\\r"))
    }

    func testEmptyMetadataBecomesNil() {
        let entry = LogEntry(level: .info, category: .ui, message: "x", metadata: [:])
        XCTAssertNil(entry.metadata)
    }

    func testWhitespaceOnlyKeysStripped() {
        let entry = LogEntry(level: .info, category: .ui, message: "x", metadata: ["  ": "val", "key": "v"])
        XCTAssertNil(entry.metadata?["  "])
        XCTAssertEqual(entry.metadata?["key"], "v")
    }

    func testFormattedMetadataSortedByKey() {
        let entry = LogEntry(level: .info, category: .ui, message: "x", metadata: ["z": "1", "a": "2"])
        let fmt = entry.formattedMetadata!
        XCTAssertEqual(fmt, "a=2 z=1")
    }

    func testExactly500CharsNotTruncated() {
        let value = String(repeating: "a", count: 500)
        let entry = LogEntry(level: .info, category: .ui, message: "x", metadata: ["k": value])
        XCTAssertEqual(entry.metadata?["k"], value)
    }
}

// MARK: - LogFileStats Tests

final class LogFileStatsTests: XCTestCase {

    func testLogFileStatsInit() {
        let stats = LogFileStats(
            fileURL: URL(fileURLWithPath: "/tmp/test.log"),
            sizeBytes: 1024,
            entryCount: 50,
            droppedWriteCount: 3,
            lastWriteError: "disk full"
        )
        XCTAssertEqual(stats.sizeBytes, 1024)
        XCTAssertEqual(stats.entryCount, 50)
        XCTAssertEqual(stats.droppedWriteCount, 3)
        XCTAssertEqual(stats.lastWriteError, "disk full")
    }
}

// MARK: - FileLogWriter Tests

final class FileLogWriterTests: XCTestCase {

    func testWriteAndReadEntries() async {
        let writer = AppLogger.fileWriter
        let marker = UUID().uuidString
        let entry = LogEntry(level: .info, category: .state, message: "test-\(marker)")
        await writer.write(entry)

        let entries = await writer.readEntries(limit: 5000)
        XCTAssertTrue(entries.contains(where: { $0.message == "test-\(marker)" }))
    }

    func testEntryCountNonNegative() async {
        let count = await AppLogger.fileWriter.entryCount()
        XCTAssertTrue(count >= 0)
    }

    func testLogFileSizeNonNegative() async {
        let size = await AppLogger.fileWriter.logFileSize()
        XCTAssertTrue(size >= 0)
    }

    func testStatsReturnsValidObject() async {
        let stats = await AppLogger.fileWriter.stats()
        XCTAssertTrue(stats.sizeBytes >= 0)
        XCTAssertTrue(stats.entryCount >= 0)
        XCTAssertTrue(stats.droppedWriteCount >= 0)
    }

    func testExportLogReturnsURL() async {
        let url = await AppLogger.fileWriter.exportLog()
        XCTAssertNotNil(url)
    }

    func testReadEntriesLimitRespected() async {
        let writer = AppLogger.fileWriter
        // Write a few entries
        for i in 0..<5 {
            await writer.write(LogEntry(level: .debug, category: .ui, message: "limit-test-\(i)"))
        }
        let entries = await writer.readEntries(limit: 3)
        XCTAssertLessThanOrEqual(entries.count, 3)
    }
}

// MARK: - AppLogger Static Loggers Tests

final class AppLoggerStaticTests: XCTestCase {

    func testAllCategoryLoggersExist() {
        // Just verify each logger has the right category
        XCTAssertEqual(AppLogger.network.category, .network)
        XCTAssertEqual(AppLogger.ui.category, .ui)
        XCTAssertEqual(AppLogger.lifecycle.category, .lifecycle)
        XCTAssertEqual(AppLogger.performance.category, .performance)
        XCTAssertEqual(AppLogger.error.category, .error)
        XCTAssertEqual(AppLogger.agent.category, .agent)
        XCTAssertEqual(AppLogger.codex.category, .codex)
        XCTAssertEqual(AppLogger.terminal.category, .terminal)
        XCTAssertEqual(AppLogger.state.category, .state)
    }
}
