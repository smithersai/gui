import Foundation

enum PersistedChatRole: String {
    case user
    case assistant
}

struct PersistedSessionSummary {
    let id: String
    let title: String
    let preview: String
    let updatedAt: Date
    let createdAt: Date
    var isPinned: Bool = false
    var isArchived: Bool = false
    var isUnread: Bool = false
}

struct PersistedSessionMessage {
    let id: String
    let role: PersistedChatRole
    let text: String
    let createdAt: Date
}

struct PersistedTerminalTab {
    let id: String
    let title: String
    let preview: String
    let updatedAt: Date
    let createdAt: Date
    let workingDirectory: String?
    let command: String?
    let backend: TerminalBackend
    let rootSurfaceId: String?
    let tmuxSocketName: String?
    let tmuxSessionName: String?
    let workspaceStateJSON: String?
    var isPinned: Bool = false
}

protocol SessionPersisting: AnyObject {
    func loadSessions() throws -> [PersistedSessionSummary]
    func loadMessages(sessionID: String) throws -> [PersistedSessionMessage]
    func loadTerminalTabs() throws -> [PersistedTerminalTab]
    func createSession(id: String, title: String) throws
    func renameSession(id: String, title: String) throws
    func updateSessionFlags(id: String, isPinned: Bool, isArchived: Bool, isUnread: Bool) throws
    func deleteSession(id: String) throws
    func createMessage(sessionID: String, messageID: String, role: PersistedChatRole, text: String) throws
    func updateMessage(messageID: String, role: PersistedChatRole, text: String) throws
    func upsertTerminalTab(_ tab: PersistedTerminalTab) throws
    func deleteTerminalTab(id: String) throws
}

final class SQLiteSessionPersistence: SessionPersisting {
    static let sqliteBinaryPath = "/usr/bin/sqlite3"

