import Foundation

enum DiffParseError: Error, Equatable {
    case malformedHunkHeader(line: Int, header: String)
}

struct UnifiedDiffParseWarning: Equatable, Sendable {
    let line: Int
    let header: String
}

enum UnifiedDiffFileStatus: String, Equatable, Sendable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case unknown = "?"
}

struct UnifiedDiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case context
        case addition
        case deletion
    }

    let kind: Kind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    var id: String {
        "\(oldLineNumber ?? -1):\(newLineNumber ?? -1):\(kind):\(text.hashValue)"
    }
}

struct UnifiedDiffHunk: Identifiable, Equatable, Sendable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let header: String
    let lines: [UnifiedDiffLine]

    var id: String {
        "\(oldStart),\(oldCount)->\(newStart),\(newCount):\(header.hashValue)"
    }
}

struct UnifiedDiffFile: Identifiable, Equatable, Sendable {
    let path: String
    let oldPath: String?
    let status: UnifiedDiffFileStatus
    let modeChanges: [String]
    let isBinary: Bool
    let binarySizeBytes: Int?
    let hunks: [UnifiedDiffHunk]
    let partialParse: Bool

    var id: String {
        if let oldPath, !oldPath.isEmpty, oldPath != path {
            return "\(oldPath)->\(path)"
        }
        return path
    }

    var additions: Int {
        hunks.reduce(0) { partial, hunk in
            partial + hunk.lines.reduce(0) { subtotal, line in
                subtotal + (line.kind == .addition ? 1 : 0)
            }
        }
    }

    var deletions: Int {
        hunks.reduce(0) { partial, hunk in
            partial + hunk.lines.reduce(0) { subtotal, line in
                subtotal + (line.kind == .deletion ? 1 : 0)
            }
        }
    }

    var renderedLineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count }
    }
}

struct UnifiedDiffParseResult: Equatable, Sendable {
    let file: UnifiedDiffFile
    let warnings: [UnifiedDiffParseWarning]
}

enum UnifiedDiffParser {
    static func parse(
        diff: String,
        path: String = "unknown",
        operation: NodeDiffPatch.Operation = .modify,
        oldPath: String? = nil,
        isBinary: Bool = false,
        binarySizeBytes: Int? = nil,
        strict: Bool = true
    ) throws -> UnifiedDiffParseResult {
        let binaryContent: String? = {
            if let binarySizeBytes, binarySizeBytes > 0 {
                return String(repeating: "A", count: binarySizeBytes)
            }
            return isBinary ? "AA==" : nil
        }()

        let patch = NodeDiffPatch(
            path: path,
            oldPath: oldPath,
            operation: operation,
            diff: diff,
            binaryContent: binaryContent
        )

        return try parse(patch: patch, strict: strict)
    }

    static func parse(patch: NodeDiffPatch, strict: Bool = true) throws -> UnifiedDiffParseResult {
        let normalizedDiff = normalizeLineEndings(in: patch.diff)
        let lines = normalizedDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var warnings: [UnifiedDiffParseWarning] = []
        var modeChanges: [String] = []
        var hunks: [UnifiedDiffHunk] = []

        var renameFrom: String? = patch.oldPath
        var renameTo: String?

        var inferredOldPath: String? = patch.oldPath
        var inferredNewPath: String = patch.path
        var status = status(from: patch.operation)
        var sawBinaryMarker = patch.isBinary

        var currentHunkMeta: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String)?
        var currentHunkLines: [UnifiedDiffLine] = []
        var oldLine = 0
        var newLine = 0

        func flushCurrentHunk() {
            guard let meta = currentHunkMeta else { return }
            hunks.append(UnifiedDiffHunk(
                oldStart: meta.oldStart,
                oldCount: meta.oldCount,
                newStart: meta.newStart,
                newCount: meta.newCount,
                header: meta.header,
                lines: currentHunkLines
            ))
            currentHunkMeta = nil
            currentHunkLines = []
        }

