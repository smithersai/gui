import XCTest
@testable import SmithersGUI

// MARK: - Snapshot helpers

private func makeBlock(
    id: String? = nil,
    itemId: String? = nil,
    runId: String? = "run-snap",
    nodeId: String? = "task:render:0",
    attempt: Int? = 0,
    role: String,
    content: String,
    timestampMs: Int64? = nil
) -> ChatBlock {
    ChatBlock(
        id: id,
        itemId: itemId,
        runId: runId,
        nodeId: nodeId,
        attempt: attempt,
        role: role,
        content: content,
        timestampMs: timestampMs
    )
}

private func snapshot(_ blocks: [ChatBlock]) -> String {
    if blocks.isEmpty { return "(empty)" }
    return blocks.enumerated().map { idx, block in
        let lifecycle = block.lifecycleId ?? "<nil>"
        let role = block.role
        let content = block.content
        return "[\(idx)] role=\(role) lifecycle=\(lifecycle) content=\(content.debugDescription)"
    }.joined(separator: "\n")
}

private func filterSnapshot(role: String, content: String, regex: String? = nil) -> String {
    let block = makeBlock(role: role, content: content)
    let hidden = ChatBlockFilter.shouldHide(block, enabled: true, regexPattern: regex)
    let disabled = ChatBlockFilter.shouldHide(block, enabled: false, regexPattern: regex)
    return "role=\(role) content=\(content.debugDescription) enabled=true→hide=\(hidden) enabled=false→hide=\(disabled)"
}

#if os(macOS)
private func markdownSnapshot(_ markdown: String) -> String {
    MarkdownWebViewRepresentable.setContentScript(for: markdown)
}
#endif

// MARK: - Markdown rendering snapshots
//
// The Swift side of the markdown surface only owns the shell injection
// boundary: `setContentScript` JSON-encodes the markdown source so the JS
// shell can parse it safely. These snapshots pin the exact wire format —
// regressions in JSONEncoder behavior (escaping rules, key ordering, etc)
// or in the wrapping JS expression would surface immediately.

#if os(macOS)
final class MarkdownRenderingSnapshotTests: XCTestCase {
    func testHeaderH1Snapshot() {
        XCTAssertEqual(
            markdownSnapshot("# Heading 1"),
            #######"window.smithersMarkdown.setContent("# Heading 1");"#######
        )
    }

    func testHeaderH6Snapshot() {
        XCTAssertEqual(
            markdownSnapshot("###### Heading 6"),
            #######"window.smithersMarkdown.setContent("###### Heading 6");"#######
        )
    }

