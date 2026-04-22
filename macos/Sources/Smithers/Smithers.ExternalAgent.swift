import Foundation

// MARK: - ExternalAgentKind

/// Identifies one of the external AI CLIs the app can launch in a PTY tab.
///
/// The raw values intentionally match the canonical executable names on
/// `PATH` so that `ExternalAgentKind(rawValue:)` can double as a light
/// detector when the caller already has an executable basename in hand.
enum ExternalAgentKind: String, Codable, Hashable, CaseIterable {
    case claude
    case codex
    case gemini
    case kimi
}

// MARK: - Detection

extension ExternalAgentKind {

    /// Parse a launch command like "claude --dangerously-skip-permissions" or
    /// "/usr/local/bin/codex -c foo=bar --yolo" and extract the agent kind.
    /// Returns nil if the executable is not one of the supported CLIs.
    static func detect(fromCommand command: String) -> ExternalAgentKind? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = tokenize(trimmed)
        guard var index = tokens.firstIndex(where: { !$0.isEmpty }) else { return nil }

        // Strip a leading `env` prefix (optionally followed by `KEY=VALUE` pairs).
        let firstBasename = basename(of: tokens[index])
        if firstBasename == "env" {
            index += 1
            while index < tokens.count, isEnvAssignment(tokens[index]) || tokens[index].hasPrefix("-") {
                // Skip env flags and KEY=VALUE assignments before the real executable.
                index += 1
            }
            guard index < tokens.count else { return nil }
        }

