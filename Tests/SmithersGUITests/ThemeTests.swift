import XCTest
import SwiftUI
@testable import SmithersGUI

// MARK: - Helper to extract sRGB components from a Color

private extension Color {
    /// Resolves the color in a dark appearance and returns (red, green, blue, opacity) in 0...1.
    func rgbaComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let nsColor = NSColor(self).usingColorSpace(.sRGB)
            ?? NSColor(self).usingColorSpace(.deviceRGB)
            ?? NSColor(self)
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}

private func projectSource(_ filename: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let projectDirectory = testsDirectory
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = projectDirectory.appendingPathComponent(filename)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

// MARK: - THEME_COLOR_BASE through THEME_COLOR_SYN_COMMENT

final class ThemeColorExistenceTests: XCTestCase {

    // Every static color must be non-nil and resolve to a real value.
    // We access each property and confirm the resolved RGBA has finite components.

    private func assertColorIsValid(_ color: Color, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let c = color.rgbaComponents()
        XCTAssertTrue(c.r.isFinite, "\(name) red is not finite", file: file, line: line)
        XCTAssertTrue(c.g.isFinite, "\(name) green is not finite", file: file, line: line)
        XCTAssertTrue(c.b.isFinite, "\(name) blue is not finite", file: file, line: line)
        XCTAssertTrue(c.a.isFinite, "\(name) alpha is not finite", file: file, line: line)
    }

    func testBaseExists()             { assertColorIsValid(Theme.base, "base") }
    func testSurface1Exists()         { assertColorIsValid(Theme.surface1, "surface1") }
    func testSurface2Exists()         { assertColorIsValid(Theme.surface2, "surface2") }
    func testBorderExists()           { assertColorIsValid(Theme.border, "border") }
    func testSidebarBgExists()        { assertColorIsValid(Theme.sidebarBg, "sidebarBg") }
    func testSidebarHoverExists()     { assertColorIsValid(Theme.sidebarHover, "sidebarHover") }
    func testSidebarSelectedExists()  { assertColorIsValid(Theme.sidebarSelected, "sidebarSelected") }
    func testPillBgExists()           { assertColorIsValid(Theme.pillBg, "pillBg") }
    func testPillBorderExists()       { assertColorIsValid(Theme.pillBorder, "pillBorder") }
    func testPillActiveExists()       { assertColorIsValid(Theme.pillActive, "pillActive") }
    func testTitlebarBgExists()       { assertColorIsValid(Theme.titlebarBg, "titlebarBg") }
    func testTitlebarFgExists()       { assertColorIsValid(Theme.titlebarFg, "titlebarFg") }
    func testBubbleAssistantExists()  { assertColorIsValid(Theme.bubbleAssistant, "bubbleAssistant") }
    func testBubbleUserExists()       { assertColorIsValid(Theme.bubbleUser, "bubbleUser") }
    func testBubbleCommandExists()    { assertColorIsValid(Theme.bubbleCommand, "bubbleCommand") }
    func testBubbleStatusExists()     { assertColorIsValid(Theme.bubbleStatus, "bubbleStatus") }
    func testBubbleDiffExists()       { assertColorIsValid(Theme.bubbleDiff, "bubbleDiff") }
    func testInputBgExists()          { assertColorIsValid(Theme.inputBg, "inputBg") }
    func testAccentExists()           { assertColorIsValid(Theme.accent, "accent") }
    func testSuccessExists()          { assertColorIsValid(Theme.success, "success") }
    func testWarningExists()          { assertColorIsValid(Theme.warning, "warning") }
    func testDangerExists()           { assertColorIsValid(Theme.danger, "danger") }
    func testInfoExists()             { assertColorIsValid(Theme.info, "info") }
    func testTextPrimaryExists()      { assertColorIsValid(Theme.textPrimary, "textPrimary") }
    func testTextSecondaryExists()    { assertColorIsValid(Theme.textSecondary, "textSecondary") }
    func testTextTertiaryExists()     { assertColorIsValid(Theme.textTertiary, "textTertiary") }
    func testSynKeywordExists()       { assertColorIsValid(Theme.synKeyword, "synKeyword") }
    func testSynStringExists()        { assertColorIsValid(Theme.synString, "synString") }
    func testSynFunctionExists()      { assertColorIsValid(Theme.synFunction, "synFunction") }
    func testSynCommentExists()       { assertColorIsValid(Theme.synComment, "synComment") }
}

// MARK: - PLATFORM_HEX_COLOR_EXTENSION

final class ColorHexInitTests: XCTestCase {

    private let accuracy: CGFloat = 1.0 / 255.0

    // --- 6-digit hex ---

    func testSixDigitHex_white() {
        let c = Color(hex: "#FFFFFF").rgbaComponents()
        XCTAssertEqual(c.r, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy)
    }

    func testSixDigitHex_black() {
        let c = Color(hex: "#000000").rgbaComponents()
        XCTAssertEqual(c.r, 0.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 0.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 0.0, accuracy: accuracy)
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy)
    }

    func testSixDigitHex_red() {
        let c = Color(hex: "#FF0000").rgbaComponents()
        XCTAssertEqual(c.r, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 0.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 0.0, accuracy: accuracy)
    }

    func testSixDigitHex_withoutHash() {
        let c = Color(hex: "4C8DFF").rgbaComponents()
        XCTAssertEqual(c.r, 0x4C / 255.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 0x8D / 255.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 0xFF / 255.0, accuracy: accuracy)
    }

    func testSixDigitHex_accent() {
        // Theme.accent is #4C8DFF
        let c = Color(hex: "#4C8DFF").rgbaComponents()
        XCTAssertEqual(c.r, 0x4C / 255.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 0x8D / 255.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 0xFF / 255.0, accuracy: accuracy)
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy)
    }

    // --- 3-digit hex ---

    func testThreeDigitHex_white() {
        // #FFF should expand to #FFFFFF
        let c = Color(hex: "#FFF").rgbaComponents()
        XCTAssertEqual(c.r, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy)
    }

    func testThreeDigitHex_black() {
        let c = Color(hex: "#000").rgbaComponents()
        XCTAssertEqual(c.r, 0.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 0.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 0.0, accuracy: accuracy)
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy)
    }

    func testThreeDigitHex_components() {
        // #F80 -> R=0xFF, G=0x88, B=0x00
        let c = Color(hex: "#F80").rgbaComponents()
        XCTAssertEqual(c.r, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 0x88 / 255.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 0.0, accuracy: accuracy)
    }

    // --- 8-digit hex (ARGB) ---

    func testEightDigitHex_opaqueWhite() {
        // FF + FFFFFF = fully opaque white
        let c = Color(hex: "#FFFFFFFF").rgbaComponents()
        XCTAssertEqual(c.r, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy)
    }

    func testEightDigitHex_halfAlpha() {
        // 80 = 128 -> ~0.502 alpha, red = FF
        let c = Color(hex: "#80FF0000").rgbaComponents()
        XCTAssertEqual(c.a, 128.0 / 255.0, accuracy: accuracy)
        XCTAssertEqual(c.r, 1.0, accuracy: accuracy)
        XCTAssertEqual(c.g, 0.0, accuracy: accuracy)
        XCTAssertEqual(c.b, 0.0, accuracy: accuracy)
    }

    func testEightDigitHex_zeroAlpha() {
        let c = Color(hex: "#00FF0000").rgbaComponents()
        XCTAssertEqual(c.a, 0.0, accuracy: accuracy)
    }

    // --- Default / invalid hex ---

    func testDefaultCase_invalidHex_producesExpectedFallback() {
        // The current implementation uses (a,r,g,b) = (1,1,1,0) for the default case.
        // This is a BUG: alpha = 1/255 ~ 0.004 which is effectively invisible,
        // and the "color" is (1/255, 1/255, 0/255) — essentially transparent dark.
        // A correct fallback should be fully opaque (alpha = 255) with a clear signal
        // color, e.g. magenta, or (0,0,0,0) for transparent.
        //
        // We test what the CORRECT behavior should be: the default/fallback should
        // produce a fully transparent color or a clearly visible error color.
        // This test documents the bug by asserting the intended behavior.
        let c = Color(hex: "XXXXX").rgbaComponents()   // 5 chars after trim -> default
        // Expected correct behavior: fully opaque clear-black or visible error color.
        // The fallback alpha should be 1.0 (fully opaque), not 1/255.
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy,
                       "BUG: default hex fallback should have full opacity, got \(c.a)")
    }

    func testEmptyString_hitsDefault() {
        let c = Color(hex: "").rgbaComponents()
        // Empty string after trimming has count 0 -> default case
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy,
                       "BUG: empty hex string should produce fully opaque fallback")
    }

    func testSingleChar_hitsDefault() {
        let c = Color(hex: "#A").rgbaComponents()
        // 1 char -> default
        XCTAssertEqual(c.a, 1.0, accuracy: accuracy,
                       "BUG: single-char hex should produce fully opaque fallback")
    }
}