    func testAllHeaderLevelsSnapshot() {
        let md = "# h1\n## h2\n### h3\n#### h4\n##### h5\n###### h6"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("# h1\n## h2\n### h3\n#### h4\n##### h5\n###### h6");"#######
        )
    }

    func testNestedUnorderedListSnapshot() {
        let md = "- one\n  - one.a\n  - one.b\n- two"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("- one\n  - one.a\n  - one.b\n- two");"#######
        )
    }

    func testOrderedAndUnorderedMixedListSnapshot() {
        let md = "1. first\n   - sub a\n   - sub b\n2. second"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("1. first\n   - sub a\n   - sub b\n2. second");"#######
        )
    }

    func testFencedCodeBlockNoLanguageSnapshot() {
        let md = "```\nlet x = 1\n```"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("```\nlet x = 1\n```");"#######
        )
    }

    func testFencedCodeBlockWithLanguageSnapshot() {
        let md = "```swift\nlet y = 2\n```"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("```swift\nlet y = 2\n```");"#######
        )
    }

    func testInlineCodeSnapshot() {
        XCTAssertEqual(
            markdownSnapshot("Use `foo()` to call."),
            #######"window.smithersMarkdown.setContent("Use `foo()` to call.");"#######
        )
    }

    func testBoldItalicStrikeComboSnapshot() {
        let md = "**bold** _italic_ ~~strike~~ ***boldit***"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("**bold** _italic_ ~~strike~~ ***boldit***");"#######
        )
    }

    func testBlockquoteSnapshot() {
        let md = "> a quote\n> second line"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("> a quote\n> second line");"#######
        )
    }

    func testBlockquoteNestedInListSnapshot() {
        let md = "- item\n  > nested quote\n  > line two\n- next"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("- item\n  > nested quote\n  > line two\n- next");"#######
        )
    }

    func testLinkWithTitleSnapshot() {
        let md = #"[home](https://smithers.sh "Smithers Home")"#
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("[home](https:\/\/smithers.sh \"Smithers Home\")");"#######
        )
    }

    func testImageSnapshot() {
        let md = "![alt](https://example.com/x.png)"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("![alt](https:\/\/example.com\/x.png)");"#######
        )
    }

    func testHardLineBreakSnapshot() {
        let md = "first line  \nsecond line"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("first line  \nsecond line");"#######
        )
    }

    func testHorizontalRuleSnapshot() {
        XCTAssertEqual(
            markdownSnapshot("above\n\n---\n\nbelow"),
            #######"window.smithersMarkdown.setContent("above\n\n---\n\nbelow");"#######
        )
    }

    func testGFMTableSnapshot() {
        let md = "| col a | col b |\n| ----- | ----- |\n| 1     | 2     |"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("| col a | col b |\n| ----- | ----- |\n| 1     | 2     |");"#######
        )
    }

    func testTaskListSnapshot() {
        let md = "- [ ] todo\n- [x] done"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("- [ ] todo\n- [x] done");"#######
        )
    }

    func testAutolinkSnapshot() {
        let md = "see <https://smithers.sh> for docs"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("see <https:\/\/smithers.sh> for docs");"#######
        )
    }

    func testMixedTextAndCodeSnapshot() {
        let md = "intro line\n\n```js\nconsole.log(1);\n```\n\noutro line"
        XCTAssertEqual(
            markdownSnapshot(md),
            #######"window.smithersMarkdown.setContent("intro line\n\n```js\nconsole.log(1);\n```\n\noutro line");"#######
        )
    }

    func testEmptyMarkdownSnapshot() {
        XCTAssertEqual(
            markdownSnapshot(""),
            #######"window.smithersMarkdown.setContent("");"#######
        )
    }

    func testScriptInjectionMarkdownSnapshot() {
        // Documents the </script> escaping that lets us inline the script tag.
        XCTAssertEqual(
            markdownSnapshot("</script><script>alert(1)</script>"),
            #######"window.smithersMarkdown.setContent("<\/script><script>alert(1)<\/script>");"#######
        )
    }

    func testJSLineSeparatorInMarkdownIsEscaped() {
        // U+2028 LINE SEPARATOR breaks JS string literals pre-ES2019. The
        // production code now escapes these explicitly so injected JS stays
        // valid in any JS engine.
        let md = "line1\u{2028}line2"
        let expected = "window.smithersMarkdown.setContent(\"line1\\u2028line2\");"
        XCTAssertEqual(markdownSnapshot(md), expected)
    }

    func testJSParagraphSeparatorInMarkdownIsEscaped() {
        // U+2029 PARAGRAPH SEPARATOR — same hazard as U+2028.
        let md = "para1\u{2029}para2"
        let expected = "window.smithersMarkdown.setContent(\"para1\\u2029para2\");"
        XCTAssertEqual(markdownSnapshot(md), expected)
    }

    func testCombinedFormattingSnapshot() {
        let md = """
        # Mixed Document

        Intro **bold** with `code` and a [link](https://x).

        - one
        - two

        > quote here

        ```py
        print("hi")
        ```
        """
        let expected = #######"window.smithersMarkdown.setContent("# Mixed Document\n\nIntro **bold** with `code` and a [link](https:\/\/x).\n\n- one\n- two\n\n> quote here\n\n```py\nprint(\"hi\")\n```");"#######
        XCTAssertEqual(markdownSnapshot(md), expected)
    }
}
#endif

// MARK: - Chat block merger snapshots

final class ChatBlockMergerSnapshotTests: XCTestCase {
    func testEmptyInputSnapshot() {
        var merger = ChatBlockMerger()
        merger.append(contentsOf: [])
        XCTAssertEqual(snapshot(merger.blocks), "(empty)")
    }

