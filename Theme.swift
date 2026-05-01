import AppKit
import SwiftUI

struct Theme {
    static let base = Color(hex: "#0C0E16")
    static let surface1 = Color(hex: "#141826")
    static let surface2 = Color(hex: "#1A2030")
    static let accent = Color(hex: "#4C8DFF")
    static let success = Color(hex: "#34D399")
    static let warning = Color(hex: "#FBBF24")
    static let danger = Color(hex: "#F87171")
    static let info = Color(hex: "#60A5FA")
    static let border = Color.white.opacity(0.08)
    static let overlayShadow = Color.black.opacity(0.25)
    static let sidebarBg = base
    static let sidebarHover = Color.white.opacity(0.04)
    static let sidebarSelected = accent.opacity(0.12)
    static let pillBg = Color.white.opacity(0.06)
    static let pillBorder = Color.white.opacity(0.10)
    static let pillActive = accent.opacity(0.15)
    static let titlebarBg = surface1
    static let titlebarFg = Color.white.opacity(0.70)
    static let bubbleAssistant = Color.white.opacity(0.05)
    static let bubbleUser = accent.opacity(0.12)
    static let bubbleCommand = Color.white.opacity(0.04)
    static let bubbleStatus = Color.white.opacity(0.04)
    static let bubbleDiff = Color.white.opacity(0.05)
    static let inputBg = Color.white.opacity(0.06)
    static let textPrimary = Color.white.opacity(0.88)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary = Color.white.opacity(0.45)
    
    // Diff
    static let diffAddBg = success.opacity(0.10)
    static let diffAddFg = success
    static let diffDelBg = danger.opacity(0.10)
    static let diffDelFg = danger
    static let diffHunkBg = accent.opacity(0.08)
    static let diffHunkFg = accent.opacity(0.70)
    static let diffLineNum = Color.white.opacity(0.25)
    static let diffFileBg = Color.white.opacity(0.06)
    static let diffFileFg = Color.white.opacity(0.80)

    // Syntax
    static let synKeyword = Color(hex: "#FF5370")
    static let synString = Color(hex: "#C3E88D")
    static let synFunction = Color(hex: "#82AAFF")
    static let synComment = Color(hex: "#676E95")
    static let synNumber = Color(hex: "#F78C6C")
    static let synType = Color(hex: "#C792EA")
    static let synProperty = Color(hex: "#FFCB6B")
    static let synPunctuation = Color.white.opacity(0.50)
    static let synHeading = Color(hex: "#89DDFF")

    static func sidebarRowFill(isSelected: Bool, isHovered: Bool, defaultFill: Color = Color.clear) -> Color {
        if isSelected { return sidebarSelected }
        if isHovered { return sidebarHover }
        return defaultFill
    }

    enum Metrics {
        static let sidebarRowCornerRadius: CGFloat = 0
        static let pillCornerRadius: CGFloat = 4
        static let diffBlockCornerRadius: CGFloat = 8
        static let componentBorderWidth: CGFloat = 1
        static let syntaxTextSize: CGFloat = 11
        static let syntaxLineSpacing: CGFloat = 2
        static let editorFontSize: CGFloat = 12
        static let editorInset: CGFloat = 8
        static let highlightDebounce: TimeInterval = 0.1
        static let tabIntervalMultiplier: CGFloat = 4
    }
}

enum ScoreColorScale {
    static let highThreshold = 0.8
    static let mediumThreshold = 0.5

    static func color(for score: Double) -> Color {
        guard score.isFinite else { return Theme.textTertiary }

        let normalizedScore = min(max(score, 0), 1)
        if normalizedScore >= highThreshold { return Theme.success }
        if normalizedScore >= mediumThreshold { return Theme.warning }
        return Theme.danger
    }
}

private struct ThemedSidebarRowBackground: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    let defaultFill: Color
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(Theme.sidebarRowFill(isSelected: isSelected, isHovered: isHovered, defaultFill: defaultFill))
            .cornerRadius(cornerRadius)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct ThemedCardHover: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isHovered ? Theme.accent.opacity(0.25) : Theme.border, lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct ThemedRowHover: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? Theme.sidebarHover : Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct ThemedButtonHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .opacity(isHovered ? 1.0 : 0.85)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct ThemedPillBackground: ViewModifier {
    let fill: Color
    let border: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(fill)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(border, lineWidth: Theme.Metrics.componentBorderWidth)
            )
    }
}

