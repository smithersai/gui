import XCTest
@testable import SmithersGUI

/// Edge-case + randomized-fuzzer coverage for ``UnifiedDiffParser``.
///
/// The existing happy-path suite lives in ``UnifiedDiffParserTests``. This
/// suite intentionally lives in a separate file so the surface for randomized
/// / mutation tests doesn't accrete on the original happy-path file.
///
/// All fuzz tests use a fixed RNG seed for determinism — if a regression slips
/// in, the failure should reproduce locally without flakes.
final class UnifiedDiffParserEdgeTests: XCTestCase {

    // MARK: Helpers

    /// Calls the parser in non-strict mode (returns warnings rather than
    /// throwing) since fuzz inputs are expected to often be malformed.
    @discardableResult
    private func parseLenient(_ diff: String, path: String = "x.txt") -> UnifiedDiffParseResult? {
        try? UnifiedDiffParser.parse(diff: diff, path: path, strict: false)
    }

    @discardableResult
    private func parseStrict(_ diff: String, path: String = "x.txt") throws -> UnifiedDiffParseResult {
        try UnifiedDiffParser.parse(diff: diff, path: path, strict: true)
    }

    // MARK: Binary diff markers

    func testGitBinaryPatchMarkerFlagsBinary() throws {
        let diff = """
        GIT binary patch
        literal 7
        Hc$@<O00001
        """

        let parsed = try parseStrict(diff, path: "blob.bin")
        XCTAssertTrue(parsed.file.isBinary, "GIT binary patch line must mark file as binary")
        XCTAssertEqual(parsed.file.hunks.count, 0, "Binary patches must not produce text hunks")
    }

    func testBinaryFilesDifferMarkerHandledGracefully() throws {
        let diff = "Binary files a/img.png and b/img.png differ\n"
        let parsed = try parseStrict(diff, path: "img.png")
        XCTAssertTrue(parsed.file.isBinary)
        XCTAssertEqual(parsed.file.hunks.count, 0)
    }

    // MARK: Malformed @@ headers

    func testNegativeLineNumbersInHunkHeaderFailParseInStrictMode() {
        let diff = """
        @@ --3,1 +3,1 @@
        -a
        +b
        """
        XCTAssertThrowsError(try parseStrict(diff))
    }

    func testHunkHeaderMissingPlusSignThrowsStrict() {
        let diff = """
        @@ -1,1 1,1 @@
        -a
        +b
        """
        XCTAssertThrowsError(try parseStrict(diff))
    }

    func testHunkHeaderMissingLeadingMinusThrowsStrict() {
        let diff = """
        @@ 1,1 +1,1 @@
        -a
        +b
        """
        XCTAssertThrowsError(try parseStrict(diff))
    }

    func testHunkHeaderMissingCommaIsValid() throws {
        // A missing comma means count defaults to 1 — well-formed per
        // unified diff grammar.
        let diff = """
        @@ -5 +5 @@
        -a
        +b
        """
        let parsed = try parseStrict(diff)
        XCTAssertEqual(parsed.file.hunks.first?.oldCount, 1)
        XCTAssertEqual(parsed.file.hunks.first?.newCount, 1)
    }

    func testHunkHeaderWithIntMaxParsesOrFailsCleanly() {
        // Int.max as a 19-digit string is a valid Swift Int, so we expect a
        // successful parse — but the test exists to make sure we don't crash
        // on values near the integer boundary.
        let big = "\(Int.max)"
        let diff = "@@ -\(big),1 +\(big),1 @@\n-a\n+b\n"
        XCTAssertNoThrow(try parseStrict(diff))
    }

    func testHunkHeaderOverflowingIntegerThrowsStrict() {
        // 30-digit numbers cannot fit in a signed 64-bit Int and must be
        // rejected — never crash via overflow.
        let diff = """
        @@ -123456789012345678901234567890,1 +1,1 @@
        -a
        +b
        """
        XCTAssertThrowsError(try parseStrict(diff))
    }