        for (zeroIndex, line) in lines.enumerated() {
            let lineNumber = zeroIndex + 1

            if line.hasPrefix("diff --git ") || line.hasPrefix("index ") || line.hasPrefix("similarity index ") {
                continue
            }

            if line.hasPrefix("rename from ") {
                renameFrom = String(line.dropFirst("rename from ".count))
                status = .renamed
                continue
            }
            if line.hasPrefix("rename to ") {
                renameTo = String(line.dropFirst("rename to ".count))
                inferredNewPath = renameTo ?? inferredNewPath
                status = .renamed
                continue
            }

            if line.hasPrefix("old mode ") || line.hasPrefix("new mode ") {
                modeChanges.append(line)
                continue
            }

            if line.hasPrefix("new file mode ") {
                status = .added
                continue
            }
            if line.hasPrefix("deleted file mode ") {
                status = .deleted
                continue
            }

            if line.hasPrefix("--- ") {
                let parsed = parsePathHeader(line, prefix: "--- ")
                if parsed == "/dev/null" {
                    status = .added
                    inferredOldPath = nil
                } else {
                    inferredOldPath = parsed
                }
                continue
            }
            if line.hasPrefix("+++ ") {
                let parsed = parsePathHeader(line, prefix: "+++ ")
                if parsed == "/dev/null" {
                    status = .deleted
                } else {
                    inferredNewPath = parsed
                }
                continue
            }

            if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                sawBinaryMarker = true
                continue
            }

            if line.hasPrefix("\\ No newline at end of file") {
                continue
            }

            if line.hasPrefix("@@") {
                flushCurrentHunk()
                guard let header = parseHunkHeader(line) else {
                    if strict {
                        throw DiffParseError.malformedHunkHeader(line: lineNumber, header: line)
                    }
                    warnings.append(UnifiedDiffParseWarning(line: lineNumber, header: line))
                    continue
                }
                currentHunkMeta = (
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    header: line
                )
                oldLine = header.oldStart
                newLine = header.newStart
                continue
            }

            guard currentHunkMeta != nil else {
                continue
            }

            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                currentHunkLines.append(UnifiedDiffLine(
                    kind: .addition,
                    text: String(line.dropFirst()),
                    oldLineNumber: nil,
                    newLineNumber: newLine
                ))
                newLine += 1
                continue
            }

            if line.hasPrefix("-") && !line.hasPrefix("---") {
                currentHunkLines.append(UnifiedDiffLine(
                    kind: .deletion,
                    text: String(line.dropFirst()),
                    oldLineNumber: oldLine,
                    newLineNumber: nil
                ))
                oldLine += 1
                continue
            }

            if line.hasPrefix(" ") {
                currentHunkLines.append(UnifiedDiffLine(
                    kind: .context,
                    text: String(line.dropFirst()),
                    oldLineNumber: oldLine,
                    newLineNumber: newLine
                ))
                oldLine += 1
                newLine += 1
                continue
            }

            // Blank lines are not valid unified-diff body lines by themselves
            // (empty context is encoded as a single leading space), so ignore.
            if line.isEmpty {
                continue
            }

            // Fallback for malformed-but-recoverable context lines.
            currentHunkLines.append(UnifiedDiffLine(
                kind: .context,
                text: line,
                oldLineNumber: oldLine,
                newLineNumber: newLine
            ))
            oldLine += 1
            newLine += 1
        }

        flushCurrentHunk()

        let path = renameTo ?? inferredNewPath
        let oldPath = renameFrom ?? inferredOldPath

        let file = UnifiedDiffFile(
            path: path,
            oldPath: oldPath,
            status: status,
            modeChanges: modeChanges,
            isBinary: sawBinaryMarker,
            binarySizeBytes: patch.binarySizeBytes,
            hunks: hunks,
            partialParse: !warnings.isEmpty
        )

        return UnifiedDiffParseResult(file: file, warnings: warnings)
    }

    private static func normalizeLineEndings(in value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func status(from operation: NodeDiffPatch.Operation) -> UnifiedDiffFileStatus {
        switch operation {
        case .add: return .added
        case .modify: return .modified
        case .delete: return .deleted
        case .rename: return .renamed
        case .unknown: return .unknown
        }
    }

    private static func parsePathHeader(_ line: String, prefix: String) -> String {
        var raw = String(line.dropFirst(prefix.count))
        if raw.hasPrefix("a/") || raw.hasPrefix("b/") {
            raw.removeFirst(2)
        }
        return raw
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        func intValue(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: line) else {
                return nil
            }
            return Int(line[swiftRange])
        }

        guard let oldStart = intValue(1), let newStart = intValue(3) else {
            return nil
        }
        let oldCount = intValue(2) ?? 1
        let newCount = intValue(4) ?? 1
        return (oldStart, oldCount, newStart, newCount)
    }
}
