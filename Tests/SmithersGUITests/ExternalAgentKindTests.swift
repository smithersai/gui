import XCTest
@testable import SmithersGUI

// MARK: - detect(fromCommand:) Tests

final class ExternalAgentKindDetectTests: XCTestCase {

    func testDetectClaudeBare() {
        XCTAssertEqual(ExternalAgentKind.detect(fromCommand: "claude"), .claude)
    }

    func testDetectCodexBare() {
        XCTAssertEqual(ExternalAgentKind.detect(fromCommand: "codex"), .codex)
    }

    func testDetectGeminiBare() {
        XCTAssertEqual(ExternalAgentKind.detect(fromCommand: "gemini"), .gemini)
    }

    func testDetectKimiBare() {
        XCTAssertEqual(ExternalAgentKind.detect(fromCommand: "kimi"), .kimi)
    }

    func testDetectClaudeWithPathPrefix() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "/usr/local/bin/claude --resume abc"),
            .claude
        )
    }

    func testDetectCodexWithPathPrefix() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "/opt/homebrew/bin/codex -c foo=bar --yolo"),
            .codex
        )
    }

    func testDetectWithEnvPrefix() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "env NODE_ENV=prod claude --resume 1"),
            .claude
        )
    }

    func testDetectWithEnvPrefixMultipleAssignments() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "env FOO=1 BAR=2 BAZ=quux gemini --yolo"),
            .gemini
        )
    }

    func testDetectWithEnvAndFlag() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "env -i PATH=/usr/bin codex"),
            .codex
        )
    }

    func testDetectWithFlagsAfterExecutable() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "claude --dangerously-skip-permissions --print"),
            .claude
        )
    }

    func testDetectWithQuotedValue() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "codex -c model_reasoning_effort=\"high\""),
            .codex
        )
    }

    func testDetectWithQuotedExecutablePath() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "\"/usr/local/bin/claude\" --resume abc"),
            .claude
        )
    }

    func testDetectUnknownExecutable() {
        XCTAssertNil(ExternalAgentKind.detect(fromCommand: "zsh -i"))
    }

    func testDetectEmptyString() {
        XCTAssertNil(ExternalAgentKind.detect(fromCommand: ""))
    }

    func testDetectWhitespaceOnly() {
        XCTAssertNil(ExternalAgentKind.detect(fromCommand: "   \t\n  "))
    }

    func testDetectCodexResumeSubcommandStillReturnsCodex() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "codex resume 11111111-2222-3333-4444-555555555555"),
            .codex
        )
    }

    func testDetectTrailingWhitespace() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "claude --yolo   \n"),
            .claude
        )
    }

    func testDetectLeadingWhitespace() {
        XCTAssertEqual(
            ExternalAgentKind.detect(fromCommand: "    kimi"),
            .kimi
        )
    }

    func testDetectCaseSensitiveRejection() {
        // Executables are case-sensitive on unix-ish systems.
        XCTAssertNil(ExternalAgentKind.detect(fromCommand: "Claude"))
    }

    func testDetectClaudeCodeAliasNotSupported() {
        // `claude-code` is not a recognized executable name.
        XCTAssertNil(ExternalAgentKind.detect(fromCommand: "claude-code --resume 1"))
    }
}

// MARK: - sessionDirectory Tests

final class ExternalAgentKindSessionDirectoryTests: XCTestCase {