    func testSingleBlockSnapshot() {
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: "only", role: "assistant", content: "hello"))
        XCTAssertEqual(
            snapshot(merger.blocks),
            #"[0] role=assistant lifecycle=only content="hello""#
        )
    }

    func testTwoAdjacentSameLifecycleAssistantBlocksMergeSnapshot() {
        // Same lifecycle id + assistant role + streaming-overlap → merge.
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: "stream-1", role: "assistant", content: "Hel"))
        merger.append(makeBlock(id: "stream-1", role: "assistant", content: "Hello"))
        XCTAssertEqual(
            snapshot(merger.blocks),
            #"[0] role=assistant lifecycle=stream-1 content="Hello""#
        )
    }

    func testTwoAdjacentDifferentLifecycleBlocksDoNotMergeSnapshot() {
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: "a", role: "assistant", content: "one"))
        merger.append(makeBlock(id: "b", role: "assistant", content: "two"))
        XCTAssertEqual(
            snapshot(merger.blocks),
            """
            [0] role=assistant lifecycle=a content="one"
            [1] role=assistant lifecycle=b content="two"
            """
        )
    }

    func testTwoAdjacentDifferentRoleBlocksDoNotMergeSnapshot() {
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: "x", role: "user", content: "hi"))
        merger.append(makeBlock(id: "y", role: "assistant", content: "hello"))
        XCTAssertEqual(
            snapshot(merger.blocks),
            """
            [0] role=user lifecycle=x content="hi"
            [1] role=assistant lifecycle=y content="hello"
            """
        )
    }

    func testInterleavedWithWhitespaceGapsSnapshot() {
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: "a", role: "assistant", content: "hello"))
        merger.append(makeBlock(id: "b", role: "system", content: "  "))
        merger.append(makeBlock(id: "c", role: "assistant", content: "world"))
        XCTAssertEqual(
            snapshot(merger.blocks),
            """
            [0] role=assistant lifecycle=a content="hello"
            [1] role=system lifecycle=b content="  "
            [2] role=assistant lifecycle=c content="world"
            """
        )
    }

    func testThousandUniqueBlocksSnapshotShape() {
        var merger = ChatBlockMerger()
        for i in 0..<1_000 {
            merger.append(makeBlock(id: "id-\(i)", role: "system", content: "msg-\(i)"))
        }
        XCTAssertEqual(merger.blocks.count, 1_000)
        // Snapshot just the first and last lines of the shape — pinning all
        // 1000 lines would balloon the test file with no extra signal.
        let lines = snapshot(merger.blocks).split(separator: "\n")
        XCTAssertEqual(lines.first.map(String.init), #"[0] role=system lifecycle=id-0 content="msg-0""#)
        XCTAssertEqual(lines.last.map(String.init), #"[999] role=system lifecycle=id-999 content="msg-999""#)
    }

    func testUnicodeContentSnapshot() {
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: "u1", role: "assistant", content: "你好 😀"))
        merger.append(makeBlock(id: "u2", role: "assistant", content: "привет мир"))
        XCTAssertEqual(
            snapshot(merger.blocks),
            """
            [0] role=assistant lifecycle=u1 content="你好 😀"
            [1] role=assistant lifecycle=u2 content="привет мир"
            """
        )
    }

    func testEmptyContentBlockSnapshot() {
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: "empty", role: "system", content: ""))
        XCTAssertEqual(
            snapshot(merger.blocks),
            #"[0] role=system lifecycle=empty content="""#
        )
    }

    func testMissingLifecycleIdsAppendDistinctSnapshot() {
        // No lifecycle id → no merge attempt → both retained.
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: nil, itemId: nil, role: "tool", content: "call A"))
        merger.append(makeBlock(id: nil, itemId: nil, role: "tool", content: "call B"))
        XCTAssertEqual(
            snapshot(merger.blocks),
            """
            [0] role=tool lifecycle=<nil> content="call A"
            [1] role=tool lifecycle=<nil> content="call B"
            """
        )
    }

    func testSameLifecycleNonAssistantReplacesSnapshot() {
        var merger = ChatBlockMerger()
        merger.append(makeBlock(id: "k", role: "system", content: "old"))
        merger.append(makeBlock(id: "k", role: "system", content: "new"))
        XCTAssertEqual(
            snapshot(merger.blocks),
            #"[0] role=system lifecycle=k content="new""#
        )
    }
}

// MARK: - Chat block filter snapshots