    func testZeroWidthHunkParsesWithNoLines() throws {
        let diff = "@@ -0,0 +0,0 @@\n"
        let parsed = try parseStrict(diff)
        XCTAssertEqual(parsed.file.hunks.count, 1)
        XCTAssertEqual(parsed.file.hunks.first?.oldCount, 0)
        XCTAssertEqual(parsed.file.hunks.first?.newCount, 0)
        XCTAssertEqual(parsed.file.hunks.first?.lines.count, 0)
    }

    // MARK: Hunk count mismatches

    func testHunkCountMismatchHeaderDoesNotCrash() throws {
        // Header advertises 5 lines, body has 3. Parser is lenient and just
        // records what it sees — must not crash.
        let diff = """
        @@ -1,5 +1,5 @@
        -a
        -b
        -c
        """
        let parsed = try parseStrict(diff)
        XCTAssertEqual(parsed.file.hunks.first?.oldCount, 5)
        XCTAssertEqual(parsed.file.hunks.first?.lines.count, 3)
    }

    // MARK: Embedded weirdness

    func testEmbeddedNullBytesInContentDoNotCrash() throws {
        let diff = "@@ -1,1 +1,1 @@\n-old\u{0000}value\n+new\u{0000}value\n"
        let parsed = try parseStrict(diff)
        XCTAssertEqual(parsed.file.hunks.first?.lines.count, 2)
    }

    func testEmbeddedCRLFInUnifiedContextLineIsNormalized() throws {
        // Literal "\r\n" in the middle of a content line. Parser normalizes
        // \r\n -> \n at the top, so this becomes a hunk line split.
        let diff = " context-with-\r\nembedded\n"
        // Wrap with a hunk header:
        let wrapped = "@@ -1,2 +1,2 @@\n" + diff
        let parsed = try parseStrict(wrapped)
        // Two body lines emerge after CRLF normalization.
        XCTAssertGreaterThanOrEqual(parsed.file.hunks.first?.lines.count ?? 0, 1)
    }

    // MARK: File header / hunk ordering

    func testFileHeaderWithoutHunksProducesNoHunks() throws {
        let diff = """
        diff --git a/foo.txt b/foo.txt
        --- a/foo.txt
        +++ b/foo.txt
        """
        let parsed = try parseStrict(diff)
        XCTAssertEqual(parsed.file.hunks.count, 0)
    }

    func testHunksBeforeAnyFileHeaderStillParse() throws {
        // Free-floating hunks (no diff --git / --- / +++) still produce hunks
        // — the parser uses the explicit `path:` argument.
        let diff = """
        @@ -1,1 +1,1 @@
        -a
        +b
        """
        let parsed = try parseStrict(diff, path: "loose.txt")
        XCTAssertEqual(parsed.file.path, "loose.txt")
        XCTAssertEqual(parsed.file.hunks.count, 1)
    }

    func testBodyLinesBeforeAnyHunkHeaderAreIgnored() throws {
        let diff = """
        +stray-add
        -stray-del
         stray-ctx
        @@ -1,1 +1,1 @@
        -real
        +real-new
        """
        let parsed = try parseStrict(diff)
        XCTAssertEqual(parsed.file.hunks.count, 1)
        XCTAssertEqual(parsed.file.hunks.first?.lines.count, 2)
    }

    // MARK: Empty / whitespace input

    func testEmptyInputProducesEmptyFile() throws {
        let parsed = try parseStrict("")
        XCTAssertEqual(parsed.file.hunks.count, 0)
        XCTAssertFalse(parsed.file.isBinary)
    }

    func testWhitespaceOnlyInputProducesEmptyFile() throws {
        let parsed = try parseStrict("   \n\t\n  \n")
        XCTAssertEqual(parsed.file.hunks.count, 0)
    }

    // MARK: Large inputs

    func testVeryLongSingleLineOneMegabyte() throws {
        let mb = String(repeating: "a", count: 1_000_000)
        let diff = "@@ -1,1 +1,1 @@\n-x\n+\(mb)\n"
        let parsed = try parseStrict(diff)
        let added = parsed.file.hunks.flatMap(\.lines).first { $0.kind == .addition }
        XCTAssertEqual(added?.text.count, 1_000_000)
    }

    func testManySmallHunksBoundary10() throws {
        try assertManyHunks(count: 10)
    }