    func testClaudeSessionDirectory() {
        let url = ExternalAgentKind.claude.sessionDirectory
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.hasSuffix("/.claude/projects"), "got \(url!.path)")
    }

    func testCodexSessionDirectory() {
        let url = ExternalAgentKind.codex.sessionDirectory
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.hasSuffix("/.codex/sessions"), "got \(url!.path)")
    }

    func testGeminiSessionDirectoryNil() {
        XCTAssertNil(ExternalAgentKind.gemini.sessionDirectory)
    }

    func testKimiSessionDirectoryNil() {
        XCTAssertNil(ExternalAgentKind.kimi.sessionDirectory)
    }

    func testClaudeSlugBasic() {
        XCTAssertEqual(
            ExternalAgentKind.claudeSlug(forWorkingDirectory: "/Users/will/gui"),
            "-Users-will-gui"
        )
    }

    func testClaudeSlugTrailingSlash() {
        XCTAssertEqual(
            ExternalAgentKind.claudeSlug(forWorkingDirectory: "/Users/will/gui/"),
            "-Users-will-gui"
        )
    }

    func testClaudeSlugLeadingSlashOnly() {
        XCTAssertEqual(
            ExternalAgentKind.claudeSlug(forWorkingDirectory: "/"),
            "-"
        )
    }

    func testClaudeSlugWithDots() {
        XCTAssertEqual(
            ExternalAgentKind.claudeSlug(forWorkingDirectory: "/Users/will/my.project/src"),
            "-Users-will-my.project-src"
        )
    }

    func testClaudeSlugWithSpaces() {
        XCTAssertEqual(
            ExternalAgentKind.claudeSlug(forWorkingDirectory: "/Users/will/my project/src"),
            "-Users-will-my project-src"
        )
    }

    func testClaudeSlugEmptyYieldsEmpty() {
        XCTAssertEqual(ExternalAgentKind.claudeSlug(forWorkingDirectory: ""), "")
        XCTAssertEqual(ExternalAgentKind.claudeSlug(forWorkingDirectory: "   "), "")
    }

    func testClaudeSessionDirectoryForWorkingDirectory() {
        let url = ExternalAgentKind.claude.sessionDirectory(forWorkingDirectory: "/Users/will/gui")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.hasSuffix("/.claude/projects/-Users-will-gui"), "got \(url!.path)")
    }

    func testCodexSessionDirectoryForWorkingDirectoryNotPartitioned() {
        let anyCwd = "/Users/will/elsewhere"
        XCTAssertEqual(
            ExternalAgentKind.codex.sessionDirectory(forWorkingDirectory: anyCwd),
            ExternalAgentKind.codex.sessionDirectory
        )
    }

    func testGeminiSessionDirectoryForWorkingDirectoryNil() {
        XCTAssertNil(ExternalAgentKind.gemini.sessionDirectory(forWorkingDirectory: "/anything"))
    }

    func testKimiSessionDirectoryForWorkingDirectoryNil() {
        XCTAssertNil(ExternalAgentKind.kimi.sessionDirectory(forWorkingDirectory: "/anything"))
    }
}

// MARK: - sessionId(fromFilename:) Tests

final class ExternalAgentKindSessionIdFromFilenameTests: XCTestCase {

    private let validUUID = "12345678-1234-1234-1234-123456789abc"

    func testClaudeValidSessionFilename() {
        XCTAssertEqual(
            ExternalAgentKind.claude.sessionId(fromFilename: "\(validUUID).jsonl"),
            validUUID
        )
    }

    func testClaudeRejectsNonJsonlExtension() {
        XCTAssertNil(
            ExternalAgentKind.claude.sessionId(fromFilename: "\(validUUID).txt")
        )
    }

    func testClaudeRejectsMissingUUID() {
        XCTAssertNil(ExternalAgentKind.claude.sessionId(fromFilename: "not-a-uuid.jsonl"))
    }

    func testClaudeRejectsTooShortId() {
        XCTAssertNil(
            ExternalAgentKind.claude.sessionId(fromFilename: "1234-1234.jsonl")
        )
    }

    func testClaudeRejectsCodexRolloutPrefix() {
        let name = "rollout-2025-01-02-\(validUUID).jsonl"
        XCTAssertNil(ExternalAgentKind.claude.sessionId(fromFilename: name))
    }

    func testClaudeAcceptsUppercaseHex() {
        let uppercase = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        XCTAssertEqual(
            ExternalAgentKind.claude.sessionId(fromFilename: "\(uppercase).jsonl"),
            uppercase
        )
    }

    func testClaudeRejectsNonHex() {
        XCTAssertNil(
            ExternalAgentKind.claude.sessionId(fromFilename: "zzzzzzzz-1234-1234-1234-123456789abc.jsonl")
        )
    }

    func testClaudeRejectsExtraSegments() {
        let bad = "12345678-1234-1234-1234-1234-123456789abc"
        XCTAssertNil(
            ExternalAgentKind.claude.sessionId(fromFilename: "\(bad).jsonl")
        )
    }