// MARK: - PLATFORM_DARK_THEME_SYSTEM

final class ThemeDarkPaletteTests: XCTestCase {

    /// The theme is designed for a dark UI. Base/surface colors should be dark
    /// (low luminance) and text colors should be light (high luminance).

    func testBaseIsDark() {
        let c = Theme.base.rgbaComponents()
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        XCTAssertLessThan(luminance, 0.15, "base should be a dark color")
    }

    func testSurface1IsDark() {
        let c = Theme.surface1.rgbaComponents()
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        XCTAssertLessThan(luminance, 0.15)
    }

    func testSurface2IsDark() {
        let c = Theme.surface2.rgbaComponents()
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        XCTAssertLessThan(luminance, 0.15)
    }

    func testSidebarBgIsDarkest() {
        // Sidebar should be at least as dark as base
        let sidebar = Theme.sidebarBg.rgbaComponents()
        let base = Theme.base.rgbaComponents()
        let lumSidebar = 0.2126 * sidebar.r + 0.7152 * sidebar.g + 0.0722 * sidebar.b
        let lumBase = 0.2126 * base.r + 0.7152 * base.g + 0.0722 * base.b
        XCTAssertLessThanOrEqual(lumSidebar, lumBase + 0.01,
                                 "sidebarBg should be at least as dark as base")
    }

