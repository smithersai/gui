import SwiftUI

struct DiffFileView: View {
    static let collapseForLargeFileThreshold = 2_000
    static let initialRenderedLinesForLargeFile = 1_000

    let file: UnifiedDiffFile
    @Binding var isExpanded: Bool

    @State private var showRemainingLines = false

    private var totalRenderedLines: Int {
        file.renderedLineCount
    }

    private var shouldPaginate: Bool {
        totalRenderedLines > Self.collapseForLargeFileThreshold
    }

    private var visibleLineCount: Int {
        if showRemainingLines || !shouldPaginate {
            return totalRenderedLines
        }
        return Self.initialRenderedLinesForLargeFile
    }

    private var paginationRemainder: Int {
        max(0, totalRenderedLines - visibleLineCount)
    }

    private var displayedHunks: [UnifiedDiffHunk] {
        guard !file.isBinary else { return [] }
        if showRemainingLines || !shouldPaginate {
            return file.hunks
        }

        var remaining = visibleLineCount
        var trimmed: [UnifiedDiffHunk] = []

        for hunk in file.hunks {
            guard remaining > 0 else { break }
            if hunk.lines.count <= remaining {
                trimmed.append(hunk)
                remaining -= hunk.lines.count
                continue
            }

            let partialLines = Array(hunk.lines.prefix(remaining))
            trimmed.append(UnifiedDiffHunk(
                oldStart: hunk.oldStart,
                oldCount: hunk.oldCount,
                newStart: hunk.newStart,
                newCount: hunk.newCount,
                header: hunk.header,
                lines: partialLines
            ))
            remaining = 0
        }

        return trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                bodyContent
            }
        }
        .background(Theme.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("diffFile.section.\(safeAccessibilityID(file.id))")
        .onChange(of: file.id) { _ in
            showRemainingLines = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textTertiary)

                    statusBadge

                    Text(file.path)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.diffFileFg)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if file.status == .renamed, let oldPath = file.oldPath, !oldPath.isEmpty {
                        Text("(from \(oldPath))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diffFile.toggle.\(safeAccessibilityID(file.id))")

            Spacer()

            if file.isBinary {
                Text("Binary")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.warning)
                    .accessibilityIdentifier("diffFile.binaryBadge.\(safeAccessibilityID(file.id))")
            }

            if file.additions > 0 {
                Text("+\(file.additions)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.diffAddFg)
            }
            if file.deletions > 0 {
                Text("-\(file.deletions)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.diffDelFg)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.diffFileBg)
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if file.status == .deleted {
                Text("File deleted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.diffDelFg)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            } else if file.status == .added {
                Text("New file")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.diffAddFg)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }

            if file.partialParse {
                Text("Partial parse: some hunks could not be rendered.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.warning)
                    .padding(.horizontal, 10)
            }

            if !file.modeChanges.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(file.modeChanges, id: \.self) { modeLine in
                        Text(modeLine)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 10)
            }

            if file.isBinary {
                binaryBody
            } else {
                ForEach(displayedHunks) { hunk in
                    DiffHunkView(hunk: hunk)
                }

                if shouldPaginate && paginationRemainder > 0 {
                    Button("Expand remaining \(paginationRemainder) lines") {
                        showRemainingLines = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("diffFile.expandRemaining.\(safeAccessibilityID(file.id))")
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var statusBadge: some View {
        let style: (label: String, color: Color) = {
            switch file.status {
            case .added:
                return ("A", Theme.diffAddFg)
            case .modified:
                return ("M", Theme.diffHunkFg)
            case .deleted:
                return ("D", Theme.diffDelFg)
            case .renamed:
                return ("R", Theme.warning)
            case .unknown:
                return ("?", Theme.textTertiary)
            }
        }()

        return Text(style.label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(style.color)
            .frame(width: 18, height: 18)
            .background(style.color.opacity(0.16))
            .cornerRadius(4)
            .accessibilityIdentifier("diffFile.status.\(safeAccessibilityID(file.id))")
    }

    private var binaryBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 11))
                .foregroundColor(Theme.warning)

            if let binarySize = file.binarySizeBytes {
                Text("Binary file (\(byteCountString(binarySize)))")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else {
                Text("Binary file")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
    }

    private func byteCountString(_ bytes: Int) -> String {
        if bytes < 1_024 {
            return "\(bytes) B"
        }
        if bytes < 1_024 * 1_024 {
            return "\(bytes / 1_024) KB"
        }
        return "\(bytes / (1_024 * 1_024)) MB"
    }

    private func safeAccessibilityID(_ raw: String) -> String {
        raw.map { character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "_"
        }
        .reduce(into: "") { partial, character in
            partial.append(character)
        }
    }
}
