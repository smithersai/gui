import XCTest
@testable import LibGhosttyWrapper

/// PoC: libghostty-vt on iOS.
///
/// These tests assert TERMINAL CELL-BUFFER STATE after deterministic
/// replay of a canned VT byte stream. They do NOT hash Metal or
/// CoreGraphics pixel output — such hashes flake across simulator/device
/// and font stacks. The formatter's PLAIN output is the definitive
/// cell-buffer projection.
final class CellBufferTests: XCTestCase {

    /// Xcode test bundle (resources are copied alongside the test binary).
    private var fixtureBundle: Bundle { Bundle(for: Self.self) }

    private func fixtureURL(_ name: String, ext: String) throws -> URL {
        if let direct = fixtureBundle.url(forResource: name, withExtension: ext) {
            return direct
        }
        // When the "Fixtures" group is copied as a folder reference, resources
        // appear under a `Fixtures/` subdirectory of the test bundle.
        if let nested = fixtureBundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return nested
        }
        throw NSError(domain: "PoCTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture \(name).\(ext) not found in test bundle at \(fixtureBundle.bundlePath)"])
    }

    /// Smallest possible end-to-end proof: terminal can be created,
    /// bytes written, cell buffer read back.
    func testWriteHelloProducesExpectedCells() throws {
        let term = try GhosttyVT(cols: 20, rows: 5)
        term.write(Array("hello world".utf8))
        let out = try term.plainText(trim: true)
        // Expect single row with "hello world" followed by (rows-1) blank rows.
        // Formatter trim=true drops trailing whitespace per row.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "hello world", "first row cells wrong: \(lines)")
        let cur = term.cursor
        XCTAssertEqual(cur.x, 11, "cursor x should advance past 'hello world'")
        XCTAssertEqual(cur.y, 0, "cursor should still be on row 0")
    }

    /// SGR sequences must not leak into plain-text cell contents.
    func testSGRDoesNotAppearInPlainText() throws {
        let term = try GhosttyVT(cols: 20, rows: 2)
        term.write(Array("\u{1B}[1;31mRED\u{1B}[0m".utf8))
        let out = try term.plainText()
        XCTAssertTrue(out.hasPrefix("RED"), "got: \(out)")
        XCTAssertFalse(out.contains("["), "SGR leak detected: \(out)")
        XCTAssertFalse(out.contains("\u{1B}"), "ESC leak detected: \(out)")
    }

    /// Full ls-la fixture → cell buffer golden match.
    func testLsLaFixtureMatchesGolden() throws {
        let term = try GhosttyVT(cols: 80, rows: 24)

        let fxURL = try fixtureURL("ls-la", ext: "vt")
        let bytes = try VTFixtureLoader.decode(contentsOf: fxURL)
        XCTAssertGreaterThan(bytes.count, 0)

        term.write(bytes)

        let got = try term.plainText(trim: true)

        let expectedURL = try fixtureURL("ls-la.expected", ext: "txt")
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)

        // Both files end with trailing newline; normalize to ease comparison.
        let gotNorm = got.trimmingCharacters(in: .whitespacesAndNewlines)
        let expNorm = expected.trimmingCharacters(in: .whitespacesAndNewlines)

        if gotNorm != expNorm {
            // Emit a readable diff marker in test output.
            print("=== GOT ===\n\(gotNorm)\n=== EXPECTED ===\n\(expNorm)\n===")
        }
        XCTAssertEqual(gotNorm, expNorm, "cell buffer differs from golden")

        // Size must stay put — fixture doesn't resize.
        let s = term.size
        XCTAssertEqual(s.cols, 80)
        XCTAssertEqual(s.rows, 24)
    }

    /// Deterministic replay: the same bytes applied to two fresh terminals
    /// must produce byte-identical cell buffers. Guards against hidden
    /// nondeterminism (timers, random palettes, RNG in escape handling).
    func testReplayDeterminism() throws {
        let a = try GhosttyVT(cols: 80, rows: 24)
        let b = try GhosttyVT(cols: 80, rows: 24)
        let fxURL = try fixtureURL("ls-la", ext: "vt")
        let bytes = try VTFixtureLoader.decode(contentsOf: fxURL)
        a.write(bytes)
        b.write(bytes)
        XCTAssertEqual(try a.plainText(), try b.plainText())
        XCTAssertEqual(a.cursor.x, b.cursor.x)
        XCTAssertEqual(a.cursor.y, b.cursor.y)
    }
}