    func testTextPrimaryIsLight() {
        // textPrimary is white at 0.88 opacity — resolved against black it's ~0.88 luminance
        let c = Theme.textPrimary.rgbaComponents()
        // Because it's white * 0.88, the RGB channels should all be near 1.0,
        // with alpha ~0.88
        XCTAssertGreaterThan(c.a, 0.8, "textPrimary should have high opacity")
    }

    func testTextSecondaryIsDimmerThanPrimary() {
        let primary = Theme.textPrimary.rgbaComponents()
        let secondary = Theme.textSecondary.rgbaComponents()
        // Both are white.opacity(x), so alpha encodes the brightness
        XCTAssertGreaterThan(primary.a, secondary.a,
                             "textPrimary should have higher opacity than textSecondary")
    }

    func testTextTertiaryIsDimmestText() {
        let secondary = Theme.textSecondary.rgbaComponents()
        let tertiary = Theme.textTertiary.rgbaComponents()
        XCTAssertGreaterThan(secondary.a, tertiary.a,
                             "textSecondary should have higher opacity than textTertiary")
    }

    func testAccentIsBluish() {
        // #4C8DFF should have blue as the dominant channel
        let c = Theme.accent.rgbaComponents()
        XCTAssertGreaterThan(c.b, c.r, "accent blue > red")
        XCTAssertGreaterThan(c.b, c.g, "accent blue > green")
    }

