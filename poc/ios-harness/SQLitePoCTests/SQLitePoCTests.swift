// XCTest: open SQLite DB in the app sandbox's Documents directory, create
// schema, insert N rows, query them back, close. Real file path (not :memory:).
//
// The Zig wrapper creates the schema inside `sqpoc_open`. Swift only calls
// through the PoC C ABI — Swift never calls sqlite3_* directly, so the test
// cannot be accidentally satisfied by Apple's built-in SQLite integration.

import XCTest
@testable import SQLitePoC

final class SQLitePoCTests: XCTestCase {

    func testRoundTripInDocumentsDirectory() throws {
        let fm = FileManager.default
        let docs = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Unique file per test to avoid stale state between runs.
        let dbURL = docs.appendingPathComponent("sqpoc-\(UUID().uuidString).sqlite")
        defer {
            try? fm.removeItem(at: dbURL)
            // WAL files if PRAGMA journal_mode=WAL was enabled (we don't set
            // it in this PoC, but clean up defensively).
            try? fm.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? fm.removeItem(at: dbURL.appendingPathExtension("shm"))
        }

        let path = dbURL.path
        XCTAssertFalse(path.contains(":memory:"), "path must be a real file")

        guard let handle = path.withCString({ sqpoc_open($0) }) else {
            let err = String(cString: sqpoc_open_error())
            XCTFail("sqpoc_open failed: \(err)")
            return
        }
        defer { sqpoc_close(handle) }

        // Insert N rows.
        let N: Int64 = 200
        for i in 0..<N {
            let text = "row-\(i)"
            let rc = text.withCString { sqpoc_insert_row(handle, i, $0) }
            XCTAssertEqual(rc, 0, "insert \(i) failed: \(String(cString: sqpoc_last_error(handle)))")
        }

        XCTAssertEqual(sqpoc_count_rows(handle), N)

        // Spot-check round-trip integrity on a few rows.
        for i in stride(from: Int64(0), to: N, by: 37) {
            var buf = [CChar](repeating: 0, count: 64)
            let n = buf.withUnsafeMutableBufferPointer { bp -> Int64 in
                sqpoc_get_text(handle, i, bp.baseAddress, Int32(bp.count))
            }
            XCTAssertGreaterThanOrEqual(n, 0, "get_text \(i)")
            let got = String(cString: buf)
            XCTAssertEqual(got, "row-\(i)")
        }

        // The file MUST exist on disk after work — proves we weren't in-memory.
        XCTAssertTrue(fm.fileExists(atPath: path), "database file missing at \(path)")
    }
}
