import SwiftUI

struct DiffHunkView: View {
    let hunk: UnifiedDiffHunk

    var body: some View {
        VStack(spacing: 0) {
            hunkHeader
            ForEach(hunk.lines) { line in
                diffLineRow(line)
            }
        }
        .textSelection(.enabled)
    }

    private var hunkHeader: some View {
        HStack(spacing: 0) {
            Text("···")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.diffLineNum)
                .frame(width: 68, alignment: .center)

            ScrollView(.horizontal) {
                Text(hunk.header)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.diffHunkFg)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .padding(.leading, 4)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(Theme.diffHunkBg)
    }

    @ViewBuilder
    private func diffLineRow(_ line: UnifiedDiffLine) -> some View {
        let style = style(for: line.kind)

        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(line.oldLineNumber.map(String.init) ?? "")
                    .frame(width: 32, alignment: .trailing)
                Text(line.newLineNumber.map(String.init) ?? "")
                    .frame(width: 32, alignment: .trailing)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.diffLineNum)

            Text(style.prefix)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(style.foreground)
                .frame(width: 14)

            ScrollView(.horizontal) {
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(style.foreground)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .padding(.leading, 2)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .background(style.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: line))
    }

    private func style(for kind: UnifiedDiffLine.Kind) -> (prefix: String, background: Color, foreground: Color) {
        switch kind {
        case .addition:
            return ("+", Theme.diffAddBg, Theme.diffAddFg)
        case .deletion:
            return ("-", Theme.diffDelBg, Theme.diffDelFg)
        case .context:
            return (" ", Color.clear, Theme.textPrimary.opacity(0.78))
        }
    }

    private func accessibilityLabel(for line: UnifiedDiffLine) -> String {
        switch line.kind {
        case .addition:
            let lineNumber = line.newLineNumber.map(String.init) ?? "unknown"
            return "line \(lineNumber) added"
        case .deletion:
            let lineNumber = line.oldLineNumber.map(String.init) ?? "unknown"
            return "line \(lineNumber) removed"
        case .context:
            let lineNumber = line.newLineNumber.map(String.init) ?? line.oldLineNumber.map(String.init) ?? "unknown"
            return "line \(lineNumber) context"
        }
    }
}
