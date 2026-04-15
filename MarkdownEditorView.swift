import AppKit
import SwiftUI

// MARK: - Syntax-Highlighted Markdown Text Editor

/// A native NSTextView-based markdown editor with live syntax highlighting.
/// Works with plain markdown strings — no HTML conversion needed.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.font = .monospacedSystemFont(ofSize: CGFloat(Theme.Metrics.editorFontSize), weight: .regular)
        textView.backgroundColor = NSColor(Theme.base)
        textView.textColor = NSColor(Color.white.opacity(0.88))
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Theme.accent.opacity(0.25)),
            .foregroundColor: NSColor.white,
        ]
        textView.isRichText = true          // needed for attribute styling
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = context.coordinator

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(Theme.base)
        scrollView.scrollerStyle = .overlay

        textView.string = text
        MarkdownHighlighter.highlight(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text && !context.coordinator.isEditing {
            let savedSelection = textView.selectedRanges
            textView.string = text
            MarkdownHighlighter.highlight(textView)
            textView.selectedRanges = savedSelection
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var isEditing = false
        private var highlightWork: DispatchWorkItem?

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = textView.string
            isEditing = false

            // Debounce highlighting to avoid per-keystroke cost
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak textView] in
                guard let textView else { return }
                MarkdownHighlighter.highlight(textView)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Theme.Metrics.highlightDebounce,
                execute: work
            )
        }
    }
}

// MARK: - Markdown Syntax Highlighter

