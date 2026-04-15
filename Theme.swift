import SwiftUI

struct Theme {
    static let base = Color(hex: "#0F111A")
    static let surface1 = Color(hex: "#141826")
    static let surface2 = Color(hex: "#1A2030")
    static let border = Color.white.opacity(0.08)
    static let sidebarBg = Color(hex: "#0C0E16")
    static let sidebarHover = Color.white.opacity(0.04)
    static let sidebarSelected = Color(hex: "#4C8DFF").opacity(0.12)
    static let pillBg = Color.white.opacity(0.06)
    static let pillBorder = Color.white.opacity(0.10)
    static let pillActive = Color(hex: "#4C8DFF").opacity(0.15)
    static let titlebarBg = Color(hex: "#141826")
    static let titlebarFg = Color.white.opacity(0.70)
    static let bubbleAssistant = Color.white.opacity(0.05)
    static let bubbleUser = Color(hex: "#4C8DFF").opacity(0.12)
    static let bubbleCommand = Color.white.opacity(0.04)
    static let bubbleStatus = Color.white.opacity(0.04)
    static let bubbleDiff = Color.white.opacity(0.05)
    static let inputBg = Color.white.opacity(0.06)
    static let accent = Color(hex: "#4C8DFF")
    static let success = Color(hex: "#34D399")
    static let warning = Color(hex: "#FBBF24")
    static let danger = Color(hex: "#F87171")
    static let info = Color(hex: "#60A5FA")
    static let textPrimary = Color.white.opacity(0.88)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary = Color.white.opacity(0.45)
    
    // Syntax
    static let synKeyword = Color(hex: "#FF5370")
    static let synString = Color(hex: "#C3E88D")
    static let synFunction = Color(hex: "#82AAFF")
    static let synComment = Color(hex: "#676E95")

    static func sidebarRowFill(isSelected: Bool, isHovered: Bool, defaultFill: Color = Color.clear) -> Color {
        if isSelected { return sidebarSelected }
        if isHovered { return sidebarHover }
        return defaultFill
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
                    .stroke(border, lineWidth: 1)
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
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func themedSidebarRowBackground(
        isSelected: Bool,
        cornerRadius: CGFloat = 0,
        defaultFill: Color = Color.clear
    ) -> some View {
        modifier(ThemedSidebarRowBackground(isSelected: isSelected, cornerRadius: cornerRadius, defaultFill: defaultFill))
    }

    func themedPill(
        fill: Color = Theme.pillBg,
        border: Color = Theme.pillBorder,
        cornerRadius: CGFloat = 4
    ) -> some View {
        modifier(ThemedPillBackground(fill: fill, border: border, cornerRadius: cornerRadius))
    }

    func themedDiffBlock(cornerRadius: CGFloat = 8) -> some View {
        modifier(ThemedDiffBlockBackground(cornerRadius: cornerRadius))
    }
}

struct SyntaxHighlightedText: View {
    let text: String
    let font: Font
    let lineSpacing: CGFloat

    init(
        _ text: String,
        font: Font = .system(size: 11, design: .monospaced),
        lineSpacing: CGFloat = 2
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

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else {
            self.init(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
            return
        }
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