private struct ThemedDiffBlockBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Theme.bubbleDiff)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Theme.border, lineWidth: Theme.Metrics.componentBorderWidth)
            )
    }
}

extension View {
    func themedSidebarRowBackground(
        isSelected: Bool,
        cornerRadius: CGFloat = Theme.Metrics.sidebarRowCornerRadius,
        defaultFill: Color = Color.clear
    ) -> some View {
        modifier(ThemedSidebarRowBackground(isSelected: isSelected, cornerRadius: cornerRadius, defaultFill: defaultFill))
    }

    func themedPill(
        fill: Color = Theme.pillBg,
        border: Color = Theme.pillBorder,
        cornerRadius: CGFloat = Theme.Metrics.pillCornerRadius
    ) -> some View {
        modifier(ThemedPillBackground(fill: fill, border: border, cornerRadius: cornerRadius))
    }

    func themedDiffBlock(cornerRadius: CGFloat = Theme.Metrics.diffBlockCornerRadius) -> some View {
        modifier(ThemedDiffBlockBackground(cornerRadius: cornerRadius))
    }

    func themedCardHover(cornerRadius: CGFloat = 10) -> some View {
        modifier(ThemedCardHover(cornerRadius: cornerRadius))
    }

    func themedRowHover(cornerRadius: CGFloat = 6) -> some View {
        modifier(ThemedRowHover(cornerRadius: cornerRadius))
    }

    func themedButtonHover() -> some View {
        modifier(ThemedButtonHover())
    }
}

struct SyntaxHighlightedText: View {
    let text: String
    let font: Font
    let lineSpacing: CGFloat

    init(
        _ text: String,
        font: Font = .system(size: Theme.Metrics.syntaxTextSize, design: .monospaced),
        lineSpacing: CGFloat = Theme.Metrics.syntaxLineSpacing
    ) {
        self.text = text
        self.font = font
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        Text(Self.highlightedString(text))
            .font(font)
            .lineSpacing(lineSpacing)
    }

    static func highlightedString(_ source: String) -> AttributedString {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var output = AttributedString()

        for lineIndex in lines.indices {
            if lineIndex != lines.startIndex {
                output += colored("\n", Theme.textPrimary)
            }
            output += highlightedLine(String(lines[lineIndex]))
        }

        return output
    }

    private static let keywords: Set<String> = [
        "async", "await", "case", "catch", "class", "const", "do", "else", "enum",
        "export", "extends", "false", "final", "for", "from", "func", "function",
        "guard", "if", "import", "in", "interface", "let", "nil", "null", "private",
        "public", "return", "static", "struct", "switch", "throws", "true", "try",
        "type", "var", "while",
    ]

    private static func highlightedLine(_ line: String) -> AttributedString {
        var output = AttributedString()
        var cursor = line.startIndex

        while cursor < line.endIndex {
            if line[cursor] == "#" {
                output += colored(String(line[cursor...]), Theme.synComment)
                break
            }

            if line[cursor] == "/", nextCharacter(in: line, after: cursor) == "/" {
                output += colored(String(line[cursor...]), Theme.synComment)
                break
            }

            if line[cursor] == "\"" || line[cursor] == "'" {
                let start = cursor
                let quote = line[cursor]
                cursor = line.index(after: cursor)
                var isEscaped = false

                while cursor < line.endIndex {
                    let char = line[cursor]
                    cursor = line.index(after: cursor)

                    if isEscaped {
                        isEscaped = false
                    } else if char == "\\" {
                        isEscaped = true
                    } else if char == quote {
                        break
                    }
                }

                output += colored(String(line[start..<cursor]), Theme.synString)
                continue
            }

            if isIdentifierHead(line[cursor]) {
                let start = cursor
                cursor = line.index(after: cursor)
                while cursor < line.endIndex, isIdentifierBody(line[cursor]) {
                    cursor = line.index(after: cursor)
                }

                let token = String(line[start..<cursor])
                if keywords.contains(token) {
                    output += colored(token, Theme.synKeyword)
                } else if isFunctionCall(in: line, after: cursor) {
                    output += colored(token, Theme.synFunction)
                } else {
                    output += colored(token, Theme.textPrimary)
                }
                continue
            }

            let next = line.index(after: cursor)
            output += colored(String(line[cursor..<next]), Theme.textPrimary)
            cursor = next
        }

        return output
    }