enum MarkdownHighlighter {

    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let baseFont = NSFont.monospacedSystemFont(ofSize: CGFloat(Theme.Metrics.editorFontSize), weight: .regular)
        let baseColor = NSColor(Color.white.opacity(0.88))
        let savedSelection = textView.selectedRanges

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: baseColor], range: full)

        applyCodeBlocks(storage, text: text)
        applyHeadings(storage, text: text, baseFont: baseFont)
        applyBold(storage, text: text, baseFont: baseFont)
        applyItalic(storage, text: text, baseFont: baseFont)
        applyInlineCode(storage, text: text, baseFont: baseFont)
        applyLinks(storage, text: text)
        applyBlockquotes(storage, text: text)
        applyListMarkers(storage, text: text)
        applyHorizontalRules(storage, text: text)
        applyStrikethrough(storage, text: text)

        storage.endEditing()
        textView.selectedRanges = savedSelection
    }

    // MARK: - Pattern helpers

    private static func ranges(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [(NSRange, NSTextCheckingResult)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let full = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: full).map { ($0.range, $0) }
    }

    // MARK: - Fenced code blocks  ```...```

    private static func applyCodeBlocks(_ storage: NSMutableAttributedString, text: String) {
        let codeFont = NSFont.monospacedSystemFont(ofSize: CGFloat(Theme.Metrics.editorFontSize), weight: .regular)
        let fenceColor = NSColor(Theme.synComment)
        let codeColor = NSColor(Color.white.opacity(0.75))
        let pattern = #"(?m)^```[^\n]*\n([\s\S]*?)^```"#
        for (range, _) in ranges(of: pattern, in: text, options: .anchorsMatchLines) {
            storage.addAttributes([.font: codeFont, .foregroundColor: codeColor], range: range)
            // Dim the fence markers themselves
            let str = text as NSString
            let fenceStart = str.lineRange(for: NSRange(location: range.location, length: 0))
            storage.addAttribute(.foregroundColor, value: fenceColor, range: fenceStart)
            let endLoc = range.location + range.length
            if endLoc <= str.length {
                let fenceEnd = str.lineRange(for: NSRange(location: max(0, endLoc - 3), length: 0))
                storage.addAttribute(.foregroundColor, value: fenceColor, range: fenceEnd)
            }
        }
    }

    // MARK: - Headings  # … ######

    private static func applyHeadings(_ storage: NSMutableAttributedString, text: String, baseFont: NSFont) {
        let headingColor = NSColor(Theme.synHeading)
        let pattern = #"(?m)^(#{1,6})\s+(.+)$"#
        for (range, match) in ranges(of: pattern, in: text, options: .anchorsMatchLines) {
            let hashRange = match.range(at: 1)
            let level = hashRange.length
            let sizes: [CGFloat] = [20, 17, 15, 14, 13, 12]
            let size = level <= sizes.count ? sizes[level - 1] : 12
            let headingFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
            storage.addAttributes([.font: headingFont, .foregroundColor: headingColor], range: range)
        }
    }

    // MARK: - Bold  **…** / __…__

    private static func applyBold(_ storage: NSMutableAttributedString, text: String, baseFont: NSFont) {
        let markerColor = NSColor(Theme.synPunctuation)
        let boldFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .bold)
        for pattern in [#"\*\*(.+?)\*\*"#, #"__(.+?)__"#] {
            for (range, match) in ranges(of: pattern, in: text) {
                let contentRange = match.range(at: 1)
                storage.addAttribute(.font, value: boldFont, range: contentRange)
                // Dim markers
                let mStart = NSRange(location: range.location, length: 2)
                let mEnd = NSRange(location: range.location + range.length - 2, length: 2)
                storage.addAttribute(.foregroundColor, value: markerColor, range: mStart)
                storage.addAttribute(.foregroundColor, value: markerColor, range: mEnd)
            }
        }
    }

    // MARK: - Italic  *…* / _…_

    private static func applyItalic(_ storage: NSMutableAttributedString, text: String, baseFont: NSFont) {
        let markerColor = NSColor(Theme.synPunctuation)
        let italicDesc = baseFont.fontDescriptor.withSymbolicTraits(.italic)
        let italicFont = NSFont(descriptor: italicDesc, size: baseFont.pointSize) ?? baseFont
        for pattern in [#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, #"(?<!\w)_(?!_)(.+?)(?<!_)_(?!\w)"#] {
            for (range, match) in ranges(of: pattern, in: text) {
                let contentRange = match.range(at: 1)
                storage.addAttribute(.font, value: italicFont, range: contentRange)
                let mStart = NSRange(location: range.location, length: 1)
                let mEnd = NSRange(location: range.location + range.length - 1, length: 1)
                storage.addAttribute(.foregroundColor, value: markerColor, range: mStart)
                storage.addAttribute(.foregroundColor, value: markerColor, range: mEnd)
            }
        }
    }

    // MARK: - Inline code  `…`

    private static func applyInlineCode(_ storage: NSMutableAttributedString, text: String, baseFont: NSFont) {
        let codeColor = NSColor(Theme.synKeyword)
        let markerColor = NSColor(Theme.synPunctuation)
        let pattern = #"(?<!`)`(?!`)(.+?)(?<!`)`(?!`)"#
        for (range, match) in ranges(of: pattern, in: text) {
            storage.addAttribute(.foregroundColor, value: codeColor, range: match.range(at: 1))
            let mStart = NSRange(location: range.location, length: 1)
            let mEnd = NSRange(location: range.location + range.length - 1, length: 1)
            storage.addAttribute(.foregroundColor, value: markerColor, range: mStart)
            storage.addAttribute(.foregroundColor, value: markerColor, range: mEnd)
        }
    }

    // MARK: - Links  [text](url)

    private static func applyLinks(_ storage: NSMutableAttributedString, text: String) {
        let linkColor = NSColor(Theme.accent)
        let bracketColor = NSColor(Theme.synPunctuation)
        let urlColor = NSColor(Theme.synComment)
        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        for (range, match) in ranges(of: pattern, in: text) {
            let textRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            storage.addAttribute(.foregroundColor, value: linkColor, range: textRange)
            storage.addAttribute(.foregroundColor, value: urlColor, range: urlRange)
            // Brackets & parens
            let ob = NSRange(location: range.location, length: 1)
            let cb = NSRange(location: textRange.location + textRange.length, length: 2)
            let cp = NSRange(location: range.location + range.length - 1, length: 1)
            storage.addAttribute(.foregroundColor, value: bracketColor, range: ob)
            storage.addAttribute(.foregroundColor, value: bracketColor, range: cb)
            storage.addAttribute(.foregroundColor, value: bracketColor, range: cp)
        }
    }

    // MARK: - Blockquotes  > …

    private static func applyBlockquotes(_ storage: NSMutableAttributedString, text: String) {
        let quoteColor = NSColor(Theme.synComment)
        let markerColor = NSColor(Theme.accent)
        let pattern = #"(?m)^(>)\s+(.+)$"#
        for (_, match) in ranges(of: pattern, in: text, options: .anchorsMatchLines) {
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 1))
            storage.addAttribute(.foregroundColor, value: quoteColor, range: match.range(at: 2))
        }
    }

    // MARK: - List markers  - / * / + / 1.

    private static func applyListMarkers(_ storage: NSMutableAttributedString, text: String) {
        let markerColor = NSColor(Theme.accent)
        // Unordered
        let ul = #"(?m)^(\s*[-*+])\s"#
        for (_, match) in ranges(of: ul, in: text, options: .anchorsMatchLines) {
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 1))
        }
        // Ordered
        let ol = #"(?m)^(\s*\d+\.)\s"#
        for (_, match) in ranges(of: ol, in: text, options: .anchorsMatchLines) {
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 1))
        }
    }

    // MARK: - Horizontal rules  --- / *** / ___

    private static func applyHorizontalRules(_ storage: NSMutableAttributedString, text: String) {
        let ruleColor = NSColor(Theme.synComment)
        let pattern = #"(?m)^(---+|\*\*\*+|___+)\s*$"#
        for (range, _) in ranges(of: pattern, in: text, options: .anchorsMatchLines) {
            storage.addAttribute(.foregroundColor, value: ruleColor, range: range)
        }
    }

    // MARK: - Strikethrough  ~~…~~

    private static func applyStrikethrough(_ storage: NSMutableAttributedString, text: String) {
        let strikeColor = NSColor(Theme.synComment)
        let pattern = #"~~(.+?)~~"#
        for (range, _) in ranges(of: pattern, in: text) {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: strikeColor,
            ], range: range)
        }
    }
}