    func testSuccessIsGreenish() {
        let c = Theme.success.rgbaComponents()
        XCTAssertGreaterThan(c.g, c.r, "success green > red")
        XCTAssertGreaterThan(c.g, c.b, "success green > blue")
    }

    func testWarningIsWarm() {
        // #FBBF24 — red and green dominant, blue low
        let c = Theme.warning.rgbaComponents()
        XCTAssertGreaterThan(c.r, c.b, "warning red > blue")
        XCTAssertGreaterThan(c.g, c.b, "warning green > blue")
    }

    func testDangerIsReddish() {
        let c = Theme.danger.rgbaComponents()
        XCTAssertGreaterThan(c.r, c.g, "danger red > green")
        XCTAssertGreaterThan(c.r, c.b, "danger red > blue")
    }

    func testSurfaceHierarchyGetsBrighter() {
        // base < surface1 < surface2 in luminance (progressively lighter surfaces)
        let lumBase = { let c = Theme.base.rgbaComponents(); return 0.2126*c.r + 0.7152*c.g + 0.0722*c.b }()
        let lumS1   = { let c = Theme.surface1.rgbaComponents(); return 0.2126*c.r + 0.7152*c.g + 0.0722*c.b }()
        let lumS2   = { let c = Theme.surface2.rgbaComponents(); return 0.2126*c.r + 0.7152*c.g + 0.0722*c.b }()
        XCTAssertLessThan(lumBase, lumS1, "base should be darker than surface1")
        XCTAssertLessThan(lumS1, lumS2, "surface1 should be darker than surface2")
    }
}

// MARK: - PLATFORM_SYNTAX_HIGHLIGHTING_COLORS

final class ThemeSyntaxHighlightingTests: XCTestCase {

    func testSynKeywordIsReddishPink() {
        // #FF5370
        let c = Theme.synKeyword.rgbaComponents()
        XCTAssertEqual(c.r, 0xFF / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.g, 0x53 / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.b, 0x70 / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.a, 1.0, accuracy: 1/255.0)
    }

    func testSynStringIsGreenish() {
        // #C3E88D
        let c = Theme.synString.rgbaComponents()
        XCTAssertEqual(c.r, 0xC3 / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.g, 0xE8 / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.b, 0x8D / 255.0, accuracy: 1/255.0)
        XCTAssertGreaterThan(c.g, c.r, "synString green > red")
        XCTAssertGreaterThan(c.g, c.b, "synString green > blue")
    }

    func testSynFunctionIsBluish() {
        // #82AAFF
        let c = Theme.synFunction.rgbaComponents()
        XCTAssertEqual(c.r, 0x82 / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.g, 0xAA / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.b, 0xFF / 255.0, accuracy: 1/255.0)
        XCTAssertGreaterThan(c.b, c.r, "synFunction blue > red")
    }

    func testSynCommentIsMuted() {
        // #676E95 — low saturation, grayish-blue
        let c = Theme.synComment.rgbaComponents()
        XCTAssertEqual(c.r, 0x67 / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.g, 0x6E / 255.0, accuracy: 1/255.0)
        XCTAssertEqual(c.b, 0x95 / 255.0, accuracy: 1/255.0)
    }