    private static func colored(_ text: String, _ color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = color
        return attributed
    }

    private static func nextCharacter(in line: String, after index: String.Index) -> Character? {
        let next = line.index(after: index)
        guard next < line.endIndex else { return nil }
        return line[next]
    }

    private static func isFunctionCall(in line: String, after index: String.Index) -> Bool {
        var cursor = index
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        return cursor < line.endIndex && line[cursor] == "("
    }

    private static func isIdentifierHead(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        isIdentifierHead(character) || character.isNumber
    }
}

enum SourceCodeLanguage: Equatable {
    case typeScriptReact
    case typeScript
    case javaScriptReact
    case javaScript
    case markdown
    case mdx
    case plainText

    init(fileName: String?) {
        let ext = fileName.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        switch ext {
        case "tsx":
            self = .typeScriptReact
        case "ts", "mts", "cts":
            self = .typeScript
        case "jsx":
            self = .javaScriptReact
        case "js", "mjs", "cjs":
            self = .javaScript
        case "mdx":
            self = .mdx
        case "md", "markdown":
            self = .markdown
        default:
            self = .plainText
        }
    }

    var allowsJSX: Bool {
        self == .typeScriptReact || self == .javaScriptReact || self == .mdx
    }

    var isJavaScriptLike: Bool {
        switch self {
        case .typeScriptReact, .typeScript, .javaScriptReact, .javaScript:
            return true
        case .markdown, .mdx, .plainText:
            return false
        }
    }

    var isMarkdownLike: Bool {
        self == .markdown || self == .mdx
    }
}

struct SyntaxHighlightedTextEditor: NSViewRepresentable {
    @Binding var text: String

    let language: SourceCodeLanguage
    let fontSize: CGFloat
    let isEditable: Bool
    let accessibilityIdentifier: String?

    init(
        text: Binding<String>,
        language: SourceCodeLanguage,
        fontSize: CGFloat = Theme.Metrics.editorFontSize,
        isEditable: Bool = true,
        accessibilityIdentifier: String? = nil
    ) {
        _text = text
        self.language = language
        self.fontSize = fontSize
        self.isEditable = isEditable
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SourceCodeTextScrollView {
        let scrollView = SourceCodeTextScrollView()
        scrollView.textView.delegate = context.coordinator
        scrollView.textView.string = text
        configure(scrollView)
        context.coordinator.applyHighlight(to: scrollView.textView, language: language, font: editorFont)
        return scrollView
    }

    func updateNSView(_ nsView: SourceCodeTextScrollView, context: Context) {
        context.coordinator.parent = self
        configure(nsView)

        if nsView.textView.string != text {
            context.coordinator.isUpdatingFromSwiftUI = true
            let selectedRanges = nsView.textView.selectedRanges
            nsView.textView.string = text
            nsView.textView.selectedRanges = context.coordinator.clampedRanges(
                selectedRanges,
                length: (text as NSString).length
            )
            context.coordinator.isUpdatingFromSwiftUI = false
        }

        context.coordinator.applyHighlight(to: nsView.textView, language: language, font: editorFont)
    }

    private var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private func configure(_ scrollView: SourceCodeTextScrollView) {
        let textView = scrollView.textView
        let baseColor = SourceCodeSyntaxHighlighter.nsColor(Theme.base)
        let foregroundColor = SourceCodeSyntaxHighlighter.nsColor(Theme.textPrimary)

        scrollView.drawsBackground = true
        scrollView.backgroundColor = baseColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier)

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = editorFont
        textView.textColor = foregroundColor
        textView.insertionPointColor = foregroundColor
        textView.backgroundColor = baseColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: Theme.Metrics.editorInset, height: Theme.Metrics.editorInset)
        textView.typingAttributes = SourceCodeSyntaxHighlighter.baseAttributes(font: editorFont)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightedTextEditor
        var isUpdatingFromSwiftUI = false
        private var isApplyingHighlight = false
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: SyntaxHighlightedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI, !isApplyingHighlight else { return }
            guard let textView = notification.object as? NSTextView else { return }

            parent.text = textView.string

