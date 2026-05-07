import XCTest
@testable import SmithersGUI

/// Property-based tests for ``UnifiedDiffParser``.
///
/// These tests generate hundreds of randomized-but-valid unified diffs and
/// assert structural invariants (roundtrip equality, idempotence, determinism,
/// order preservation, addition/deletion counts, etc.).
///
/// Notes on adapting the canonical 10 properties to this parser:
/// - The parser handles a single logical file at a time (it accepts a
///   `path:` argument and returns one ``UnifiedDiffFile``). "File order"
///   therefore translates to *hunk order* within a file. "Concatenation"
///   becomes: the hunks of `parse(a + "\n" + b)` equal `parse(a).hunks ++
///   parse(b).hunks`, modulo the normalized re-serialization both sides
///   share.
///
/// All tests use a single fixed seed so failures reproduce deterministically.
final class UnifiedDiffParserPropertyTests: XCTestCase {

    // MARK: - Deterministic RNG (splitmix64, same as edge-test suite)

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEF : seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z &>> 31)
        }

        mutating func nextInt(_ upper: Int) -> Int {
            precondition(upper > 0)
            return Int(next() % UInt64(upper))
        }
        mutating func nextBool() -> Bool { next() % 2 == 0 }
    }

    /// The seed is fixed across the suite; per-property RNGs derive from it.
    private static let propertySeed: UInt64 = 0x5EED_C0DE_2026_0425
    private static let iterations = 250

    // MARK: - Generators

    /// A single logical hunk used both for input synthesis and for round-trip
    /// equality. We deliberately keep the shape simple (no rename/binary
    /// metadata) so the input is always a valid strict-mode diff.
    private struct GenHunk: Equatable {
        let oldStart: Int
        let newStart: Int
        // Lines, in body order.
        let lines: [GenLine]
    }
    fileprivate enum GenLine: Equatable {
        case context(String)
        case addition(String)
        case deletion(String)

        /// Whether this line consumes an "old-side" line slot (deletions and
        /// contexts do; additions don't).
        var isOldVisible: Bool {
            switch self {
            case .deletion, .context: return true
            case .addition: return false
            }
        }
        /// Whether this line consumes a "new-side" line slot.
        var isNewVisible: Bool {
            switch self {
            case .addition, .context: return true
            case .deletion: return false
            }
        }
    }

    /// Generate a small printable ASCII string (no leading +/-/space, no
    /// newline) so it round-trips faithfully through a unified-diff body.
    private static func genText(_ rng: inout SeededRNG, maxLen: Int = 24) -> String {
        let len = rng.nextInt(maxLen) + 1
        var out = String()
        out.reserveCapacity(len)
        for _ in 0..<len {
            // Printable ASCII 0x21..0x7E (skip 0x20 space — we'll re-add
            // mid-string only) plus selective punctuation. We avoid leading
            // whitespace/+/- because those are the diff body sigils.
            let pick = rng.nextInt(64)
            let ch: Character
            if pick < 26 { ch = Character(UnicodeScalar(0x61 + pick)!) }            // a-z
            else if pick < 52 { ch = Character(UnicodeScalar(0x41 + (pick - 26))!) } // A-Z
            else if pick < 62 { ch = Character(UnicodeScalar(0x30 + (pick - 52))!) } // 0-9
            else if pick == 62 { ch = "_" }
            else { ch = "." }
            out.append(ch)
        }
        return out
    }

    private static func genHunk(_ rng: inout SeededRNG, oldStart: Int, newStart: Int) -> GenHunk {
        let lineCount = rng.nextInt(6) + 1   // 1..6 lines
        var lines: [GenLine] = []
        lines.reserveCapacity(lineCount)
        for _ in 0..<lineCount {
            let kind = rng.nextInt(3)
            let text = genText(&rng)
            switch kind {
            case 0: lines.append(.context(text))
            case 1: lines.append(.addition(text))
            default: lines.append(.deletion(text))
            }
        }
        return GenHunk(oldStart: oldStart, newStart: newStart, lines: lines)
    }

    /// Synthesize a list of hunks with strictly-increasing, non-overlapping
    /// start positions so the resulting diff is unambiguous.
    private static func genHunks(_ rng: inout SeededRNG, count: Int) -> [GenHunk] {
        var hunks: [GenHunk] = []
        var oldCursor = 1
        var newCursor = 1
        for _ in 0..<count {
            let h = genHunk(&rng, oldStart: oldCursor, newStart: newCursor)
            hunks.append(h)
            // Advance cursors past this hunk's footprint plus a gap so the
            // next hunk is a separate one.
            let oldUsed = h.lines.reduce(0) { $0 + ($1.isOldVisible ? 1 : 0) }
            let newUsed = h.lines.reduce(0) { $0 + ($1.isNewVisible ? 1 : 0) }
            oldCursor += max(oldUsed, 1) + rng.nextInt(4) + 1
            newCursor += max(newUsed, 1) + rng.nextInt(4) + 1
        }
        return hunks
    }

    /// Render a single generated hunk into unified-diff text with explicit
    /// `oldCount,newCount` so the parser doesn't need to fall back to the
    /// implicit `=1` default.
    private static func renderHunk(_ h: GenHunk) -> String {
        let oldCount = h.lines.reduce(0) { $0 + ($1.isOldVisible ? 1 : 0) }
        let newCount = h.lines.reduce(0) { $0 + ($1.isNewVisible ? 1 : 0) }
        var out = "@@ -\(h.oldStart),\(oldCount) +\(h.newStart),\(newCount) @@"
        for line in h.lines {
            switch line {
            case .context(let t):  out += "\n " + t
            case .addition(let t): out += "\n+" + t
            case .deletion(let t): out += "\n-" + t
            }
        }
        return out
    }

    private static func renderDiff(_ hunks: [GenHunk]) -> String {
        hunks.map(renderHunk).joined(separator: "\n")
    }

    // MARK: - Normalized re-serialization (used by roundtrip property)

    /// Serialize a parsed ``UnifiedDiffFile`` back to a canonical string.
    ///
    /// Two diffs that parse to the same file should serialize byte-for-byte
    /// identically. This is the canonicalizer the round-trip property uses.
    private static func serialize(_ file: UnifiedDiffFile) -> String {
        var parts: [String] = []
        for hunk in file.hunks {
            // Recompute counts from the line list rather than trusting the
            // header's stated counts — this is what makes serialization
            // canonical (a malformed `@@ -1,5 +1,5 @@` with only 3 body
            // lines re-serializes with `,3 ,3` and the round-trip stabilises).
            let oldCount = hunk.lines.reduce(0) { $0 + ($1.kind == .deletion || $1.kind == .context ? 1 : 0) }
            let newCount = hunk.lines.reduce(0) { $0 + ($1.kind == .addition || $1.kind == .context ? 1 : 0) }
            parts.append("@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@")
            for line in hunk.lines {
                switch line.kind {
                case .context:  parts.append(" "  + line.text)
                case .addition: parts.append("+" + line.text)
                case .deletion: parts.append("-" + line.text)
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Properties

    /// Property 1 — Roundtrip: random valid diff → parse → reserialize →
    /// parse → assert equal hunk structure.
    func testProperty1_Roundtrip() throws {
        var rng = SeededRNG(seed: Self.propertySeed)
        for i in 0..<Self.iterations {
            let hunkCount = rng.nextInt(4) + 1
            let hunks = Self.genHunks(&rng, count: hunkCount)
            let diff = Self.renderDiff(hunks)

            let first = try UnifiedDiffParser.parse(diff: diff, path: "rt.txt", strict: true)
            let serialized = Self.serialize(first.file)
            let second = try UnifiedDiffParser.parse(diff: serialized, path: "rt.txt", strict: true)

            // The parsed structure must survive the reserialize-then-reparse
            // cycle exactly (modulo header-text differences which are why we
            // compare via hunkSignature).
            XCTAssertEqual(
                Self.hunkSignature(first.file),
                Self.hunkSignature(second.file),
                "Roundtrip mismatch on iteration \(i) (seed \(Self.propertySeed)). diff:\n\(diff)"
            )
        }
    }

    /// Property 2 — Idempotence: parsing the same input twice yields equal
    /// results.
    func testProperty2_Idempotence() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 2)
        for i in 0..<Self.iterations {
            let hunks = Self.genHunks(&rng, count: rng.nextInt(4) + 1)
            let diff = Self.renderDiff(hunks)
            let a = try UnifiedDiffParser.parse(diff: diff, path: "idem.txt", strict: true)
            let b = try UnifiedDiffParser.parse(diff: diff, path: "idem.txt", strict: true)
            XCTAssertEqual(a, b, "Idempotence failed on iteration \(i)")
        }
    }

    /// Property 3 — Determinism: the same input across separate parser
    /// invocations always returns identical bytes when serialized.
    func testProperty3_Determinism() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 3)
        for i in 0..<Self.iterations {
            let hunks = Self.genHunks(&rng, count: rng.nextInt(4) + 1)
            let diff = Self.renderDiff(hunks)
            let a = try UnifiedDiffParser.parse(diff: diff, path: "det.txt", strict: true)
            let b = try UnifiedDiffParser.parse(diff: diff, path: "det.txt", strict: true)
            let c = try UnifiedDiffParser.parse(diff: diff, path: "det.txt", strict: true)
            XCTAssertEqual(Self.serialize(a.file), Self.serialize(b.file), "Run 1 != Run 2 at iter \(i)")
            XCTAssertEqual(Self.serialize(b.file), Self.serialize(c.file), "Run 2 != Run 3 at iter \(i)")
        }
    }

    /// Property 4 — Order preservation: the order of hunks in the input is
    /// preserved in the output. (The single-file parser doesn't have multiple
    /// files to order, so we check hunk ordering instead — which is the
    /// semantically equivalent invariant.)
    func testProperty4_OrderPreservation() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 4)
        for i in 0..<Self.iterations {
            let hunks = Self.genHunks(&rng, count: rng.nextInt(5) + 2) // ≥2 to be meaningful
            let diff = Self.renderDiff(hunks)
            let parsed = try UnifiedDiffParser.parse(diff: diff, path: "ord.txt", strict: true)
            XCTAssertEqual(
                parsed.file.hunks.count, hunks.count,
                "Hunk count drift on iteration \(i)"
            )
            // oldStart values are strictly increasing in the generator, so
            // they pin down the order.
            let inputStarts = hunks.map(\.oldStart)
            let outputStarts = parsed.file.hunks.map(\.oldStart)
            XCTAssertEqual(inputStarts, outputStarts, "Hunk order changed at iter \(i)")
        }
    }

    /// Property 5 — Hunk count consistency: the line counts the parser
    /// stores in the hunk header (oldCount/newCount) match the actual
    /// number of '-'+' ' / '+'+' ' body lines respectively.
    func testProperty5_HunkCountConsistency() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 5)
        for i in 0..<Self.iterations {
            let hunks = Self.genHunks(&rng, count: rng.nextInt(4) + 1)
            let diff = Self.renderDiff(hunks)
            let parsed = try UnifiedDiffParser.parse(diff: diff, path: "cnt.txt", strict: true)
            for (j, hunk) in parsed.file.hunks.enumerated() {
                let actualOld = hunk.lines.filter { $0.kind == .deletion || $0.kind == .context }.count
                let actualNew = hunk.lines.filter { $0.kind == .addition || $0.kind == .context }.count
                XCTAssertEqual(hunk.oldCount, actualOld, "iter \(i) hunk \(j): oldCount mismatch")
                XCTAssertEqual(hunk.newCount, actualNew, "iter \(i) hunk \(j): newCount mismatch")
            }
        }
    }

    /// Property 6 — No content drift: N additions and M deletions in the
    /// source must yield exactly N additions and M deletions out.
    func testProperty6_AdditionDeletionCountsExact() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 6)
        for i in 0..<Self.iterations {
            let hunks = Self.genHunks(&rng, count: rng.nextInt(4) + 1)
            let inputAdds = hunks.flatMap(\.lines).filter { if case .addition = $0 { return true } else { return false } }.count
            let inputDels = hunks.flatMap(\.lines).filter { if case .deletion = $0 { return true } else { return false } }.count

            let diff = Self.renderDiff(hunks)
            let parsed = try UnifiedDiffParser.parse(diff: diff, path: "ad.txt", strict: true)

            XCTAssertEqual(parsed.file.additions, inputAdds, "iter \(i): addition drift")
            XCTAssertEqual(parsed.file.deletions, inputDels, "iter \(i): deletion drift")
        }
    }

    /// Property 7 — Filename preservation: a randomized ASCII filename
    /// (including spaces, dots, dashes, underscores) survives the parse.
    func testProperty7_FilenamePreservation() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 7)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.")
        for i in 0..<Self.iterations {
            let len = rng.nextInt(40) + 1
            var name = ""
            for _ in 0..<len {
                name.append(alphabet[rng.nextInt(alphabet.count)])
            }
            // Avoid leading/trailing whitespace because some downstream
            // git tooling trims it (and the parser just stores the string,
            // but path lookups would diverge); generators in the wild
            // wouldn't emit those either.
            name = name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "x.txt" }

            let hunks = Self.genHunks(&rng, count: 1)
            let diff = Self.renderDiff(hunks)
            let parsed = try UnifiedDiffParser.parse(diff: diff, path: name, strict: true)
            XCTAssertEqual(parsed.file.path, name, "iter \(i): filename mutated")
        }
    }

    /// Property 8 — Empty-diff invariant: empty input yields an empty hunk
    /// list (which is the single-file analogue of "empty file list").
    func testProperty8_EmptyDiffInvariant() throws {
        // Run many empty / whitespace-only inputs to confirm stability.
        var rng = SeededRNG(seed: Self.propertySeed &+ 8)
        let candidates: [() -> String] = [
            { "" },
            { "\n" },
            { "\n\n\n" },
            { "   " },
            { "\t\t" },
            { "\r\n\r\n" },
        ]
        for i in 0..<Self.iterations {
            let s = candidates[rng.nextInt(candidates.count)]()
            let parsed = try UnifiedDiffParser.parse(diff: s, path: "empty.txt", strict: true)
            XCTAssertEqual(parsed.file.hunks.count, 0, "iter \(i): non-empty hunks for empty input \(s.debugDescription)")
            XCTAssertEqual(parsed.file.additions, 0)
            XCTAssertEqual(parsed.file.deletions, 0)
            XCTAssertFalse(parsed.file.partialParse)
        }
    }

    /// Property 9 — Single-line invariant: one hunk with exactly one added
    /// line yields one file, one hunk, one addition (and zero deletions /
    /// zero contexts).
    func testProperty9_SingleAddedLineInvariant() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 9)
        for i in 0..<Self.iterations {
            let text = Self.genText(&rng)
            let oldStart = rng.nextInt(1_000) + 1
            let newStart = rng.nextInt(1_000) + 1
            let diff = "@@ -\(oldStart),0 +\(newStart),1 @@\n+\(text)"
            let parsed = try UnifiedDiffParser.parse(diff: diff, path: "one.txt", strict: true)
            XCTAssertEqual(parsed.file.hunks.count, 1, "iter \(i): hunk count")
            let hunk = try XCTUnwrap(parsed.file.hunks.first)
            XCTAssertEqual(hunk.lines.count, 1, "iter \(i): line count")
            XCTAssertEqual(hunk.lines.first?.kind, .addition, "iter \(i): kind")
            XCTAssertEqual(hunk.lines.first?.text, text, "iter \(i): text fidelity")
            XCTAssertEqual(parsed.file.additions, 1)
            XCTAssertEqual(parsed.file.deletions, 0)
        }
    }

    /// Property 10 — Concatenation: the hunks of `parse(a + "\n" + b)`
    /// equal `parse(a).hunks ++ parse(b).hunks` (modulo header-string
    /// canonicalisation).
    ///
    /// We compare via the canonical serialization: serialize(parse(combined))
    /// must equal serialize(parse(a)) + "\n" + serialize(parse(b)).
    func testProperty10_Concatenation() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 10)
        for i in 0..<Self.iterations {
            // Generate two non-overlapping hunk streams. Use disjoint line
            // ranges by giving `b` a large oldStart cursor offset.
            let aHunks = Self.genHunks(&rng, count: rng.nextInt(3) + 1)
            var bRng = SeededRNG(seed: Self.propertySeed &+ 100 &+ UInt64(i))
            let bRaw = Self.genHunks(&bRng, count: rng.nextInt(3) + 1)
            // Shift `b` past `a` so we don't generate two hunks at the same
            // start line (which would still parse but is semantically odd).
            let bShift = (aHunks.last.map { $0.oldStart + 100 } ?? 1)
            let bHunks: [GenHunk] = bRaw.map { h in
                GenHunk(oldStart: h.oldStart + bShift, newStart: h.newStart + bShift, lines: h.lines)
            }

            let aDiff = Self.renderDiff(aHunks)
            let bDiff = Self.renderDiff(bHunks)
            let combined = aDiff + "\n" + bDiff

            let parsedA = try UnifiedDiffParser.parse(diff: aDiff, path: "ab.txt", strict: true)
            let parsedB = try UnifiedDiffParser.parse(diff: bDiff, path: "ab.txt", strict: true)
            let parsedC = try UnifiedDiffParser.parse(diff: combined, path: "ab.txt", strict: true)

            // 10.a — total hunk count is additive.
            XCTAssertEqual(
                parsedC.file.hunks.count,
                parsedA.file.hunks.count + parsedB.file.hunks.count,
                "iter \(i): concat hunk count"
            )
            // 10.b — total adds/dels are additive.
            XCTAssertEqual(parsedC.file.additions, parsedA.file.additions + parsedB.file.additions)
            XCTAssertEqual(parsedC.file.deletions, parsedA.file.deletions + parsedB.file.deletions)
            // 10.c — canonical serialization is concatenated.
            let expected = Self.serialize(parsedA.file) + "\n" + Self.serialize(parsedB.file)
            XCTAssertEqual(
                Self.serialize(parsedC.file), expected,
                "iter \(i): concat serialization"
            )
        }
    }

    // MARK: - Bonus properties

    /// Property 11 — Line-text fidelity: every body line's `text` field
    /// matches the input text byte-for-byte (no leading-sigil bleed).
    func testProperty11_LineTextFidelity() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 11)
        for i in 0..<Self.iterations {
            let hunks = Self.genHunks(&rng, count: rng.nextInt(4) + 1)
            let diff = Self.renderDiff(hunks)
            let parsed = try UnifiedDiffParser.parse(diff: diff, path: "fid.txt", strict: true)
            // Flatten input lines and compare in body order.
            let inputLines = hunks.flatMap(\.lines)
            let outputLines = parsed.file.hunks.flatMap(\.lines)
            XCTAssertEqual(inputLines.count, outputLines.count, "iter \(i): line count")
            for (idx, pair) in zip(inputLines, outputLines).enumerated() {
                let (gen, parsed) = pair
                switch gen {
                case .context(let t):
                    XCTAssertEqual(parsed.kind, .context, "iter \(i) line \(idx): kind")
                    XCTAssertEqual(parsed.text, t, "iter \(i) line \(idx): text")
                case .addition(let t):
                    XCTAssertEqual(parsed.kind, .addition, "iter \(i) line \(idx): kind")
                    XCTAssertEqual(parsed.text, t, "iter \(i) line \(idx): text")
                case .deletion(let t):
                    XCTAssertEqual(parsed.kind, .deletion, "iter \(i) line \(idx): kind")
                    XCTAssertEqual(parsed.text, t, "iter \(i) line \(idx): text")
                }
            }
        }
    }

    /// Property 12 — Line numbering: addition lines have `newLineNumber !=
    /// nil && oldLineNumber == nil`; deletion lines vice versa; context has
    /// both. The numbering is monotonically non-decreasing within a hunk.
    func testProperty12_LineNumberingShape() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 12)
        for i in 0..<Self.iterations {
            let hunks = Self.genHunks(&rng, count: rng.nextInt(3) + 1)
            let diff = Self.renderDiff(hunks)
            let parsed = try UnifiedDiffParser.parse(diff: diff, path: "lnum.txt", strict: true)
            for (h, hunk) in parsed.file.hunks.enumerated() {
                var lastOld = Int.min
                var lastNew = Int.min
                for (j, line) in hunk.lines.enumerated() {
                    switch line.kind {
                    case .addition:
                        XCTAssertNil(line.oldLineNumber, "iter \(i) h\(h) l\(j): add has oldLineNumber")
                        XCTAssertNotNil(line.newLineNumber, "iter \(i) h\(h) l\(j): add missing newLineNumber")
                        if let n = line.newLineNumber { XCTAssertGreaterThanOrEqual(n, lastNew); lastNew = n }
                    case .deletion:
                        XCTAssertNotNil(line.oldLineNumber, "iter \(i) h\(h) l\(j): del missing oldLineNumber")
                        XCTAssertNil(line.newLineNumber, "iter \(i) h\(h) l\(j): del has newLineNumber")
                        if let n = line.oldLineNumber { XCTAssertGreaterThanOrEqual(n, lastOld); lastOld = n }
                    case .context:
                        XCTAssertNotNil(line.oldLineNumber)
                        XCTAssertNotNil(line.newLineNumber)
                        if let o = line.oldLineNumber { XCTAssertGreaterThanOrEqual(o, lastOld); lastOld = o }
                        if let n = line.newLineNumber { XCTAssertGreaterThanOrEqual(n, lastNew); lastNew = n }
                    }
                }
            }
        }
    }

    /// Property 13 — CRLF normalization is invisible: parsing the same diff
    /// with LF and with CRLF yields equal results.
    func testProperty13_CRLFNormalizationStability() throws {
        var rng = SeededRNG(seed: Self.propertySeed &+ 13)
        for i in 0..<Self.iterations {
            let hunks = Self.genHunks(&rng, count: rng.nextInt(3) + 1)
            let lf = Self.renderDiff(hunks)
            let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
            let a = try UnifiedDiffParser.parse(diff: lf, path: "lf.txt", strict: true)
            let b = try UnifiedDiffParser.parse(diff: crlf, path: "lf.txt", strict: true)
            XCTAssertEqual(Self.serialize(a.file), Self.serialize(b.file), "iter \(i): CRLF mismatch")
        }
    }

    // MARK: - Helpers

    /// A signature that captures everything we care about for round-trip
    /// equality but ignores details that the canonical serializer normalises
    /// away (e.g. the original `header` text or the parser's auto-incremented
    /// line numbers, which the serializer recomputes from `oldStart` /
    /// `newStart`).
    private static func hunkSignature(_ file: UnifiedDiffFile) -> String {
        return serialize(file)
    }
}