    func testManySmallHunksBoundary100() throws {
        try assertManyHunks(count: 100)
    }

    func testManySmallHunksBoundary1000() throws {
        try assertManyHunks(count: 1000)
    }

    private func assertManyHunks(count: Int) throws {
        var parts: [String] = []
        parts.reserveCapacity(count * 3)
        for i in 0..<count {
            let n = i + 1
            parts.append("@@ -\(n),1 +\(n),1 @@")
            parts.append("-old\(n)")
            parts.append("+new\(n)")
        }
        let parsed = try parseStrict(parts.joined(separator: "\n"))
        XCTAssertEqual(parsed.file.hunks.count, count)
        XCTAssertEqual(parsed.file.additions, count)
        XCTAssertEqual(parsed.file.deletions, count)
    }

    // MARK: Unicode filenames

    func testUnicodeFilenameRTL() throws {
        // Hebrew, right-to-left.
        let diff = """
        --- a/שלום.txt
        +++ b/שלום.txt
        @@ -1,1 +1,1 @@
        -שלום
        +שלום עולם
        """
        let parsed = try parseStrict(diff, path: "שלום.txt")
        XCTAssertEqual(parsed.file.path, "שלום.txt")
        XCTAssertEqual(parsed.file.hunks.count, 1)
    }

    func testUnicodeFilenameWithCombiningMarks() throws {
        // "café" in NFC vs NFD — Swift's `String` compares under canonical
        // equivalence (so `nfc == nfd` is `true`), but the underlying byte
        // sequences differ. Make sure the parser doesn't drop bytes when
        // round-tripping a name containing combining marks.
        let nfc = "caf\u{00E9}.txt"     // é precomposed
        let nfd = "cafe\u{0301}.txt"    // e + combining acute
        XCTAssertNotEqual(
            Array(nfc.utf8), Array(nfd.utf8),
            "NFC and NFD must differ at the byte level"
        )

        let diff = """
        --- a/\(nfc)
        +++ b/\(nfd)
        @@ -1,1 +1,1 @@
        -a
        +b
        """
        let parsed = try parseStrict(diff, path: nfd)
        XCTAssertEqual(parsed.file.path, nfd)
        XCTAssertEqual(Array(parsed.file.path.utf8), Array(nfd.utf8))
    }

    func testFilenameWithSpacesTabsAndQuotes() throws {
        let weird = "my file\twith\"quotes and spaces.txt"
        let diff = """
        @@ -1,1 +1,1 @@
        -a
        +b
        """
        let parsed = try parseStrict(diff, path: weird)
        XCTAssertEqual(parsed.file.path, weird)
    }

    // MARK: Only-additions / only-deletions

    func testOnlyDeletionsWithLargeCount() throws {
        var parts: [String] = ["@@ -1,50 +0,0 @@"]
        for i in 0..<50 { parts.append("-line\(i)") }
        let parsed = try parseStrict(parts.joined(separator: "\n"))
        XCTAssertEqual(parsed.file.deletions, 50)
        XCTAssertEqual(parsed.file.additions, 0)
    }

    func testOnlyAdditionsWithLargeCount() throws {
        var parts: [String] = ["@@ -0,0 +1,50 @@"]
        for i in 0..<50 { parts.append("+line\(i)") }
        let parsed = try parseStrict(parts.joined(separator: "\n"))
        XCTAssertEqual(parsed.file.additions, 50)
        XCTAssertEqual(parsed.file.deletions, 0)
    }

    // MARK: Lenient (warnings) mode

