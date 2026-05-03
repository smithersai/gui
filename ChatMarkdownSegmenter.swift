import Foundation

enum ChatMarkdownSegment: Equatable {
    case text(String)
    case code(language: String?, content: String)
}

enum ChatMarkdownSegmenter {
    static func segments(in content: String) -> [ChatMarkdownSegment] {
        var segments: [ChatMarkdownSegment] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeBlock = false

        func flushText() {
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            textLines.removeAll()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            segments.append(.text(text))
        }

        func flushCode() {
            let code = codeLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            codeLines.removeAll()
            segments.append(.code(language: codeLanguage, content: code))
            codeLanguage = nil
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else {
                if inCodeBlock {
                    codeLines.append(line)
                } else {
                    textLines.append(line)
                }
                continue
            }

            if inCodeBlock {
                flushCode()
                inCodeBlock = false
            } else {
                flushText()
                inCodeBlock = true
                codeLanguage = language(fromFence: trimmed)
            }
        }

        if inCodeBlock {
            flushCode()
        } else {
            flushText()
        }

        return segments
    }

    private static func language(fromFence fence: String) -> String? {
        let raw = fence.dropFirst(3)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let token = raw.split(whereSeparator: { $0.isWhitespace }).first
        return token.map(String.init)
    }
}
