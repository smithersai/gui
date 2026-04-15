import Foundation
import XCTest
@testable import SmithersGUI

@MainActor
final class SQLBrowserClientTests: XCTestCase {
    private func ensureSQLite3() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sqlite3", "--version"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw XCTSkip("sqlite3 is required for SQLBrowserClientTests")
            }
        } catch {
            throw XCTSkip("sqlite3 is required for SQLBrowserClientTests")
        }
    }

    private func makeTempDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = root.appendingPathComponent("smithers-sql-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func runSQLite(dbPath: String, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sqlite3", dbPath, sql]

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "SQLBrowserClientTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "sqlite3 failed: \(message)"]
            )
        }
    }

    private func makeDatabase() throws -> URL {
        try ensureSQLite3()

        let directory = try makeTempDirectory()
        let dbURL = directory.appendingPathComponent("smithers.db")
        try runSQLite(
            dbPath: dbURL.path,
            sql: """
            CREATE TABLE widgets (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                active INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO widgets (id, name, active) VALUES (1, 'alpha', 1);
            INSERT INTO widgets (id, name, active) VALUES (2, 'beta', 0);
            CREATE VIEW widget_names AS
            SELECT name FROM widgets;
            """
        )

        return directory
    }

    private func makeClient(cwd: String) -> SmithersClient {
        SmithersClient(cwd: cwd)
    }

    private func rowMaps(from result: SQLResult) -> [[String: String]] {
        result.rows.map { row in
            Dictionary(uniqueKeysWithValues: zip(result.columns, row))
        }
    }

    func testListSQLTablesUsesSQLiteFallback() async throws {
        let directory = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient(cwd: directory.path)
        let tables = try await client.listSQLTables()

        XCTAssertTrue(tables.contains(where: { $0.name == "widgets" && $0.type == "table" }))
        XCTAssertTrue(tables.contains(where: { $0.name == "widget_names" && $0.type == "view" }))
        XCTAssertEqual(tables.first(where: { $0.name == "widgets" })?.rowCount, 2)
    }

    func testGetSQLTableSchemaUsesSQLiteFallback() async throws {
        let directory = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient(cwd: directory.path)
        let schema = try await client.getSQLTableSchema("widgets")

        XCTAssertEqual(schema.tableName, "widgets")
        XCTAssertEqual(schema.columns.map(\.name), ["id", "name", "active"])
        XCTAssertTrue(schema.columns[0].primaryKey)
        XCTAssertTrue(schema.columns[1].notNull)
    }

    func testExecuteSQLSelectUsesSQLiteFallback() async throws {
        let directory = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient(cwd: directory.path)
        let result = try await client.executeSQL(
            "SELECT id, name, active FROM widgets ORDER BY id"
        )
        let rows = rowMaps(from: result)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["id"], "1")
        XCTAssertEqual(rows[0]["name"], "alpha")
        XCTAssertEqual(rows[0]["active"], "true")
        XCTAssertEqual(rows[1]["id"], "2")
        XCTAssertEqual(rows[1]["name"], "beta")
        XCTAssertEqual(rows[1]["active"], "false")
    }

    func testExecuteSQLMutationWithoutServerReturnsNoTransport() async throws {
        let directory = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient(cwd: directory.path)

        do {
            _ = try await client.executeSQL("UPDATE widgets SET name = 'changed' WHERE id = 1")
            XCTFail("Mutation query should not run without HTTP SQL transport")
        } catch {
            guard case SmithersError.notAvailable(let message) = error else {
                XCTFail("Expected SmithersError.notAvailable, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("no smithers transport available"))
        }

        let verify = try await client.executeSQL("SELECT name FROM widgets WHERE id = 1")
        let rows = rowMaps(from: verify)
        XCTAssertEqual(rows.first?["name"], "alpha")
    }
}