    static var isSQLiteAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sqliteBinaryPath)
    }

    private let fileManager = FileManager.default
    private let initLock = NSLock()
    private let dataDirectory: String
    private let databasePath: String
    private let sqlitePath: String?
    private var schemaInitialized = false

    init(workingDirectory: String) {
        dataDirectory = Self.resolveDataDirectory(from: workingDirectory)
        databasePath = Self.resolveDatabasePath(in: dataDirectory)
        sqlitePath = Self.isSQLiteAvailable ? Self.sqliteBinaryPath : nil
    }

    func loadSessions() throws -> [PersistedSessionSummary] {
        try ensureSchema()

        let rows = try executeJSON(
            """
            SELECT
              s.id AS id,
              s.title AS title,
              s.updated_at AS updated_at,
              s.created_at AS created_at,
              COALESCE(s.is_pinned, 0) AS is_pinned,
              COALESCE(s.is_archived, 0) AS is_archived,
              COALESCE(s.is_unread, 0) AS is_unread,
              COALESCE((
                SELECT m.parts
                FROM messages m
                WHERE m.session_id = s.id
                ORDER BY m.created_at DESC
                LIMIT 1
              ), '') AS latest_parts,
              COALESCE((
                SELECT m.parts
                FROM messages m
                WHERE m.session_id = s.id
                  AND m.role = 'user'
                ORDER BY m.created_at ASC
                LIMIT 1
              ), '') AS first_user_parts
            FROM sessions s
            WHERE s.parent_session_id IS NULL
            ORDER BY s.created_at DESC;
            """
        )

        return rows.compactMap { row in
            guard let id = stringValue(row["id"]) else { return nil }
            let rawTitle = stringValue(row["title"]) ?? SessionStore.defaultChatTitle
            let firstUser = extractText(fromPartsJSON: stringValue(row["first_user_parts"]) ?? "")
            let title = normalizedTitle(rawTitle, firstUserMessage: firstUser)
            let latestText = extractText(fromPartsJSON: stringValue(row["latest_parts"]) ?? "")
            let preview = String((latestText.nilIfBlank ?? firstUser).prefix(80))
            let updatedAt = date(fromUnix: int64Value(row["updated_at"]))
            let createdAt = date(fromUnix: int64Value(row["created_at"]))
            return PersistedSessionSummary(
                id: id,
                title: title,
                preview: preview,
                updatedAt: updatedAt,
                createdAt: createdAt,
                isPinned: boolValue(row["is_pinned"]),
                isArchived: boolValue(row["is_archived"]),
                isUnread: boolValue(row["is_unread"])
            )
        }
    }

    func loadMessages(sessionID: String) throws -> [PersistedSessionMessage] {
        try ensureSchema()

        let rows = try executeJSON(
            """
            SELECT
              id,
              role,
              parts,
              created_at
            FROM messages
            WHERE session_id = \(quoteSQL(sessionID))
            ORDER BY created_at ASC;
            """
        )

        return rows.compactMap { row in
            guard let id = stringValue(row["id"]),
                  let roleRaw = stringValue(row["role"])?.lowercased(),
                  let role = PersistedChatRole(rawValue: roleRaw)
            else {
                return nil
            }

            let text = extractText(fromPartsJSON: stringValue(row["parts"]) ?? "")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return PersistedSessionMessage(
                id: id,
                role: role,
                text: text,
                createdAt: date(fromUnix: int64Value(row["created_at"]))
            )
        }
    }

    func loadTerminalTabs() throws -> [PersistedTerminalTab] {
        try ensureSchema()

        let rows = try executeJSON(
            """
            SELECT
              id,
              title,
              preview,
              updated_at,
              created_at,
              working_directory,
              command,
              backend,
              root_surface_id,
              tmux_socket_name,
              tmux_session_name,
              workspace_state_json,
              COALESCE(is_pinned, 0) AS is_pinned
            FROM terminal_tabs
            ORDER BY updated_at DESC;
            """
        )

        return rows.compactMap { row in
            guard let id = stringValue(row["id"]) else { return nil }
            let backendRaw = stringValue(row["backend"]) ?? TerminalBackend.tmux.rawValue
            return PersistedTerminalTab(
                id: id,
                title: stringValue(row["title"]) ?? "Terminal",
                preview: stringValue(row["preview"]) ?? "Shell session",
                updatedAt: date(fromUnix: int64Value(row["updated_at"])),
                createdAt: date(fromUnix: int64Value(row["created_at"])),
                workingDirectory: nonEmptyStringValue(row["working_directory"]),
                command: nonEmptyStringValue(row["command"]),
                backend: TerminalBackend(rawValue: backendRaw) ?? .tmux,
                rootSurfaceId: nonEmptyStringValue(row["root_surface_id"]),
                tmuxSocketName: nonEmptyStringValue(row["tmux_socket_name"]),
                tmuxSessionName: nonEmptyStringValue(row["tmux_session_name"]),
                workspaceStateJSON: nonEmptyStringValue(row["workspace_state_json"]),
                isPinned: boolValue(row["is_pinned"])
            )
        }
    }

    func createSession(id: String, title: String) throws {
        try ensureSchema()

        try executeWrite(
            """
            BEGIN;
            INSERT OR IGNORE INTO sessions (
              id,
              parent_session_id,
              title,
              message_count,
              prompt_tokens,
              completion_tokens,
              cost,
              summary_message_id,
              todos,
              is_pinned,
              is_archived,
              is_unread,
              updated_at,
              created_at
            ) VALUES (
              \(quoteSQL(id)),
              NULL,
              \(quoteSQL(title)),
              0,
              0,
              0,
              0.0,
              NULL,
              NULL,
              0,
              0,
              0,
              strftime('%s', 'now'),
              strftime('%s', 'now')
            );
            UPDATE sessions
            SET
              title = \(quoteSQL(title)),
              updated_at = strftime('%s', 'now')
            WHERE id = \(quoteSQL(id));
            COMMIT;
            """
        )
    }

    func renameSession(id: String, title: String) throws {
        try ensureSchema()

        try executeWrite(
            """
            UPDATE sessions
            SET title = \(quoteSQL(title))
            WHERE id = \(quoteSQL(id));
            """
        )
    }

    func updateSessionFlags(id: String, isPinned: Bool, isArchived: Bool, isUnread: Bool) throws {
        try ensureSchema()

        try executeWrite(
            """
            UPDATE sessions
            SET
              is_pinned = \(isPinned ? 1 : 0),
              is_archived = \(isArchived ? 1 : 0),
              is_unread = \(isUnread ? 1 : 0)
            WHERE id = \(quoteSQL(id));
            """
        )
    }

    func deleteSession(id: String) throws {
        try ensureSchema()

        try executeWrite(
            """
            BEGIN;
            DELETE FROM messages WHERE session_id = \(quoteSQL(id));
            DELETE FROM files WHERE session_id = \(quoteSQL(id));
            DELETE FROM read_files WHERE session_id = \(quoteSQL(id));
            DELETE FROM sessions WHERE id = \(quoteSQL(id));
            COMMIT;
            """
        )
    }

    func createMessage(sessionID: String, messageID: String, role: PersistedChatRole, text: String) throws {
        try ensureSchema()

        let parts = textPartsJSON(text)
        try executeWrite(
            """
            BEGIN;
            INSERT INTO messages (
              id,
              session_id,
              role,
              parts,
              model,
              provider,
              is_summary_message,
              created_at,
              updated_at
            ) VALUES (
              \(quoteSQL(messageID)),
              \(quoteSQL(sessionID)),
              \(quoteSQL(role.rawValue)),
              \(quoteSQL(parts)),
              NULL,
              NULL,
              0,
              strftime('%s', 'now'),
              strftime('%s', 'now')
            );
            UPDATE sessions
            SET updated_at = strftime('%s', 'now')
            WHERE id = \(quoteSQL(sessionID));
            COMMIT;
            """
        )
    }

    func updateMessage(messageID: String, role: PersistedChatRole, text: String) throws {
        try ensureSchema()

        let parts = textPartsJSON(text)
        try executeWrite(
            """
            BEGIN;
            UPDATE messages
            SET
              role = \(quoteSQL(role.rawValue)),
              parts = \(quoteSQL(parts)),
              updated_at = strftime('%s', 'now')
            WHERE id = \(quoteSQL(messageID));
            UPDATE sessions
            SET updated_at = strftime('%s', 'now')
            WHERE id = (
              SELECT session_id
              FROM messages
              WHERE id = \(quoteSQL(messageID))
            );
            COMMIT;
            """
        )
    }

    func upsertTerminalTab(_ tab: PersistedTerminalTab) throws {
        try ensureSchema()

        try executeWrite(
            """
            INSERT INTO terminal_tabs (
              id,
              title,
              preview,
              working_directory,
              command,
              backend,
              root_surface_id,
              tmux_socket_name,
              tmux_session_name,
              workspace_state_json,
              is_pinned,
              updated_at,
              created_at
            ) VALUES (
              \(quoteSQL(tab.id)),
              \(quoteSQL(tab.title)),
              \(quoteSQL(tab.preview)),
              \(quoteOptionalSQL(tab.workingDirectory)),
              \(quoteOptionalSQL(tab.command)),
              \(quoteSQL(tab.backend.rawValue)),
              \(quoteOptionalSQL(tab.rootSurfaceId)),
              \(quoteOptionalSQL(tab.tmuxSocketName)),
              \(quoteOptionalSQL(tab.tmuxSessionName)),
              \(quoteOptionalSQL(tab.workspaceStateJSON)),
              \(tab.isPinned ? 1 : 0),
              \(unixSeconds(tab.updatedAt)),
              \(unixSeconds(tab.createdAt))
            )
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title,
              preview = excluded.preview,
              working_directory = excluded.working_directory,
              command = excluded.command,
              backend = excluded.backend,
              root_surface_id = excluded.root_surface_id,
              tmux_socket_name = excluded.tmux_socket_name,
              tmux_session_name = excluded.tmux_session_name,
              workspace_state_json = excluded.workspace_state_json,
              is_pinned = excluded.is_pinned,
              updated_at = excluded.updated_at;
            """
        )
    }

    func deleteTerminalTab(id: String) throws {
        try ensureSchema()

        try executeWrite(
            """
            DELETE FROM terminal_tabs
            WHERE id = \(quoteSQL(id));
            """
        )
    }

    private func ensureSchema() throws {
        initLock.lock()
        defer { initLock.unlock() }

        if schemaInitialized {
            return
        }

        guard sqlitePath != nil else {
            throw SQLiteSessionPersistenceError("sqlite3 is not available")
        }

        try fileManager.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)

        try executeWrite(
            """
            PRAGMA foreign_keys = ON;
            PRAGMA journal_mode = WAL;

            CREATE TABLE IF NOT EXISTS sessions (
              id TEXT PRIMARY KEY,
              parent_session_id TEXT,
              title TEXT NOT NULL,
              message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count >= 0),
              prompt_tokens INTEGER NOT NULL DEFAULT 0 CHECK (prompt_tokens >= 0),
              completion_tokens INTEGER NOT NULL DEFAULT 0 CHECK (completion_tokens >= 0),
              cost REAL NOT NULL DEFAULT 0.0 CHECK (cost >= 0.0),
              updated_at INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              summary_message_id TEXT,
              todos TEXT,
              is_pinned INTEGER NOT NULL DEFAULT 0,
              is_archived INTEGER NOT NULL DEFAULT 0,
              is_unread INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS files (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              path TEXT NOT NULL,
              content TEXT NOT NULL,
              version INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
              UNIQUE(path, session_id, version)
            );

            CREATE TABLE IF NOT EXISTS messages (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              role TEXT NOT NULL,
              parts TEXT NOT NULL DEFAULT '[]',
              model TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              finished_at INTEGER,
              provider TEXT,
              is_summary_message INTEGER DEFAULT 0 NOT NULL,
              FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS read_files (
              session_id TEXT NOT NULL,
              path TEXT NOT NULL,
              read_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
              PRIMARY KEY (session_id, path),
              FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS terminal_tabs (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              preview TEXT NOT NULL DEFAULT '',
              working_directory TEXT,
              command TEXT,
              backend TEXT NOT NULL DEFAULT 'tmux',
              root_surface_id TEXT,
              tmux_socket_name TEXT,
              tmux_session_name TEXT,
              workspace_state_json TEXT,
              is_pinned INTEGER NOT NULL DEFAULT 0,
              updated_at INTEGER NOT NULL,
              created_at INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_files_session_id ON files (session_id);
            CREATE INDEX IF NOT EXISTS idx_files_path ON files (path);
            CREATE INDEX IF NOT EXISTS idx_messages_session_id ON messages (session_id);
            CREATE INDEX IF NOT EXISTS idx_sessions_created_at ON sessions (created_at);
            CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages (created_at);
            CREATE INDEX IF NOT EXISTS idx_files_created_at ON files (created_at);
            CREATE INDEX IF NOT EXISTS idx_terminal_tabs_updated_at ON terminal_tabs (updated_at);

            CREATE TRIGGER IF NOT EXISTS update_sessions_updated_at
            AFTER UPDATE ON sessions
            BEGIN
              UPDATE sessions SET updated_at = strftime('%s', 'now')
              WHERE id = new.id;
            END;

            CREATE TRIGGER IF NOT EXISTS update_files_updated_at
            AFTER UPDATE ON files
            BEGIN
              UPDATE files SET updated_at = strftime('%s', 'now')
              WHERE id = new.id;
            END;

            CREATE TRIGGER IF NOT EXISTS update_messages_updated_at
            AFTER UPDATE ON messages
            BEGIN
              UPDATE messages SET updated_at = strftime('%s', 'now')
              WHERE id = new.id;
            END;

            CREATE TRIGGER IF NOT EXISTS update_session_message_count_on_insert
            AFTER INSERT ON messages
            BEGIN
              UPDATE sessions
              SET message_count = message_count + 1
              WHERE id = new.session_id;
            END;

            CREATE TRIGGER IF NOT EXISTS update_session_message_count_on_delete
            AFTER DELETE ON messages
            BEGIN
              UPDATE sessions
              SET message_count = message_count - 1
              WHERE id = old.session_id;
            END;
            """
        )

        try ensureColumn(table: "sessions", column: "summary_message_id", definition: "TEXT")
        try ensureColumn(table: "sessions", column: "todos", definition: "TEXT")
        try ensureColumn(table: "sessions", column: "is_pinned", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "sessions", column: "is_archived", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "sessions", column: "is_unread", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "messages", column: "provider", definition: "TEXT")
        try ensureColumn(table: "messages", column: "is_summary_message", definition: "INTEGER DEFAULT 0 NOT NULL")
        try ensureColumn(table: "terminal_tabs", column: "working_directory", definition: "TEXT")
        try ensureColumn(table: "terminal_tabs", column: "command", definition: "TEXT")
        try ensureColumn(table: "terminal_tabs", column: "backend", definition: "TEXT NOT NULL DEFAULT 'tmux'")
        try ensureColumn(table: "terminal_tabs", column: "root_surface_id", definition: "TEXT")
        try ensureColumn(table: "terminal_tabs", column: "tmux_socket_name", definition: "TEXT")
        try ensureColumn(table: "terminal_tabs", column: "tmux_session_name", definition: "TEXT")
        try ensureColumn(table: "terminal_tabs", column: "workspace_state_json", definition: "TEXT")
        try ensureColumn(table: "terminal_tabs", column: "is_pinned", definition: "INTEGER NOT NULL DEFAULT 0")

        schemaInitialized = true
    }

    private func ensureColumn(table: String, column: String, definition: String) throws {
        let rows = try executeJSON("PRAGMA table_info(\(table));")
        let hasColumn = rows.contains { row in
            stringValue(row["name"])?.caseInsensitiveCompare(column) == .orderedSame
        }
        if hasColumn {
            return
        }

        try executeWrite(
            """
            ALTER TABLE \(quoteIdentifier(table))
            ADD COLUMN \(quoteIdentifier(column)) \(definition);
            """
        )
    }

    private func executeJSON(_ query: String) throws -> [[String: Any]] {
        let output = try runSQLite(arguments: ["-json", databasePath, query])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else {
            throw SQLiteSessionPersistenceError("sqlite3 emitted non-UTF8 output")
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SQLiteSessionPersistenceError("sqlite3 JSON payload is not an array")
        }
        return rows
    }

    private func executeWrite(_ query: String) throws {
        _ = try runSQLite(arguments: [databasePath, query])
    }

    private func runSQLite(arguments: [String]) throws -> String {
        guard let sqlitePath else {
            throw SQLiteSessionPersistenceError("sqlite3 is not available")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let readerGroup = DispatchGroup()
        let outputReader = SQLitePipeReader(fileHandle: outputPipe.fileHandleForReading)
        let errorReader = SQLitePipeReader(fileHandle: errorPipe.fileHandleForReading)
        outputReader.start(group: readerGroup)
        errorReader.start(group: readerGroup)
        process.waitUntilExit()
        readerGroup.wait()

        let outputData = outputReader.collectedData()
        let errorData = errorReader.collectedData()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let stderr = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SQLiteSessionPersistenceError(
                detail.isEmpty
                    ? "sqlite3 exited with status \(process.terminationStatus)"
                    : detail
            )
        }

        return output
    }

    private static func resolveDataDirectory(from workingDirectory: String) -> String {
        for directory in [".codeplane", ".smithers-tui", ".crush"] {
            if let found = lookupClosestDirectory(named: directory, from: workingDirectory) {
                return found
            }
        }

        return (workingDirectory as NSString).appendingPathComponent(".codeplane")
    }

    private static func lookupClosestDirectory(named target: String, from start: String) -> String? {
        var current = URL(fileURLWithPath: start, isDirectory: true).standardizedFileURL
        let fm = FileManager.default

        while true {
            let candidate = current.appendingPathComponent(target, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    private static func resolveDatabasePath(in dataDirectory: String) -> String {
        let candidates = ["codeplane.db", "smithers-tui.db", "crush.db"].map {
            (dataDirectory as NSString).appendingPathComponent($0)
        }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }

        return candidates[0]
    }
}

private final class SQLitePipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func start(group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let captured = fileHandle.readDataToEndOfFile()
            lock.lock()
            data = captured
            lock.unlock()
            group.leave()
        }
    }

    func collectedData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private struct SQLiteSessionPersistenceError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var errorDescription: String? { message }
}

