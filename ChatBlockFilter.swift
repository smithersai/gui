import Foundation

/// Centralizes transcript noise filtering so the same rules apply in every logs surface.
enum ChatBlockFilter {
    static let defaultNoisePattern = #"^(?:warning:.*|ERROR\s+codex_core::.*|ERROR\s+codex_.*|state db missing rollout path.*|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\s+(?:ERROR|WARN)\s+.+)$"#

    private static let defaultRegex: NSRegularExpression = {
        // Safe by construction: shipped default should never fail to compile.
        try! NSRegularExpression(pattern: defaultNoisePattern, options: [.caseInsensitive])
    }()

    static func shouldHide(
        _ block: ChatBlock,
        enabled: Bool,
        regexPattern: String? = nil
    ) -> Bool {
        guard enabled else { return false }

        let role = block.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role == "system" || role == "stderr" || role == "status" else {
            return false
        }

        let trimmed = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        let regex = compiledRegex(from: regexPattern)
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { line in
            let range = NSRange(location: 0, length: (line as NSString).length)
            return regex.firstMatch(in: line, options: [], range: range) != nil
        }
    }

    private static func compiledRegex(from pattern: String?) -> NSRegularExpression {
        let trimmed = pattern?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return defaultRegex
        }

        do {
            return try NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
        } catch {
            AppLogger.ui.warning("Invalid custom noise regex, falling back to default", metadata: [
                "pattern_length": String(trimmed.count),
                "error": String(describing: error),
            ])
            return defaultRegex
        }
    }
}