        let candidate = basename(of: tokens[index])
        return ExternalAgentKind(rawValue: candidate)
    }

    // MARK: Parsing helpers

    /// Tokenize a shell-ish command string, respecting simple single/double
    /// quoted substrings. Not a full shell parser — just enough to keep quoted
    /// paths and values intact.
    private static func tokenize(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        for ch in input {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            if ch.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Strip a leading directory path from a token. `"/usr/local/bin/claude"`
    /// becomes `"claude"`. A bare name is returned unchanged.
    private static func basename(of token: String) -> String {
        guard let slashIndex = token.lastIndex(of: "/") else { return token }
        return String(token[token.index(after: slashIndex)...])
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eqIndex = token.firstIndex(of: "=") else { return false }
        // Must have at least one char before the `=`, and that char must not
        // look like a flag.
        let keyPart = token[..<eqIndex]
        guard !keyPart.isEmpty else { return false }
        guard let first = keyPart.first, first != "-" else { return false }
        return true
    }
}

// MARK: - Session directory

extension ExternalAgentKind {

    /// Absolute path to the directory where this CLI writes session files
    /// whose names contain the session UUID. Returns nil if the CLI does not
    /// expose session files we can watch.
    var sessionDirectory: URL? {
        let home = Self.homeDirectoryURL
        switch self {
        case .claude:
            return home.appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        case .codex:
            return home.appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        case .gemini, .kimi:
            return nil
        }
    }

    /// For a given working directory, return the most specific subdirectory
    /// this CLI uses for that cwd's sessions (or the top-level sessionDirectory
    /// if the CLI does not partition by cwd). Claude uses a slug of the cwd.
    func sessionDirectory(forWorkingDirectory cwd: String) -> URL? {
        switch self {
        case .claude:
            guard let root = sessionDirectory else { return nil }
            let slug = Self.claudeSlug(forWorkingDirectory: cwd)
            guard !slug.isEmpty else { return root }
            return root.appendingPathComponent(slug, isDirectory: true)
        case .codex:
            return sessionDirectory
        case .gemini, .kimi:
            return nil
        }
    }

    /// Convert a filesystem path into the slug Claude Code uses to partition
    /// sessions. Empirically Claude replaces each `/` with `-`, so
    /// `/Users/will/gui` becomes `-Users-will-gui`. Trailing slashes are
    /// discarded; embedded dots and spaces are preserved verbatim.
    static func claudeSlug(forWorkingDirectory cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Strip trailing slashes so `/foo/` and `/foo` slug identically.
        var stripped = trimmed
        while stripped.count > 1, stripped.hasSuffix("/") {
            stripped.removeLast()
        }
        return stripped.replacingOccurrences(of: "/", with: "-")
    }

    private static var homeDirectoryURL: URL {
        // `FileManager.default.homeDirectoryForCurrentUser` is sandbox-aware,
        // but for a local CLI session watcher we want the real home dir.
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

// MARK: - Session ID extraction

extension ExternalAgentKind {

    /// Given a filename (not full path) written by this CLI, extract the UUID
    /// session id. Returns nil if the filename doesn't match the expected
    /// pattern.
    func sessionId(fromFilename filename: String) -> String? {
        switch self {
        case .claude:
            guard filename.hasSuffix(".jsonl") else { return nil }
            let stem = String(filename.dropLast(".jsonl".count))
            // Claude stores raw `<uuid>.jsonl`. Reject anything containing a
            // `-rollout` prefix or additional path-like separators so we do
            // not accidentally match codex filenames placed in the wrong dir.
            guard !stem.contains("/") else { return nil }
            guard Self.isUUIDLike(stem) else { return nil }
            return stem
        case .codex:
            guard filename.hasSuffix(".jsonl") else { return nil }
            let stem = String(filename.dropLast(".jsonl".count))
            guard stem.hasPrefix("rollout-") else { return nil }
            // Walk segments from the right; the session id is the last
            // UUID-shaped token.
            let segments = stem.split(separator: "-").map(String.init)
            for segment in segments.reversed() where Self.isUUIDLike(segment) {
                return segment
            }
            // It's also valid for the UUID to straddle multiple `-` splits
            // since UUIDs themselves contain dashes. Reconstruct the trailing
            // 5 segments and test.
            if segments.count >= 5 {
                let tail = segments.suffix(5).joined(separator: "-")
                if Self.isUUIDLike(tail) {
                    return tail
                }
            }
            return nil
        case .gemini, .kimi:
            return nil
        }
    }

    /// Cheap UUID shape check: 8-4-4-4-12 lowercase-or-uppercase hex.
    private static func isUUIDLike(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        let expectedLengths = [8, 4, 4, 4, 12]
        for (part, length) in zip(parts, expectedLengths) {
            guard part.count == length else { return false }
            for ch in part where !ch.isHexDigit {
                return false
            }
        }
        return true
    }
}

// MARK: - Resume command construction

extension ExternalAgentKind {

    /// Whether this CLI supports resuming a session by ID.
    var supportsResume: Bool {
        switch self {
        case .claude, .codex:
            return true
        case .gemini, .kimi:
            return false
        }
    }

    /// Build a new launch command that resumes the given session.
    /// Preserves non-resume flags from `originalCommand` where safe, but drops
    /// any existing --resume / resume positional args to avoid duplication.
    func resumeCommand(sessionId: String, originalCommand: String) -> String {
        guard supportsResume else { return originalCommand }
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty else { return originalCommand }

        let trimmed = originalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return originalCommand }

        let tokens = Self.tokenize(trimmed)
        guard !tokens.isEmpty else { return originalCommand }

        // Identify the boundary between optional env-prefix tokens and the
        // executable + args.
        var execIndex = 0
        if Self.basename(of: tokens[0]) == "env" {
            execIndex = 1
            while execIndex < tokens.count, Self.isEnvAssignment(tokens[execIndex]) || tokens[execIndex].hasPrefix("-") {
                execIndex += 1
            }
        }
        guard execIndex < tokens.count else { return originalCommand }

        let envPrefix = Array(tokens[0..<execIndex])
        let executable = tokens[execIndex]
        let rest = Array(tokens[(execIndex + 1)...])

        switch self {
        case .claude:
            let cleaned = Self.stripResumeFlag(from: rest)
            var pieces = envPrefix
            pieces.append(executable)
            pieces.append(contentsOf: cleaned)
            pieces.append("--resume")
            pieces.append(trimmedSessionId)
            return pieces.joined(separator: " ")
        case .codex:
            let cleaned = Self.stripCodexResumeSubcommand(from: rest)
            var pieces = envPrefix
            pieces.append(executable)
            pieces.append("resume")
            pieces.append(trimmedSessionId)
            pieces.append(contentsOf: cleaned)
            return pieces.joined(separator: " ")
        case .gemini, .kimi:
            return originalCommand
        }
    }

    /// Drop an existing `--resume <value>` pair from a token list. Flags of
    /// the form `--resume=<value>` are also removed.
    private static func stripResumeFlag(from tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--resume" {
                // Skip the flag plus its value if present.
                index += 2
                continue
            }
            if token.hasPrefix("--resume=") {
                index += 1
                continue
            }
            result.append(token)
            index += 1
        }
        return result
    }

    /// Drop a leading `resume <value>` subcommand (and any embedded one) from
    /// a codex token list.
    private static func stripCodexResumeSubcommand(from tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "resume" {
                // Consume the subcommand plus its id if the next token is not
                // a flag.
                if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            result.append(token)
            index += 1
        }
        return result
    }
}