private func quoteSQL(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

private func quoteOptionalSQL(_ value: String?) -> String {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "NULL"
    }
    return quoteSQL(value)
}

private func quoteIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func unixSeconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970)
}

private func int64Value(_ value: Any?) -> Int64 {
    if let int = value as? Int64 {
        return int
    }
    if let int = value as? Int {
        return Int64(int)
    }
    if let number = value as? NSNumber {
        return number.int64Value
    }
    if let text = value as? String, let int = Int64(text) {
        return int
    }
    return 0
}

private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
        return value
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return nil
}

private func nonEmptyStringValue(_ value: Any?) -> String? {
    let trimmed = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func boolValue(_ value: Any?) -> Bool {
    if let bool = value as? Bool {
        return bool
    }
    if let number = value as? NSNumber {
        return number.boolValue
    }
    if let text = value as? String {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }
    return false
}

private func date(fromUnix value: Int64) -> Date {
    guard value > 0 else { return Date.distantPast }
    if value > 10_000_000_000 {
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
    }
    return Date(timeIntervalSince1970: TimeInterval(value))
}

private func textPartsJSON(_ text: String) -> String {
    let payload: [[String: Any]] = [
        [
            "type": "text",
            "data": [
                "text": text,
            ],
        ],
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }

    return json
}

private func extractText(fromPartsJSON value: String) -> String {
    guard let data = value.data(using: .utf8),
          let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
        return ""
    }

    let chunks: [String] = parts.compactMap { part in
        let type = (part["type"] as? String)?.lowercased() ?? ""
        guard type == "text" else { return nil }

        if let data = part["data"] as? [String: Any],
           let text = data["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let text = part["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        return nil
    }

    return chunks.joined(separator: "\n\n")
}

private func normalizedTitle(_ storedTitle: String, firstUserMessage: String) -> String {
    let trimmed = storedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if SessionStore.isPlaceholderChatTitle(trimmed) {
        let generated = ChatTitleGenerator.title(for: firstUserMessage)
        return generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SessionStore.defaultChatTitle
            : generated
    }
    return storedTitle
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