// MARK: - Native SwiftUI Markdown Renderer (read-only)

/// A lightweight SwiftUI view that renders markdown with proper formatting.
/// Uses native SwiftUI views — no WKWebView overhead.
struct MarkdownContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.parse(content).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(markdownInline(text))
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(markdownInline(text))
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .textSelection(.enabled)

        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.80))
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\u{2022}")
                            .foregroundColor(Theme.textTertiary)
                            .font(.system(size: 12))
                        Text(markdownInline(item))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4)

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundColor(Theme.textTertiary)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 20, alignment: .trailing)
                        Text(markdownInline(item))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent)
                    .frame(width: 3)
                Text(markdownInline(text))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, 10)
                    .textSelection(.enabled)
            }

        case .horizontalRule:
            Divider().background(Theme.border)
        }
    }

    private func markdownInline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        case 4: return 14
        default: return 13
        }
    }
}

// MARK: - Markdown Block Parser

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(language: String?, code: String)
    case unorderedList(items: [String])
    case orderedList(items: [String])
    case blockquote(text: String)
    case horizontalRule
}

enum MarkdownParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code = ""
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                    if !code.isEmpty { code += "\n" }
                    code += lines[i]
                    i += 1
                }
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: code))
                continue
            }

            // Heading
            if let (level, text) = parseHeading(trimmed) {
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed.range(of: #"^(---+|\*\*\*+|___+)$"#, options: .regularExpression) != nil {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Blockquote (collect consecutive > lines)
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("> ") {
                        quoteLines.append(String(l.dropFirst(2)))
                    } else if l == ">" {
                        quoteLines.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: " ")))
                continue
            }

            // Unordered list
            if isUnorderedItem(trimmed) {
                var items: [String] = []
                while i < lines.count, isUnorderedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))
                    i += 1
                }
                blocks.append(.unorderedList(items: items))
                continue
            }

            // Ordered list
            if isOrderedItem(trimmed) {
                var items: [String] = []
                while i < lines.count, isOrderedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let r = l.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                        items.append(String(l[r.upperBound...]))
                    }
                    i += 1
                }
                blocks.append(.orderedList(items: items))
                continue
            }

            // Paragraph – accumulate until we hit a block-level element or blank
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("```") || l.hasPrefix("> ")
                    || isUnorderedItem(l) || isOrderedItem(l)
                    || l.range(of: #"^(---+|\*\*\*+|___+)$"#, options: .regularExpression) != nil {
                    break
                }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(text: paraLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func isUnorderedItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }
}