    func testCodexValidRolloutFilename() {
        let name = "rollout-2025-04-21T13_30_00-\(validUUID).jsonl"
        XCTAssertEqual(
            ExternalAgentKind.codex.sessionId(fromFilename: name),
            validUUID
        )
    }

    func testCodexValidRolloutSimpleTimestamp() {
        let name = "rollout-1714000000-\(validUUID).jsonl"
        XCTAssertEqual(
            ExternalAgentKind.codex.sessionId(fromFilename: name),
            validUUID
        )
    }

    func testCodexRejectsMissingRolloutPrefix() {
        let name = "\(validUUID).jsonl"
        XCTAssertNil(ExternalAgentKind.codex.sessionId(fromFilename: name))
    }

    func testCodexRejectsNonJsonlExtension() {
        let name = "rollout-2025-04-21-\(validUUID).log"
        XCTAssertNil(ExternalAgentKind.codex.sessionId(fromFilename: name))
    }

    func testCodexRejectsNoUUID() {
        XCTAssertNil(
            ExternalAgentKind.codex.sessionId(fromFilename: "rollout-2025-04-21-notauuid.jsonl")
        )
    }

    func testGeminiSessionIdAlwaysNil() {
        XCTAssertNil(
            ExternalAgentKind.gemini.sessionId(fromFilename: "\(validUUID).jsonl")
        )
    }

    func testKimiSessionIdAlwaysNil() {
        XCTAssertNil(
            ExternalAgentKind.kimi.sessionId(fromFilename: "\(validUUID).jsonl")
        )
    }
}

// MARK: - supportsResume Tests

final class ExternalAgentKindSupportsResumeTests: XCTestCase {

    func testClaudeSupportsResume() {
        XCTAssertTrue(ExternalAgentKind.claude.supportsResume)
    }

    func testCodexSupportsResume() {
        XCTAssertTrue(ExternalAgentKind.codex.supportsResume)
    }

    func testGeminiDoesNotSupportResume() {
        XCTAssertFalse(ExternalAgentKind.gemini.supportsResume)
    }

    func testKimiDoesNotSupportResume() {
        XCTAssertFalse(ExternalAgentKind.kimi.supportsResume)
    }
}

// MARK: - resumeCommand Tests

final class ExternalAgentKindResumeCommandTests: XCTestCase {

    private let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    // --- Claude ---

