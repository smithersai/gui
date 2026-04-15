import SwiftUI

// MARK: - Diff Parser

struct DiffLine: Identifiable {
    enum Kind { case context, addition, deletion, hunk, fileHeader }

    var id: String { "\(oldLineNum ?? 0):\(newLineNum ?? 0):\(kind):\(text.hashValue)" }
    let kind: Kind
    let text: String
    let oldLineNum: Int?
    let newLineNum: Int?
}

struct DiffFileSection: Identifiable {
    let id: String
    let fileName: String
    let status: FileStatus
    let lines: [DiffLine]

    enum FileStatus: String {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case unknown = "?"
    }
}

enum DiffParser {
    static func parse(_ raw: String) -> [DiffFileSection] {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let allLines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [DiffFileSection] = []
        var currentFileName = ""
        var currentStatus: DiffFileSection.FileStatus = .modified
        var currentLines: [DiffLine] = []
        var oldNum = 0
        var newNum = 0

        func flush() {
            if !currentFileName.isEmpty || !currentLines.isEmpty {
                let name = currentFileName.isEmpty ? "unknown" : currentFileName
                sections.append(DiffFileSection(
                    id: "\(currentStatus.rawValue):\(name)",
                    fileName: name,
                    status: currentStatus,
                    lines: currentLines
                ))
            }
            currentLines = []
        }

        for line in allLines {
            // diff --git header
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff ") {
                flush()
                // Extract filename from "diff --git a/foo b/foo"
                if let bRange = line.range(of: " b/", options: .backwards) {
                    currentFileName = String(line[bRange.upperBound...])
                } else {
                    currentFileName = String(line.dropFirst(11))
                }
                currentStatus = .modified
                continue
            }

            // --- and +++ file headers
            if line.hasPrefix("--- ") {
                if line.contains("/dev/null") { currentStatus = .added }
                continue
            }
            if line.hasPrefix("+++ ") {
                if line.contains("/dev/null") {
                    currentStatus = .deleted
                } else if currentStatus != .added {
                    // Extract name from "+++ b/filename"
                    if line.hasPrefix("+++ b/") {
                        currentFileName = String(line.dropFirst(6))
                    }
                }
                continue
            }

            // Rename / similarity headers
            if line.hasPrefix("rename ") || line.hasPrefix("similarity ") || line.hasPrefix("index ") ||
               line.hasPrefix("old mode") || line.hasPrefix("new mode") || line.hasPrefix("new file") ||
               line.hasPrefix("deleted file") {
                if line.hasPrefix("new file") { currentStatus = .added }
                if line.hasPrefix("deleted file") { currentStatus = .deleted }
                if line.hasPrefix("rename from") { currentStatus = .renamed }
                continue
            }

            // Hunk header
            if line.hasPrefix("@@") {
                // Parse @@ -old,count +new,count @@
                let parts = line.components(separatedBy: " ")
                if parts.count >= 3 {
                    let newPart = parts[2] // "+N" or "+N,M"
                    let oldPart = parts[1] // "-N" or "-N,M"
                    oldNum = abs(Int(oldPart.split(separator: ",").first.map(String.init) ?? "0") ?? 0)
                    newNum = abs(Int(newPart.split(separator: ",").first.map(String.init) ?? "0") ?? 0)
                }
                currentLines.append(DiffLine(kind: .hunk, text: line, oldLineNum: nil, newLineNum: nil))
                continue
            }

            // Diff content lines
            if line.hasPrefix("+") {
                currentLines.append(DiffLine(kind: .addition, text: String(line.dropFirst()), oldLineNum: nil, newLineNum: newNum))
                newNum += 1
            } else if line.hasPrefix("-") {
                currentLines.append(DiffLine(kind: .deletion, text: String(line.dropFirst()), oldLineNum: oldNum, newLineNum: nil))
                oldNum += 1
            } else if line.hasPrefix(" ") {
                currentLines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldLineNum: oldNum, newLineNum: newNum))
                oldNum += 1
                newNum += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — skip
                continue
            } else if sections.isEmpty && currentLines.isEmpty {
                // Not in a diff section yet — might be plain text diff output
                currentLines.append(DiffLine(kind: .context, text: line, oldLineNum: nil, newLineNum: nil))
            }
        }

        flush()
        return sections
    }
}