    func testSyntaxColorsAreAllDistinct() {
        // All four syntax colors should be visually distinct from each other
        let colors: [(String, Color)] = [
            ("synKeyword", Theme.synKeyword),
            ("synString", Theme.synString),
            ("synFunction", Theme.synFunction),
            ("synComment", Theme.synComment),
        ]
        for i in 0..<colors.count {
            for j in (i+1)..<colors.count {
                let a = colors[i].1.rgbaComponents()
                let b = colors[j].1.rgbaComponents()
                let dist = sqrt(pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2))
                XCTAssertGreaterThan(dist, 0.1,
                    "\(colors[i].0) and \(colors[j].0) should be visually distinct (dist=\(dist))")
            }
        }
    }

    func testSyntaxColorsAreFullyOpaque() {
        let acc: CGFloat = 1/255.0
        XCTAssertEqual(Theme.synKeyword.rgbaComponents().a, 1.0, accuracy: acc)
        XCTAssertEqual(Theme.synString.rgbaComponents().a, 1.0, accuracy: acc)
        XCTAssertEqual(Theme.synFunction.rgbaComponents().a, 1.0, accuracy: acc)
        XCTAssertEqual(Theme.synComment.rgbaComponents().a, 1.0, accuracy: acc)
    }

    func testSyntaxColorsContrastAgainstBase() {
        // Each syntax color should have sufficient contrast against the dark base
        let base = Theme.base.rgbaComponents()
        let baseLum = 0.2126 * base.r + 0.7152 * base.g + 0.0722 * base.b

        let syntaxColors: [(String, Color)] = [
            ("synKeyword", Theme.synKeyword),
            ("synString", Theme.synString),
            ("synFunction", Theme.synFunction),
            ("synComment", Theme.synComment),
        ]

        for (name, color) in syntaxColors {
            let c = color.rgbaComponents()
            let lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            // WCAG contrast ratio = (L1 + 0.05) / (L2 + 0.05) where L1 > L2
            let lighter = max(lum, baseLum)
            let darker = min(lum, baseLum)
            let ratio = (lighter + 0.05) / (darker + 0.05)
            // WCAG AA for normal text requires >= 4.5
            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                "\(name) contrast ratio \(ratio) against base is below WCAG AA (4.5)")
        }
    }
}

// MARK: - UI_BUILD_THEME_TOKEN_WIRING

final class ThemeTokenWiringTests: XCTestCase {
    func testSidebarHoverIsWiredThroughSelectableRows() throws {
        let theme = try projectSource("Theme.swift")
        XCTAssertTrue(theme.contains("if isHovered { return sidebarHover }"))

        let wiredSources = [
            try projectSource("SidebarView.swift"),
            try projectSource("WorkflowsView.swift"),
            try projectSource("LandingsView.swift"),
            try projectSource("IssuesView.swift"),
            try projectSource("TicketsView.swift"),
        ].joined(separator: "\n")

        XCTAssertTrue(wiredSources.contains(".themedSidebarRowBackground"))
    }

    func testPillBorderIsWiredThroughPillModifier() throws {
        let theme = try projectSource("Theme.swift")
        XCTAssertTrue(theme.contains("border: Color = Theme.pillBorder"))

        let wiredSources = [
            try projectSource("AgentsView.swift"),
            try projectSource("ChatView.swift"),
            try projectSource("MemoryView.swift"),
            try projectSource("WorkflowsView.swift"),
            try projectSource("PromptsView.swift"),
        ].joined(separator: "\n")

        XCTAssertTrue(wiredSources.contains(".themedPill"))
    }

    func testBubbleDiffIsWiredThroughDiffBlocks() throws {
        let theme = try projectSource("Theme.swift")
        XCTAssertTrue(theme.contains(".background(Theme.bubbleDiff)"))

        let wiredSources = [
            try projectSource("ChatView.swift"),
            try projectSource("ChangesView.swift"),
            try projectSource("LandingsView.swift"),
        ].joined(separator: "\n")

        XCTAssertTrue(wiredSources.contains(".themedDiffBlock"))
    }

    func testSyntaxTokensAreWiredThroughHighlightedText() throws {
        let theme = try projectSource("Theme.swift")
        for token in ["Theme.synKeyword", "Theme.synString", "Theme.synFunction", "Theme.synComment"] {
            XCTAssertTrue(theme.contains(token), "\(token) should be used by SyntaxHighlightedText")
        }

        let wiredSources = [
            try projectSource("ChatView.swift"),
            try projectSource("ChangesView.swift"),
            try projectSource("LandingsView.swift"),
        ].joined(separator: "\n")

        XCTAssertTrue(wiredSources.contains("SyntaxHighlightedText"))
    }
}