    func testClaudeResumeBasic() {
        let out = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: "claude"
        )
        XCTAssertEqual(out, "claude --resume \(sessionId)")
    }

    func testClaudeResumePreservesFlags() {
        let out = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: "claude --dangerously-skip-permissions"
        )
        XCTAssertEqual(out, "claude --dangerously-skip-permissions --resume \(sessionId)")
    }

    func testClaudeResumePreservesPathPrefix() {
        let out = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: "/usr/local/bin/claude --dangerously-skip-permissions"
        )
        XCTAssertEqual(
            out,
            "/usr/local/bin/claude --dangerously-skip-permissions --resume \(sessionId)"
        )
    }

    func testClaudeResumePreservesEnvPrefix() {
        let out = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: "env FOO=1 claude --print"
        )
        XCTAssertEqual(out, "env FOO=1 claude --print --resume \(sessionId)")
    }

    func testClaudeResumeStripsExistingResume() {
        let out = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: "claude --resume old-id --print"
        )
        XCTAssertEqual(out, "claude --print --resume \(sessionId)")
    }

    func testClaudeResumeIdempotent() {
        let first = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: "claude"
        )
        let second = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: first
        )
        XCTAssertEqual(first, second)
    }

    func testClaudeResumeEmptySessionIdReturnsOriginal() {
        let original = "claude --print"
        XCTAssertEqual(
            ExternalAgentKind.claude.resumeCommand(sessionId: "", originalCommand: original),
            original
        )
    }

    func testClaudeResumeWhitespaceSessionIdReturnsOriginal() {
        let original = "claude --print"
        XCTAssertEqual(
            ExternalAgentKind.claude.resumeCommand(sessionId: "   ", originalCommand: original),
            original
        )
    }

    // --- Codex ---

    func testCodexResumeBasic() {
        let out = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: "codex"
        )
        XCTAssertEqual(out, "codex resume \(sessionId)")
    }

    func testCodexResumePreservesFlags() {
        let out = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: "codex --yolo"
        )
        XCTAssertEqual(out, "codex resume \(sessionId) --yolo")
    }

    func testCodexResumePreservesConfigFlag() {
        let out = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: "codex -c model_reasoning_effort=high --yolo"
        )
        XCTAssertEqual(
            out,
            "codex resume \(sessionId) -c model_reasoning_effort=high --yolo"
        )
    }

    func testCodexResumePreservesPathPrefix() {
        let out = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: "/opt/homebrew/bin/codex --yolo"
        )
        XCTAssertEqual(out, "/opt/homebrew/bin/codex resume \(sessionId) --yolo")
    }

    func testCodexResumePreservesEnvPrefix() {
        let out = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: "env OPENAI_API_KEY=x codex --yolo"
        )
        XCTAssertEqual(out, "env OPENAI_API_KEY=x codex resume \(sessionId) --yolo")
    }

    func testCodexResumeStripsExistingResumeSubcommand() {
        let out = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: "codex resume old-id --yolo"
        )
        XCTAssertEqual(out, "codex resume \(sessionId) --yolo")
    }

    func testCodexResumeIdempotent() {
        let first = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: "codex --yolo"
        )
        let second = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: first
        )
        XCTAssertEqual(first, second)
    }

    func testCodexResumeEmptySessionIdReturnsOriginal() {
        let original = "codex --yolo"
        XCTAssertEqual(
            ExternalAgentKind.codex.resumeCommand(sessionId: "", originalCommand: original),
            original
        )
    }

    // --- Gemini + Kimi ---

    func testGeminiResumeReturnsOriginalUnchanged() {
        let original = "gemini --yolo"
        XCTAssertEqual(
            ExternalAgentKind.gemini.resumeCommand(sessionId: sessionId, originalCommand: original),
            original
        )
    }

    func testKimiResumeReturnsOriginalUnchanged() {
        let original = "kimi --yolo"
        XCTAssertEqual(
            ExternalAgentKind.kimi.resumeCommand(sessionId: sessionId, originalCommand: original),
            original
        )
    }

    // --- Round-trip ---

    func testClaudeResumeRoundTripDetect() {
        let resumed = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: "claude --print"
        )
        XCTAssertEqual(ExternalAgentKind.detect(fromCommand: resumed), .claude)
    }

    func testCodexResumeRoundTripDetect() {
        let resumed = ExternalAgentKind.codex.resumeCommand(
            sessionId: sessionId,
            originalCommand: "codex --yolo"
        )
        XCTAssertEqual(ExternalAgentKind.detect(fromCommand: resumed), .codex)
    }

    func testClaudeResumeRoundTripWithEnvAndPath() {
        let resumed = ExternalAgentKind.claude.resumeCommand(
            sessionId: sessionId,
            originalCommand: "env FOO=1 /usr/local/bin/claude --print"
        )
        XCTAssertEqual(ExternalAgentKind.detect(fromCommand: resumed), .claude)
    }
}

// MARK: - Codable / rawValue Tests

final class ExternalAgentKindCodableTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(
            Set(ExternalAgentKind.allCases),
            Set([.claude, .codex, .gemini, .kimi])
        )
    }

    func testRawValues() {
        XCTAssertEqual(ExternalAgentKind.claude.rawValue, "claude")
        XCTAssertEqual(ExternalAgentKind.codex.rawValue, "codex")
        XCTAssertEqual(ExternalAgentKind.gemini.rawValue, "gemini")
        XCTAssertEqual(ExternalAgentKind.kimi.rawValue, "kimi")
    }

    func testCodableRoundTrip() throws {
        for kind in ExternalAgentKind.allCases {
            let encoded = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(ExternalAgentKind.self, from: encoded)
            XCTAssertEqual(decoded, kind)
        }
    }

    func testHashable() {
        let set: Set<ExternalAgentKind> = [.claude, .codex, .claude, .gemini]
        XCTAssertEqual(set.count, 3)
    }
}