            // Debounce highlighting to avoid re-highlighting on every keystroke.
            highlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlight(to: textView, language: self.parent.language, font: self.parent.editorFont)
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Metrics.highlightDebounce, execute: workItem)
        }

        func applyHighlight(to textView: NSTextView, language: SourceCodeLanguage, font: NSFont) {
            guard !isApplyingHighlight, let textStorage = textView.textStorage else { return }

            isApplyingHighlight = true
            let selectedRanges = textView.selectedRanges
            SourceCodeSyntaxHighlighter.applyHighlights(to: textStorage, language: language, font: font)
            textView.typingAttributes = SourceCodeSyntaxHighlighter.baseAttributes(font: font)
            textView.selectedRanges = clampedRanges(selectedRanges, length: textStorage.length)
            isApplyingHighlight = false
        }

        func clampedRanges(_ ranges: [NSValue], length: Int) -> [NSValue] {
            ranges.map { value in
                let range = value.rangeValue
                let location = min(range.location, length)
                let remaining = max(0, length - location)
                return NSValue(range: NSRange(location: location, length: min(range.length, remaining)))
            }
        }
    }
}

final class SourceCodeTextScrollView: NSScrollView {
    let textView = NSTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum SourceCodeSyntaxHighlighter {
    enum Kind {
        case keyword
        case string
        case comment
        case function
        case number
        case type
        case property
        case punctuation
        case heading
    }

    struct Span {
        let range: NSRange
        let kind: Kind
    }

    static func highlightedAttributedString(
        _ source: String,
        language: SourceCodeLanguage,
        font: NSFont = .monospacedSystemFont(ofSize: Theme.Metrics.editorFontSize, weight: .regular)
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: source, attributes: baseAttributes(font: font))
        applyHighlights(to: attributed, language: language, font: font)
        return attributed
    }

