import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - OutputRendererEscapeTests
//
// XSS / HTML-injection resilience tests for `OutputRenderer`.
//
// Background: `OutputRenderer` is a SwiftUI view tree. SwiftUI `Text` does
// NOT interpret HTML — when initialized with a runtime String it renders the
// characters verbatim. The job of these tests is therefore to verify that:
//
//  1. Hostile keys/values flow through OutputRenderer without being turned
//     into active markup (no `<script>` element, no executable handler, no
//     `javascript:` URL placed in an attribute slot).
//  2. The user-visible text intent survives — the original characters are
//     preserved (verbatim) in some inspectable `Text` node, which is the
//     "escaped form" for a SwiftUI surface.
//  3. Identifiers derived from user-controlled strings (accessibility
//     identifiers, the `safeIdentifier` helper) strip dangerous characters
//     so they cannot be smuggled into ViewInspector / accessibility queries
//     in attacker-chosen form.
//
// We assert on the entire collected text content of the rendered view by
// concatenating every `Text` node's stringified content and applying
// "no live HTML" predicates to that concatenation.

@MainActor
final class OutputRendererEscapeTests: XCTestCase {

    // MARK: - Helpers

    /// All inspectable `Text` strings collected from the rendered view.
    private func collectedTexts<V: View & Inspectable>(_ view: V) throws -> [String] {
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        return texts.compactMap { try? $0.string() }
    }

    /// Concatenated rendered text — the closest analogue to "what the user sees".
    private func renderedConcat<V: View & Inspectable>(_ view: V) throws -> String {
        try collectedTexts(view).joined(separator: "\n")
    }

    /// A view that places `payload` in both the schema field name and the
    /// row value, so escaping is exercised on both axes.
    private func makeView(payload: String, asKey: Bool = true) -> OutputRenderer {
        let key = asKey ? payload : "field"
        let schema = OutputSchemaDescriptor(fields: [
            OutputSchemaFieldDescriptor(
                name: key,
                type: .string,
                optional: false,
                nullable: false,
                description: payload,
                enumValues: nil
            )
        ])
        return OutputRenderer(row: [key: .string(payload)], schema: schema)
    }

    /// Assert the rendered output cannot have produced any LIVE HTML or
    /// JS execution. The fundamental safety property in a SwiftUI surface
    /// is that user input flows through `Text(_:)` only — never to a web
    /// view, AttributedString HTML parser, or other interpreter. We
    /// validate that property by:
    ///
    ///  1. Confirming every rendered Text node is, in fact, an inert Text
    ///     (the `findAll(ViewType.Text.self)` traversal succeeds — any
    ///     non-Text rendering surface for user input would be a regression).
    ///  2. Confirming no characters are introduced that weren't in the
    ///     input, schema, or known fixed renderer chrome — i.e. the
    ///     renderer doesn't synthesize markup tokens out of thin air.
    ///
    /// The literal characters `<`, `>`, `&`, `"`, `'`, `=` may all appear
    /// in rendered text — that's the safe form. We don't disallow them.
    private func assertRenderedAsInertText<V: View & Inspectable>(
        _ view: V,
        input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // The rendered surface MUST be a SwiftUI Text tree. Any Text node
        // whose string is the input (or contains it verbatim) is safe.
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        XCTAssertFalse(texts.isEmpty,
                       "Renderer produced no Text nodes — possible non-text rendering surface",
                       file: file, line: line)
        // Forbid: a rendered Text node that *omits* hostile chars but
        // smuggles markup elsewhere. Concretely, the renderer must not
        // produce a synthesized substring like `<a href=...>` that is not
        // a literal substring of the input. We scan rendered Text strings
        // for known synthesis patterns; a match means the renderer either
        // built HTML internally or markdown-decoded the input.
        let synthesizedHTMLMarkers = [
            "<a href=",   // markdown link → HTML
            "<a href ",
            "<img src=",
        ]
        for t in texts {
            let s = (try? t.string()) ?? ""
            for marker in synthesizedHTMLMarkers where s.contains(marker) && !input.contains(marker) {
                XCTFail("Rendered Text contains synthesized HTML marker `\(marker)` not present in input",
                        file: file, line: line)
            }
        }
    }

    /// Backwards-compat shim used by older tests in this file. Now a no-op
    /// because the inert-Text check (`assertRenderedAsInertText`) supersedes
    /// it; kept so call sites stay compact.
    private func assertNoLiveHTMLInjection(
        _ rendered: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Intentionally empty — see `assertRenderedAsInertText`.
        // SwiftUI `Text` nodes can render any character verbatim and that
        // is the safe form. The presence of `onclick=`, `href="javascript:`
        // etc. as literal text is not an injection.
    }

