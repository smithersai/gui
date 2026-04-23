import Foundation

/// Loader for the checked-in readable VT fixture format.
///
/// Format rules:
///   - Lines beginning with `#` (after optional leading whitespace) are comments
///     and skipped entirely (including their terminating newline).
///   - Blank lines are also skipped.
///   - In all other lines, the two-character sequences below are decoded:
///       \e   -> 0x1B (ESC)
///       \r   -> 0x0D (CR)
///       \n   -> 0x0A (LF)
///       \\   -> 0x5C (literal backslash)
///   - Everything else is emitted as its UTF-8 bytes.
///   - The trailing LF from each non-skipped source line is NOT re-emitted
///     (because fixtures explicitly include \r\n where they want one).
///
/// This keeps the fixture human-readable in git diffs while still producing
/// a precise deterministic byte stream at replay time.
public enum VTFixtureLoader {
    public static func decode(_ source: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(source.utf8.count)

        for line in source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.isEmpty { continue }
            if trimmed.first == "#" { continue }

            var it = line.makeIterator()
            while let ch = it.next() {
                if ch == "\\" {
                    guard let esc = it.next() else {
                        // trailing backslash — emit as-is
                        out.append(0x5C); continue
                    }
                    switch esc {
                    case "e":  out.append(0x1B)
                    case "r":  out.append(0x0D)
                    case "n":  out.append(0x0A)
                    case "\\": out.append(0x5C)
                    default:
                        // unknown escape — emit literal backslash + char
                        out.append(0x5C)
                        for b in String(esc).utf8 { out.append(b) }
                    }
                } else {
                    for b in String(ch).utf8 { out.append(b) }
                }
            }
        }
        return out
    }

    public static func decode(contentsOf url: URL) throws -> [UInt8] {
        let src = try String(contentsOf: url, encoding: .utf8)
        return decode(src)
    }
}