final class ChatBlockFilterSnapshotTests: XCTestCase {
    func testStderrWarningHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "warning: deprecated foo"),
            #"role=stderr content="warning: deprecated foo" enabled=true→hide=true enabled=false→hide=false"#
        )
    }

    func testStderrCodexCoreErrorHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "ERROR codex_core::session: boom"),
            #"role=stderr content="ERROR codex_core::session: boom" enabled=true→hide=true enabled=false→hide=false"#
        )
    }

    func testStderrCodexAnyErrorHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "ERROR codex_runtime: boom"),
            #"role=stderr content="ERROR codex_runtime: boom" enabled=true→hide=true enabled=false→hide=false"#
        )
    }

    func testStderrStateDbMissingRolloutHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "state db missing rollout path: /tmp/x"),
            #"role=stderr content="state db missing rollout path: /tmp/x" enabled=true→hide=true enabled=false→hide=false"#
        )
    }

    func testStderrIsoTimestampedErrorHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "2025-04-25T12:34:56.789Z ERROR something failed"),
            #"role=stderr content="2025-04-25T12:34:56.789Z ERROR something failed" enabled=true→hide=true enabled=false→hide=false"#
        )
    }

    func testSystemEmptyHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "system", content: "   \n\n   "),
            "role=system content=\"   \\n\\n   \" enabled=true→hide=true enabled=false→hide=false"
        )
    }

    func testStatusOnlyWhitespaceHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "status", content: ""),
            #"role=status content="" enabled=true→hide=true enabled=false→hide=false"#
        )
    }

    func testNoMatchAssistantNotHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "assistant", content: "warning: this is content"),
            #"role=assistant content="warning: this is content" enabled=true→hide=false enabled=false→hide=false"#
        )
    }

    func testNoMatchUserNotHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "user", content: "ERROR codex_core::foo"),
            #"role=user content="ERROR codex_core::foo" enabled=true→hide=false enabled=false→hide=false"#
        )
    }

    func testNoMatchToolNotHiddenSnapshot() {
        XCTAssertEqual(
            filterSnapshot(role: "tool", content: "warning: x"),
            #"role=tool content="warning: x" enabled=true→hide=false enabled=false→hide=false"#
        )
    }

    func testStderrMixedMatchAndNonMatchHiddenOnlyIfAllLinesMatchSnapshot() {
        // Default rule requires ALL non-empty lines to match → mixed input
        // remains visible.
        let mixed = "warning: foo\nthis line is real output"
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: mixed),
            "role=stderr content=\"warning: foo\\nthis line is real output\" enabled=true→hide=false enabled=false→hide=false"
        )
    }

    func testStderrAllMatchingMultilineHiddenSnapshot() {
        let multi = "warning: a\nwarning: b\nERROR codex_core::x: y"
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: multi),
            "role=stderr content=\"warning: a\\nwarning: b\\nERROR codex_core::x: y\" enabled=true→hide=true enabled=false→hide=false"
        )
    }

    func testStderrContextBeforeWarningNotHiddenSnapshot() {
        // Default regex is anchored — leading context disqualifies the line.
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "context before warning: foo"),
            #"role=stderr content="context before warning: foo" enabled=true→hide=false enabled=false→hide=false"#
        )
    }

    func testStderrVeryLongInputAllMatchingSnapshot() {
        let lines = (0..<5_000).map { _ in "warning: noisy" }.joined(separator: "\n")
        let block = makeBlock(role: "stderr", content: lines)
        XCTAssertTrue(ChatBlockFilter.shouldHide(block, enabled: true))
    }

    func testStderrVeryLongInputOneNonMatchingLineKeepsVisibleSnapshot() {
        var lines = Array(repeating: "warning: noisy", count: 5_000)
        lines.append("RealOutput: keep me visible")
        let block = makeBlock(role: "stderr", content: lines.joined(separator: "\n"))
        XCTAssertFalse(ChatBlockFilter.shouldHide(block, enabled: true))
    }

    func testRegexDOSBaitDoesNotHangFilter() {
        // Pathological "evil regex" pattern paired with input that historically
        // triggers catastrophic backtracking. We only assert the filter
        // returns within a reasonable wall-clock bound and produces a stable
        // boolean — never that the whole process freezes.
        // We use n=18: the pattern still ramps backtracking exponentially,
        // but the wall-clock budget stays under a second on every supported
        // platform. The point is to lock in *finite* completion behavior —
        // not to actually defeat ReDoS — so a future regression to a
        // truly-blocking matcher would surface.
        let evilPattern = #"^(a+)+b$"#
        let evilInput = String(repeating: "a", count: 18) + "c"
        let block = makeBlock(role: "stderr", content: evilInput)
        let started = Date()
        _ = ChatBlockFilter.shouldHide(block, enabled: true, regexPattern: evilPattern)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5.0, "regex evaluation should not catastrophically backtrack")
    }

    func testCustomRegexHidesOnlyMatchingSnapshot() {
        let pattern = #"^DEBUG\s+.+$"#
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "DEBUG something happened", regex: pattern),
            #"role=stderr content="DEBUG something happened" enabled=true→hide=true enabled=false→hide=false"#
        )
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "INFO something happened", regex: pattern),
            #"role=stderr content="INFO something happened" enabled=true→hide=false enabled=false→hide=false"#
        )
    }

    func testInvalidCustomRegexFallsBackToDefaultSnapshot() {
        // Unbalanced parentheses → invalid regex → default rules still apply.
        XCTAssertEqual(
            filterSnapshot(role: "stderr", content: "warning: foo", regex: "("),
            #"role=stderr content="warning: foo" enabled=true→hide=true enabled=false→hide=false"#
        )
    }
}
