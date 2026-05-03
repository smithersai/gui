import Foundation

enum ChatTranscriptSearch {
    static func filtered(_ blocks: [ChatBlock], query: String) -> [ChatBlock] {
        let tokens = searchTokens(from: query)
        guard !tokens.isEmpty else { return blocks }

        return blocks.filter { block in
            let haystack = normalized(searchableText(for: block))
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    static func matches(_ block: ChatBlock, query: String) -> Bool {
        !filtered([block], query: query).isEmpty
    }

    private static func searchableText(for block: ChatBlock) -> String {
        [
            block.role,
            ChatBlockRenderer.roleLabel(for: block.role),
            ChatContentText.decoded(block.content),
        ].joined(separator: "\n")
    }

    private static func searchTokens(from query: String) -> [String] {
        normalized(query)
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalized(_ text: String) -> String {
        ChatContentText.decoded(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