    static func applyHighlights(
        to textStorage: NSMutableAttributedString,
        language: SourceCodeLanguage,
        font: NSFont
    ) {
        let source = textStorage.string
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(font: font), range: fullRange)
        for span in spans(in: source, language: language) where NSMaxRange(span.range) <= fullRange.length {
            textStorage.addAttributes(attributes(for: span.kind, font: font), range: span.range)
        }
        textStorage.endEditing()
    }

    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = font.maximumAdvancement.width * Theme.Metrics.tabIntervalMultiplier
        paragraph.lineBreakMode = .byClipping

        return [
            .foregroundColor: nsColor(Theme.textPrimary),
            .font: font,
            .paragraphStyle: paragraph,
        ]
    }

    static func nsColor(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }

    private static func spans(in source: String, language: SourceCodeLanguage) -> [Span] {
        if language.isJavaScriptLike {
            return javaScriptSpans(in: source, allowJSX: language.allowsJSX)
        }

        if language.isMarkdownLike {
            return markdownSpans(in: source, allowMDX: language == .mdx)
        }

        return []
    }

    private static func attributes(for kind: Kind, font: NSFont) -> [NSAttributedString.Key: Any] {
        let color: Color
        let highlightedFont: NSFont

        switch kind {
        case .keyword:
            color = Theme.synKeyword
            highlightedFont = font
        case .string:
            color = Theme.synString
            highlightedFont = font
        case .comment:
            color = Theme.synComment
            highlightedFont = font
        case .function:
            color = Theme.synFunction
            highlightedFont = font
        case .number:
            color = Theme.synNumber
            highlightedFont = font
        case .type:
            color = Theme.synType
            highlightedFont = font
        case .property:
            color = Theme.synProperty
            highlightedFont = font
        case .punctuation:
            color = Theme.synPunctuation
            highlightedFont = font
        case .heading:
            color = Theme.synHeading
            highlightedFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        }

        return [
            .foregroundColor: nsColor(color),
            .font: highlightedFont,
        ]
    }

    private static let javaScriptKeywords: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class",
        "const", "continue", "debugger", "declare", "default", "delete", "do",
        "else", "enum", "export", "extends", "false", "finally", "for", "from",
        "function", "get", "if", "implements", "import", "in", "infer",
        "instanceof", "interface", "is", "keyof", "let", "module", "namespace",
        "new", "null", "of", "private", "protected", "public", "readonly",
        "return", "satisfies", "set", "static", "super", "switch", "this",
        "throw", "true", "try", "type", "typeof", "undefined", "var", "while",
        "with", "yield",
    ]

    private static let typeNames: Set<String> = [
        "Array", "Error", "Map", "Node", "Promise", "React", "Record", "Set",
        "WeakMap", "WeakSet", "any", "bigint", "boolean", "never", "number",
        "object", "string", "symbol", "unknown", "void",
    ]

    private static func javaScriptSpans(
        in source: String,
        allowJSX: Bool,
        utf16Offset: Int = 0
    ) -> [Span] {
        var spans: [Span] = []
        var cursor = source.startIndex

        while cursor < source.endIndex {
            let character = source[cursor]

            if character == "/", Self.character(after: cursor, in: source) == "/" {
                let end = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .comment))
                cursor = end
                continue
            }

            if character == "/", Self.character(after: cursor, in: source) == "*" {
                let searchStart = source.index(cursor, offsetBy: 2)
                let end = source[searchStart...].range(of: "*/")?.upperBound ?? source.endIndex
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .comment))
                cursor = end
                continue
            }

            if character == "\"" || character == "'" || character == "`" {
                let end = stringEnd(in: source, from: cursor, quote: character)
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .string))
                cursor = end
                continue
            }

            if allowJSX, character == "<", isJSXTagStart(in: source, at: cursor) {
                let result = jsxTagSpans(in: source, from: cursor, utf16Offset: utf16Offset)
                spans.append(contentsOf: result.spans)
                cursor = result.end
                continue
            }

            if character.isNumber {
                let end = numberEnd(in: source, from: cursor)
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .number))
                cursor = end
                continue
            }

            if isIdentifierHead(character) {
                let end = identifierEnd(in: source, from: cursor)
                let token = String(source[cursor..<end])
                let kind: Kind?

                if javaScriptKeywords.contains(token) {
                    kind = .keyword
                } else if typeNames.contains(token) || startsWithUppercase(token) {
                    kind = .type
                } else if previousNonWhitespace(in: source, before: cursor) == "." {
                    kind = .property
                } else if isFunctionCall(in: source, after: end) {
                    kind = .function
                } else {
                    kind = nil
                }

                if let kind {
                    spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: kind))
                }
                cursor = end
                continue
            }

            cursor = source.index(after: cursor)
        }

        return spans
    }

    private static func markdownSpans(in source: String, allowMDX: Bool) -> [Span] {
        var spans: [Span] = []
        var lineStart = source.startIndex
        var isFirstLine = true
        var isInFrontmatter = false
        var isInFence = false
        var fencedLanguage: SourceCodeLanguage = .plainText

        while lineStart < source.endIndex {
            let newline = source[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? source.endIndex
            let nextLineStart = newline.map { source.index(after: $0) } ?? source.endIndex
            let lineRange = lineStart..<lineEnd
            let line = String(source[lineRange])
            let lineOffset = NSRange(lineRange, in: source).location
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isFirstLine, trimmed == "---" {
                isInFrontmatter = true
                spans.append(span(line.startIndex..<line.endIndex, in: line, offset: lineOffset, kind: .comment))
                lineStart = nextLineStart
                isFirstLine = false
                continue
            }

            if isInFrontmatter {
                spans.append(span(line.startIndex..<line.endIndex, in: line, offset: lineOffset, kind: .comment))
                if trimmed == "---" {
                    isInFrontmatter = false
                }
                lineStart = nextLineStart
                isFirstLine = false
                continue
            }

            if let fenceInfo = fenceInfo(from: trimmed) {
                spans.append(span(line.startIndex..<line.endIndex, in: line, offset: lineOffset, kind: .comment))
                if isInFence {
                    isInFence = false
                    fencedLanguage = .plainText
                } else {
                    isInFence = true
                    fencedLanguage = SourceCodeLanguage(fenceName: fenceInfo)
                }
                lineStart = nextLineStart
                isFirstLine = false
                continue
            }

            if isInFence {
                if fencedLanguage.isJavaScriptLike {
                    spans.append(contentsOf: javaScriptSpans(
                        in: line,
                        allowJSX: fencedLanguage.allowsJSX,
                        utf16Offset: lineOffset
                    ))
                } else {
                    spans.append(span(line.startIndex..<line.endIndex, in: line, offset: lineOffset, kind: .string))
                }
                lineStart = nextLineStart
                isFirstLine = false
                continue
            }

            if let headingRange = markdownHeadingRange(in: line) {
                spans.append(span(headingRange, in: line, offset: lineOffset, kind: .heading))
                lineStart = nextLineStart
                isFirstLine = false
                continue
            }

            if let markerRange = markdownMarkerRange(in: line) {
                spans.append(span(markerRange, in: line, offset: lineOffset, kind: .punctuation))
            }

            spans.append(contentsOf: markdownInlineSpans(in: line, allowMDX: allowMDX, utf16Offset: lineOffset))

            lineStart = nextLineStart
            isFirstLine = false
        }

        return spans
    }

    private static func markdownInlineSpans(
        in line: String,
        allowMDX: Bool,
        utf16Offset: Int
    ) -> [Span] {
        var spans: [Span] = []
        var cursor = line.startIndex

        while cursor < line.endIndex {
            if line[cursor...].hasPrefix("<!--") {
                let end = line[cursor...].range(of: "-->")?.upperBound ?? line.endIndex
                spans.append(span(cursor..<end, in: line, offset: utf16Offset, kind: .comment))
                cursor = end
                continue
            }

            if line[cursor] == "`" {
                let end = inlineCodeEnd(in: line, from: cursor)
                spans.append(span(cursor..<end, in: line, offset: utf16Offset, kind: .string))
                cursor = end
                continue
            }

            if line[cursor] == "[", let result = markdownLinkSpans(in: line, from: cursor, utf16Offset: utf16Offset) {
                spans.append(contentsOf: result.spans)
                cursor = result.end
                continue
            }

            if allowMDX, line[cursor] == "<", isJSXTagStart(in: line, at: cursor) {
                let result = jsxTagSpans(in: line, from: cursor, utf16Offset: utf16Offset)
                spans.append(contentsOf: result.spans)
                cursor = result.end
                continue
            }

            if allowMDX, line[cursor] == "{" {
                let end = balancedBraceEnd(in: line, from: cursor)
                let innerStart = line.index(after: cursor)
                let innerEnd = line.index(before: end)
                spans.append(span(cursor..<innerStart, in: line, offset: utf16Offset, kind: .punctuation))
                if innerStart < innerEnd {
                    spans.append(contentsOf: javaScriptSpans(
                        in: String(line[innerStart..<innerEnd]),
                        allowJSX: true,
                        utf16Offset: utf16Offset + NSRange(line.startIndex..<innerStart, in: line).length
                    ))
                }
                spans.append(span(innerEnd..<end, in: line, offset: utf16Offset, kind: .punctuation))
                cursor = end
                continue
            }

            if line[cursor] == "*" || line[cursor] == "_" {
                let next = line.index(after: cursor)
                spans.append(span(cursor..<next, in: line, offset: utf16Offset, kind: .punctuation))
                cursor = next
                continue
            }

            cursor = line.index(after: cursor)
        }

        return spans
    }

    private static func jsxTagSpans(
        in source: String,
        from start: String.Index,
        utf16Offset: Int
    ) -> (spans: [Span], end: String.Index) {
        var spans: [Span] = []
        var cursor = start

        let tagOpenEnd: String.Index
        if source[cursor...].hasPrefix("</") {
            tagOpenEnd = source.index(cursor, offsetBy: 2)
        } else {
            tagOpenEnd = source.index(after: cursor)
        }
        spans.append(span(cursor..<tagOpenEnd, in: source, offset: utf16Offset, kind: .punctuation))
        cursor = tagOpenEnd

        if cursor < source.endIndex, isJSXNameHead(source[cursor]) {
            let tagNameEnd = jsxNameEnd(in: source, from: cursor)
            spans.append(span(cursor..<tagNameEnd, in: source, offset: utf16Offset, kind: .function))
            cursor = tagNameEnd
        }

        while cursor < source.endIndex {
            let character = source[cursor]

            if character.isWhitespace {
                cursor = source.index(after: cursor)
                continue
            }

            if character == "\"" || character == "'" {
                let end = stringEnd(in: source, from: cursor, quote: character)
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .string))
                cursor = end
                continue
            }

            if character == "{" {
                let end = balancedBraceEnd(in: source, from: cursor)
                let innerStart = source.index(after: cursor)
                let innerEnd = source.index(before: end)
                spans.append(span(cursor..<innerStart, in: source, offset: utf16Offset, kind: .punctuation))
                if innerStart < innerEnd {
                    let innerSource = String(source[innerStart..<innerEnd])
                    let innerOffset = utf16Offset + NSRange(source.startIndex..<innerStart, in: source).length
                    spans.append(contentsOf: javaScriptSpans(in: innerSource, allowJSX: true, utf16Offset: innerOffset))
                }
                spans.append(span(innerEnd..<end, in: source, offset: utf16Offset, kind: .punctuation))
                cursor = end
                continue
            }

            if source[cursor...].hasPrefix("/>") {
                let end = source.index(cursor, offsetBy: 2)
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .punctuation))
                return (spans, end)
            }

            if character == ">" {
                let end = source.index(after: cursor)
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .punctuation))
                return (spans, end)
            }

            if isJSXNameHead(character) {
                let end = jsxNameEnd(in: source, from: cursor)
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .property))
                cursor = end
                continue
            }

            let end = source.index(after: cursor)
            if character == "=" || character == "/" {
                spans.append(span(cursor..<end, in: source, offset: utf16Offset, kind: .punctuation))
            }
            cursor = end
        }

        return (spans, source.endIndex)
    }

    private static func markdownLinkSpans(
        in line: String,
        from start: String.Index,
        utf16Offset: Int
    ) -> (spans: [Span], end: String.Index)? {
        guard let closeBracket = line[start...].firstIndex(of: "]") else { return nil }
        let parenStart = line.index(after: closeBracket)
        guard parenStart < line.endIndex, line[parenStart] == "(" else { return nil }
        guard let closeParen = line[parenStart...].firstIndex(of: ")") else { return nil }

        let textStart = line.index(after: start)
        let urlStart = line.index(after: parenStart)
        let end = line.index(after: closeParen)

        return ([
            span(start..<textStart, in: line, offset: utf16Offset, kind: .punctuation),
            span(textStart..<closeBracket, in: line, offset: utf16Offset, kind: .function),
            span(closeBracket..<urlStart, in: line, offset: utf16Offset, kind: .punctuation),
            span(urlStart..<closeParen, in: line, offset: utf16Offset, kind: .string),
            span(closeParen..<end, in: line, offset: utf16Offset, kind: .punctuation),
        ], end)
    }

    private static func markdownHeadingRange(in line: String) -> Range<String.Index>? {
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
            cursor = line.index(after: cursor)
        }

        let markerStart = cursor
        var count = 0
        while cursor < line.endIndex, line[cursor] == "#", count < 6 {
            count += 1
            cursor = line.index(after: cursor)
        }

        guard count > 0 else { return nil }
        guard cursor == line.endIndex || line[cursor].isWhitespace else { return nil }
        return markerStart..<line.endIndex
    }

    private static func markdownMarkerRange(in line: String) -> Range<String.Index>? {
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }

        if cursor < line.endIndex, line[cursor] == ">" {
            return cursor..<line.index(after: cursor)
        }

        if cursor < line.endIndex, line[cursor] == "-" || line[cursor] == "*" || line[cursor] == "+" {
            let next = line.index(after: cursor)
            if next == line.endIndex || line[next].isWhitespace {
                return cursor..<next
            }
        }

        return nil
    }

    private static func fenceInfo(from trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") else { return nil }
        let info = trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return info.components(separatedBy: .whitespacesAndNewlines).first ?? ""
    }

    private static func inlineCodeEnd(in line: String, from start: String.Index) -> String.Index {
        let searchStart = line.index(after: start)
        if let close = line[searchStart...].firstIndex(of: "`") {
            return line.index(after: close)
        }
        return line.endIndex
    }

    private static func stringEnd(in source: String, from start: String.Index, quote: Character) -> String.Index {
        var cursor = source.index(after: start)
        var isEscaped = false

        while cursor < source.endIndex {
            let character = source[cursor]
            cursor = source.index(after: cursor)

            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == quote {
                break
            }
        }

        return cursor
    }

    private static func balancedBraceEnd(in source: String, from start: String.Index) -> String.Index {
        var cursor = source.index(after: start)
        var depth = 1

        while cursor < source.endIndex {
            let character = source[cursor]

            if character == "\"" || character == "'" || character == "`" {
                cursor = stringEnd(in: source, from: cursor, quote: character)
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return source.index(after: cursor)
                }
            }

            cursor = source.index(after: cursor)
        }

        return source.endIndex
    }

    private static func numberEnd(in source: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < source.endIndex {
            let character = source[cursor]
            if character.isNumber || character.isLetter || character == "." || character == "_" {
                cursor = source.index(after: cursor)
            } else {
                break
            }
        }
        return cursor
    }

    private static func isFunctionCall(in source: String, after index: String.Index) -> Bool {
        var cursor = index
        while cursor < source.endIndex, source[cursor].isWhitespace {
            cursor = source.index(after: cursor)
        }
        return cursor < source.endIndex && source[cursor] == "("
    }

    private static func isJSXTagStart(in source: String, at index: String.Index) -> Bool {
        guard source[index] == "<" else { return false }
        guard let next = character(after: index, in: source) else { return false }

        if next == ">" {
            return true
        }

        if next == "/" {
            let slash = source.index(after: index)
            guard let afterSlash = character(after: slash, in: source) else { return false }
            return isJSXNameHead(afterSlash)
        }

        return isJSXNameHead(next)
    }

    private static func identifierEnd(in source: String, from start: String.Index) -> String.Index {
        var cursor = source.index(after: start)
        while cursor < source.endIndex, isIdentifierBody(source[cursor]) {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    private static func jsxNameEnd(in source: String, from start: String.Index) -> String.Index {
        var cursor = source.index(after: start)
        while cursor < source.endIndex, isJSXNameBody(source[cursor]) {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    private static func isIdentifierHead(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        isIdentifierHead(character) || character.isNumber
    }

    private static func isJSXNameHead(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isJSXNameBody(_ character: Character) -> Bool {
        isJSXNameHead(character) || character.isNumber || character == "-" || character == ":" || character == "."
    }

    private static func startsWithUppercase(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return first.isUppercase
    }

    private static func character(after index: String.Index, in source: String) -> Character? {
        let next = source.index(after: index)
        guard next < source.endIndex else { return nil }
        return source[next]
    }

    private static func previousNonWhitespace(in source: String, before index: String.Index) -> Character? {
        guard index > source.startIndex else { return nil }
        var cursor = source.index(before: index)
        while cursor >= source.startIndex {
            let character = source[cursor]
            if !character.isWhitespace {
                return character
            }
            if cursor == source.startIndex { break }
            cursor = source.index(before: cursor)
        }
        return nil
    }

    private static func span(
        _ range: Range<String.Index>,
        in source: String,
        offset: Int,
        kind: Kind
    ) -> Span {
        var nsRange = NSRange(range, in: source)
        nsRange.location += offset
        return Span(range: nsRange, kind: kind)
    }
}

private extension SourceCodeLanguage {
    init(fenceName: String) {
        let normalized = fenceName
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .lowercased()

        switch normalized {
        case "tsx", "typescriptreact":
            self = .typeScriptReact
        case "ts", "typescript":
            self = .typeScript
        case "jsx", "javascriptreact":
            self = .javaScriptReact
        case "js", "javascript", "node":
            self = .javaScript
        case "mdx":
            self = .mdx
        case "md", "markdown":
            self = .markdown
        default:
            self = .plainText
        }
    }
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed

        guard HexColorParser.supportedLengths.contains(digits.count),
              digits.allSatisfy(HexColorParser.isHexDigit),
              let int = UInt64(digits, radix: HexColorParser.radix)
        else {
            self.init(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
            return
        }
        let a, r, g, b: UInt64
        switch digits.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (
                HexColorParser.componentMax,
                (int >> 8) * HexColorParser.shorthandScale,
                (int >> 4 & 0xF) * HexColorParser.shorthandScale,
                (int & 0xF) * HexColorParser.shorthandScale
            )
        case 6: // RGB (24-bit)
            (a, r, g, b) = (HexColorParser.componentMax, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (HexColorParser.componentMax, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / HexColorParser.componentDivisor,
            green: Double(g) / HexColorParser.componentDivisor,
            blue:  Double(b) / HexColorParser.componentDivisor,
            opacity: Double(a) / HexColorParser.componentDivisor
        )
    }
}

private enum HexColorParser {
    static let supportedLengths: Set<Int> = [3, 6, 8]
    static let radix = 16
    static let componentMax: UInt64 = 255
    static let componentDivisor = Double(componentMax)
    static let shorthandScale: UInt64 = 17

    private static let validDigits = Set("0123456789abcdefABCDEF")

    static func isHexDigit(_ character: Character) -> Bool {
        validDigits.contains(character)
    }
}