// MARK: - Unified Diff View

struct UnifiedDiffView: View {
    let diffText: String

    private var sections: [DiffFileSection] {
        DiffParser.parse(diffText)
    }

    var body: some View {
        let parsed = sections
        Group {
            if parsed.isEmpty {
                Text("(no changes)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 16) {
                    // Stats bar
                    diffStatsBar(parsed)

                    ForEach(parsed) { section in
                        fileSectionView(section)
                    }
                }
                .padding(16)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Stats

    private func diffStatsBar(_ sections: [DiffFileSection]) -> some View {
        let adds = sections.flatMap(\.lines).filter { $0.kind == .addition }.count
        let dels = sections.flatMap(\.lines).filter { $0.kind == .deletion }.count
        return HStack(spacing: 12) {
            Text("\(sections.count) file\(sections.count == 1 ? "" : "s") changed")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            if adds > 0 {
                Text("+\(adds)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.diffAddFg)
            }
            if dels > 0 {
                Text("-\(dels)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.diffDelFg)
            }
            Spacer()
        }
    }

    // MARK: - File Section

    private func fileSectionView(_ section: DiffFileSection) -> some View {
        VStack(spacing: 0) {
            // File header
            HStack(spacing: 8) {
                statusBadge(section.status)
                Text(section.fileName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.diffFileFg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                let adds = section.lines.filter { $0.kind == .addition }.count
                let dels = section.lines.filter { $0.kind == .deletion }.count
                if adds > 0 {
                    Text("+\(adds)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.diffAddFg)
                }
                if dels > 0 {
                    Text("-\(dels)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.diffDelFg)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.diffFileBg)

            // Diff lines
            VStack(spacing: 0) {
                ForEach(section.lines) { line in
                    diffLineView(line)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func statusBadge(_ status: DiffFileSection.FileStatus) -> some View {
        let (label, color): (String, Color) = switch status {
        case .added: ("A", Theme.diffAddFg)
        case .deleted: ("D", Theme.diffDelFg)
        case .modified: ("M", Theme.diffHunkFg)
        case .renamed: ("R", Theme.warning)
        case .unknown: ("?", Theme.textTertiary)
        }

        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    // MARK: - Diff Line

    private func diffLineView(_ line: DiffLine) -> some View {
        let (bg, fg): (Color, Color) = switch line.kind {
        case .addition: (Theme.diffAddBg, Theme.diffAddFg)
        case .deletion: (Theme.diffDelBg, Theme.diffDelFg)
        case .hunk: (Theme.diffHunkBg, Theme.diffHunkFg)
        case .context: (Color.clear, Theme.textPrimary.opacity(0.75))
        case .fileHeader: (Theme.diffFileBg, Theme.diffFileFg)
        }

        let prefix: String = switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .hunk: ""
        case .context: " "
        case .fileHeader: ""
        }

        return HStack(spacing: 0) {
            // Line numbers
            if line.kind == .hunk {
                Text("···")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.diffLineNum)
                    .frame(width: 80, alignment: .center)
            } else if line.kind != .fileHeader {
                HStack(spacing: 0) {
                    Text(line.oldLineNum.map { String($0) } ?? "")
                        .frame(width: 38, alignment: .trailing)
                    Text(line.newLineNum.map { String($0) } ?? "")
                        .frame(width: 38, alignment: .trailing)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.diffLineNum)
                .padding(.trailing, 4)
            }

            // Prefix glyph
            if !prefix.isEmpty {
                Text(prefix)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(fg)
                    .frame(width: 14)
            }

            // Content
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(fg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .background(bg)
        .textSelection(.enabled)
    }
}