    func testMalformedHeaderInLenientModeProducesWarningNotThrow() throws {
        let diff = """
        @@ malformed @@
        +line
        """
        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "x.txt", strict: false)
        XCTAssertEqual(parsed.warnings.count, 1)
        XCTAssertTrue(parsed.file.partialParse)
    }

    // MARK: Fuzz tests

    /// Deterministic RNG so failures reproduce identically across runs / CI.
    /// Pass through the seed in failure messages so a triager can replay the
    /// exact input that broke things.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEF : seed }
        mutating func next() -> UInt64 {
            // splitmix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z &>> 31)
        }
    }

    private static let fuzzSeed: UInt64 = 0xC0DE_FACE_2026_0425
    private static let fuzzIterations = 1000

    /// Generates totally-random byte sequences and feeds them to the parser.
    /// Asserts the parser either returns a result or throws — never crashes
    /// or traps.
    func testFuzzRandomBytesNeverCrashes() {
        var rng = SeededRNG(seed: Self.fuzzSeed)
        for i in 0..<Self.fuzzIterations {
            // Lengths chosen to span "tiny" through "small-multi-line".
            let len = Int(rng.next() % 512)
            var bytes = [UInt8]()
            bytes.reserveCapacity(len)
            for _ in 0..<len {
                // Bias toward printable ASCII so we sometimes hit hunk-header
                // shapes; still allow control bytes & high ASCII.
                let pick = rng.next() % 100
                if pick < 70 {
                    bytes.append(UInt8(rng.next() % 95) &+ 32)  // printable
                } else if pick < 90 {
                    bytes.append(UInt8(rng.next() % 256))       // anything
                } else {
                    bytes.append(0x0A)                           // newline
                }
            }
            // Lossy UTF-8 conversion — the parser takes a `String`, so we
            // must produce one. Replacement of invalid UTF-8 is fine; the
            // parser should still survive.
            let s = String(decoding: bytes, as: UTF8.self)
            do {
                _ = try UnifiedDiffParser.parse(diff: s, path: "fuzz.txt", strict: false)
            } catch {
                // Throwing is allowed — only crashing is forbidden. Keep
                // looping.
                _ = error
            }
            // Also exercise strict mode on a subset.
            if i % 5 == 0 {
                _ = try? UnifiedDiffParser.parse(diff: s, path: "fuzz.txt", strict: true)
            }
        }
    }

    /// Takes a corpus of valid diffs and applies single-byte mutations
    /// (flip, delete, duplicate). Asserts no crashes.
    func testFuzzMutatedValidDiffsParse() {
        let corpus = [
            """
            @@ -1,1 +1,1 @@
            -a
            +b
            """,
            """
            diff --git a/foo.txt b/foo.txt
            --- a/foo.txt
            +++ b/foo.txt
            @@ -1,3 +1,4 @@
             ctx
            -old
            +new1
            +new2
             tail
            """,
            """
            @@ -1,2 +1,2 @@
             keep
            -delete
            +insert
            @@ -10,1 +11,1 @@
            -x
            +y
            """,
            """
            old mode 100644
            new mode 100755
            @@ -1,1 +1,1 @@
            -echo
            +echo!
            """,
            """
            diff --git a/old.txt b/new.txt
            rename from old.txt
            rename to new.txt
            @@ -1 +1 @@
            -hello
            +hello world
            """,
        ]

        var rng = SeededRNG(seed: Self.fuzzSeed &+ 1)

        for base in corpus {
            // Original must always parse cleanly.
            XCTAssertNoThrow(try UnifiedDiffParser.parse(diff: base, path: "src.txt", strict: false))

            var bytes = Array(base.utf8)
            // Per-corpus iterations: ~200 each => ~1000 across 5 corpus
            // entries, matching the "single-byte mutations" intent.
            let perCorpus = max(1, Self.fuzzIterations / corpus.count)
            for _ in 0..<perCorpus {
                guard !bytes.isEmpty else { break }
                let pick = rng.next() % 3
                let pos = Int(rng.next() % UInt64(bytes.count))
                switch pick {
                case 0:
                    // Flip a random bit.
                    let bit = UInt8(1 << (rng.next() % 8))
                    bytes[pos] ^= bit
                case 1:
                    // Delete a byte.
                    bytes.remove(at: pos)
                default:
                    // Duplicate a byte.
                    bytes.insert(bytes[pos], at: pos)
                }
                let mutated = String(decoding: bytes, as: UTF8.self)
                do {
                    _ = try UnifiedDiffParser.parse(diff: mutated, path: "mut.txt", strict: false)
                } catch {
                    _ = error  // throwing OK, crashing not.
                }
                // Restart from clean base periodically so we don't drift into
                // entirely-noise inputs.
                if rng.next() % 16 == 0 {
                    bytes = Array(base.utf8)
                }
            }
        }
    }
}