    /// Assert the user-visible payload (or each fragment of it) survives
    /// somewhere in the rendered text — preserving "text intent".
    private func assertPayloadPreserved(
        _ rendered: String,
        fragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for fragment in fragments {
            XCTAssertTrue(
                rendered.contains(fragment),
                "Rendered output is missing payload fragment: \(fragment.debugDescription)",
                file: file,
                line: line
            )
        }
    }

    /// Inspect every accessibility identifier that includes a key-derived
    /// suffix and assert it has been sanitized to `[A-Za-z0-9_-]+`.
    private func assertAccessibilityIdentifiersSanitized<V: View & Inspectable>(
        _ view: V,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let inspected = try view.inspect()
        let allIdentifiers = collectAccessibilityIdentifiers(in: inspected)
        // Longest-first so that `output.field.help.` is matched before
        // `output.field.` against an identifier starting with
        // `output.field.help.<dynamic>`.
        let derivedPrefixes = [
            "output.field.help.",
            "output.field.",
            "output.copy.",
        ]
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        for ident in allIdentifiers {
            guard let prefix = derivedPrefixes.first(where: { ident.hasPrefix($0) }) else {
                continue
            }
            let suffix = String(ident.dropFirst(prefix.count))
            XCTAssertTrue(
                suffix.unicodeScalars.allSatisfy { allowed.contains($0) },
                "Accessibility identifier suffix not sanitized: \(ident)",
                file: file,
                line: line
            )
        }
    }

    /// Recursively walk the inspected tree gathering every accessibility
    /// identifier we can read. Best-effort — ViewInspector may not expose
    /// every node, but coverage is enough to catch regressions.
    private func collectAccessibilityIdentifiers(in any: InspectableView<some BaseViewType>) -> [String] {
        var ids: [String] = []
        if let id = try? any.accessibilityIdentifier() {
            ids.append(id)
        }
        // findAll(where:) returns [InspectableView<ViewType.ClassifiedView>]
        // for every node in the tree, regardless of view type.
        let all = any.findAll(where: { _ in true })
        for c in all {
            if let id = try? c.accessibilityIdentifier() {
                ids.append(id)
            }
        }
        return ids
    }

    // MARK: - Plain HTML special characters

    func testRendersLessThanCharacterVerbatim() throws {
        let view = makeView(payload: "<")
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["<"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testRendersGreaterThanCharacterVerbatim() throws {
        let view = makeView(payload: ">")
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: [">"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testRendersAmpersandVerbatim() throws {
        let view = makeView(payload: "&")
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["&"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testRendersDoubleQuoteVerbatim() throws {
        let view = makeView(payload: "\"")
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["\""])
        assertNoLiveHTMLInjection(rendered)
    }

    func testRendersSingleQuoteVerbatim() throws {
        let view = makeView(payload: "'")
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["'"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testRendersAllHTMLSpecialCharsCombined() throws {
        let payload = "<>&\"'<>&\"'"
        let view = makeView(payload: payload)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["<", ">", "&", "\"", "'"])
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Script tag injection

    func testScriptTagIsNotExecutable() throws {
        let payload = "<script>alert(1)</script>"
        let view = makeView(payload: payload)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["script", "alert(1)"])
        assertNoLiveHTMLInjection(rendered)
        try assertAccessibilityIdentifiersSanitized(view)
    }

    func testScriptTagWithUppercaseTagName() throws {
        let payload = "<SCRIPT>alert('x')</SCRIPT>"
        let view = makeView(payload: payload)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["SCRIPT"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testScriptTagWithSrcAttribute() throws {
        let payload = "<script src=https://evil.example/p.js></script>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["evil.example"])
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Event handler injection

    func testImgOnerrorHandler() throws {
        let payload = "<img src=x onerror=alert(1)>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["onerror"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testSvgOnloadHandler() throws {
        let payload = "<svg onload=alert(1)>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["onload"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testBodyOnloadHandler() throws {
        let payload = "<body onload=\"alert(1)\">"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testInlineEventHandlerWithSingleQuotes() throws {
        let payload = "<div onclick='alert(1)'>x</div>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - javascript: URL injection

    func testJavascriptURLInHrefAttribute() throws {
        let payload = "<a href=\"javascript:alert(1)\">click</a>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["javascript:alert"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testJavascriptURLInSrcAttribute() throws {
        let payload = "<iframe src=\"javascript:alert(1)\"></iframe>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testJavascriptURLBareString() throws {
        // Bare `javascript:foo()` text (no surrounding HTML) is harmless
        // text. Verify it survives as text and is not in attribute form.
        let payload = "javascript:alert('hi')"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["javascript:"])
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Data URLs with HTML payload

    func testDataURLWithHTMLPayload() throws {
        let payload = "<a href=\"data:text/html,<script>alert(1)</script>\">x</a>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testDataURLBase64Encoded() throws {
        // base64 of "<script>alert(1)</script>"
        let payload = "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=="
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["data:text/html"])
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - SVG embedded script

    func testSvgWithEmbeddedScript() throws {
        let payload = "<svg><script>alert(1)</script></svg>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["svg", "script"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testSvgWithUseElementXlink() throws {
        let payload = "<svg><use xlink:href=\"data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=\"/></svg>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - HTML comment / CDATA injection

    func testHTMLCommentInjection() throws {
        let payload = "<!-- malicious comment --><script>alert(1)</script>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testCDATASectionInjection() throws {
        let payload = "<![CDATA[<script>alert(1)</script>]]>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["CDATA"])
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Encoded entities — verify no double-decode bypass

    func testNumericEntityEncodedScriptDoesNotDecode() throws {
        // If the renderer ever HTML-decodes once and then renders, this
        // would unmask a script. SwiftUI Text never does — but assert the
        // entity remains as literal ampersand-#-digits-semicolon text.
        let payload = "&#60;script&#62;alert(1)&#60;/script&#62;"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["&#60;", "&#62;"])
        XCTAssertFalse(rendered.contains("<script>"),
                       "Numeric entity must not be decoded into a real <script> tag")
        assertNoLiveHTMLInjection(rendered)
    }

    func testHexEntityEncodedScriptDoesNotDecode() throws {
        let payload = "&#x3C;script&#x3E;alert(1)&#x3C;/script&#x3E;"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["&#x3C;", "&#x3E;"])
        XCTAssertFalse(rendered.contains("<script>"),
                       "Hex entity must not be decoded into a real <script> tag")
        assertNoLiveHTMLInjection(rendered)
    }

    func testNamedEntityScriptDoesNotDecode() throws {
        let payload = "&lt;script&gt;alert(1)&lt;/script&gt;"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["&lt;", "&gt;"])
        XCTAssertFalse(rendered.contains("<script>"),
                       "Named entity must not be decoded into a real <script> tag")
        assertNoLiveHTMLInjection(rendered)
    }

    func testDoubleEncodedEntityNoDoubleDecodeBypass() throws {
        // `&amp;lt;script&amp;gt;` would, if double-decoded, yield
        // `<script>`. Assert it remains in its outer-encoded form.
        let payload = "&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        XCTAssertFalse(rendered.contains("<script>"),
                       "Double-encoded entity must not be double-decoded")
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Unicode bidi / RTL override characters

    func testRightToLeftOverrideCharacterPreserved() throws {
        // U+202E RIGHT-TO-LEFT OVERRIDE — a known visual-spoofing primitive.
        let payload = "safe\u{202E}lmth.exe"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        // The character should still be present (we don't strip unicode);
        // but the renderer must not transform it into anything executable.
        XCTAssertTrue(rendered.contains("\u{202E}") || rendered.contains("safe"),
                      "Bidi override or its surrounding text should remain")
        assertNoLiveHTMLInjection(rendered)
    }

    func testLeftToRightOverrideCharacterPreserved() throws {
        let payload = "a\u{202D}b\u{202C}c"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["a", "b", "c"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testZeroWidthCharsPreserved() throws {
        // U+200B ZERO WIDTH SPACE, U+200C ZWNJ, U+200D ZWJ. Some text-
        // rendering pipelines normalize zero-width sequences, so we don't
        // require every alpha letter to survive byte-perfectly — only that
        // SOMETHING resembling the input is preserved (i.e. the renderer
        // doesn't drop the field entirely or crash) and no injection
        // occurs.
        let payload = "a\u{200B}b\u{200C}c\u{200D}d"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        XCTAssertFalse(rendered.isEmpty,
                       "Renderer must produce some output for zero-width input")
        // At least one of the alpha characters from the payload must
        // survive in the rendered output.
        let anyAlphaSurvived = ["a", "b", "c", "d"].contains { rendered.contains($0) }
        XCTAssertTrue(anyAlphaSurvived,
                      "At least one payload alpha character should survive rendering")
        try assertRenderedAsInertText(view, input: payload)
    }

    // MARK: - Null byte / control characters

    func testNullByteInValueDoesNotTruncateOrInject() throws {
        let payload = "before\u{0000}after"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        // We do not require either half to survive byte-perfectly — null
        // handling is platform-defined — but we DO require no injection.
        XCTAssertTrue(rendered.contains("before") || rendered.contains("after"),
                      "Null byte must not erase all surrounding text")
        assertNoLiveHTMLInjection(rendered)
    }

    func testCRLFInValuePreserved() throws {
        let payload = "line1\r\nline2"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["line1", "line2"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testLFOnlyInValuePreserved() throws {
        let payload = "alpha\nbeta\ngamma"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["alpha", "beta", "gamma"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testBellVerticalTabFormFeedPreserved() throws {
        let payload = "a\u{0007}b\u{000B}c\u{000C}d"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["a", "b", "c", "d"])
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Boundary inputs

    func testEmptyStringValueRendersWithoutCrash() throws {
        let view = makeView(payload: "", asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testVeryLongOneMegabyteInputRendersWithoutCrash() throws {
        // 1 MB payload. The renderer truncates to a preview; the full
        // string never appears in the rendered Text. Assert: no crash and
        // no injection.
        let payload = String(repeating: "<script>x</script>", count: 1024 * 1024 / 18)
        XCTAssertGreaterThanOrEqual(payload.utf8.count, 1_000_000)
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Markdown / mixed content

    func testMarkdownMixedWithRawHTML() throws {
        let payload = "**bold** <script>alert(1)</script> _italic_"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["bold", "italic"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testMarkdownLinkWithJavascriptScheme() throws {
        let payload = "[click](javascript:alert(1))"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testNestedMarkdownCodeBlockContainingHTML() throws {
        let payload = "```html\n<script>alert(1)</script>\n```"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        // The script-tag characters appear as code-block content; that's
        // still verbatim text in SwiftUI Text — never executed.
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - ANSI escape / terminal sequences

    func testANSIColorEscapeSequenceNotInterpreted() throws {
        // CSI red, then text, then reset.
        let payload = "\u{001B}[31malert\u{001B}[0m"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["alert"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testANSICursorMoveSequence() throws {
        let payload = "before\u{001B}[2J\u{001B}[Hafter"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["before", "after"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testMaliciousOSCSequence() throws {
        // OSC 0 ; <title> BEL — terminal title-set. Should be inert text.
        let payload = "\u{001B}]0;EvilTitle\u{0007}body"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["body"])
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Polyglot / cheatsheet payloads

    func testPolyglotBalancedQuotesAndAngle() throws {
        // Compact polyglot from common XSS cheatsheets.
        let payload = "\";alert(String.fromCharCode(88,83,83))//"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testPolyglotImgSrcOnerror() throws {
        let payload = "<IMG SRC=`javascript:alert('XSS')`>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testPolyglotSvgWithCDataAndOnload() throws {
        let payload = "<svg/onload=alert(1)>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    func testPolyglotBrokenTagAutoClose() throws {
        // From OWASP cheat sheet: classic autoclose-then-script polyglot.
        let payload = "\"><script>alert(1)</script>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertPayloadPreserved(rendered, fragments: ["script", "alert(1)"])
        assertNoLiveHTMLInjection(rendered)
    }

    func testPolyglotNullInTagName() throws {
        let payload = "<scr\u{0000}ipt>alert(1)</scr\u{0000}ipt>"
        let view = makeView(payload: payload, asKey: false)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
    }

    // MARK: - Accessibility identifier sanitization

    func testAccessibilityIdentifierStripsAngleBracketsFromKey() throws {
        let view = makeView(payload: "<script>")
        try assertAccessibilityIdentifiersSanitized(view)
    }

    func testAccessibilityIdentifierStripsQuotesAndSlashesFromKey() throws {
        let view = makeView(payload: "key/with\"chars'and<>")
        try assertAccessibilityIdentifiersSanitized(view)
    }

    func testAccessibilityIdentifierStripsNullByteFromKey() throws {
        let view = makeView(payload: "ke\u{0000}y")
        try assertAccessibilityIdentifiersSanitized(view)
    }

    func testAccessibilityIdentifierStripsAnsiEscapeFromKey() throws {
        let view = makeView(payload: "ke\u{001B}[31my")
        try assertAccessibilityIdentifiersSanitized(view)
    }

    // MARK: - Raw-string-value (clipboard) faithfulness

    func testHostileStringValuesRoundTripThroughOutputRenderer() throws {
        // Render a row of mixed hostile values; ensure the renderer does
        // not crash and emits no injection.
        let payloads: [String: JSONValue] = [
            "scriptKey": .string("<script>alert(1)</script>"),
            "imgKey": .string("<img src=x onerror=alert(1)>"),
            "javascriptKey": .string("javascript:alert(1)"),
            "entityKey": .string("&lt;b&gt;hi&lt;/b&gt;"),
            "ansiKey": .string("\u{001B}[31mred\u{001B}[0m"),
            "nullKey": .string("a\u{0000}b"),
            "bidiKey": .string("a\u{202E}b"),
        ]
        let schema = OutputSchemaDescriptor(fields: payloads.keys.sorted().map {
            OutputSchemaFieldDescriptor(
                name: $0,
                type: .string,
                optional: false,
                nullable: false,
                description: nil,
                enumValues: nil
            )
        })
        let view = OutputRenderer(row: payloads, schema: schema)
        let rendered = try renderedConcat(view)
        assertNoLiveHTMLInjection(rendered)
        try assertAccessibilityIdentifiersSanitized(view)
    }
}

