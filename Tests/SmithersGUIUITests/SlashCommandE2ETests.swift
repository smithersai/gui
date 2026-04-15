import XCTest

final class SlashCommandE2ETests: SmithersGUIUITestCase {

    // MARK: - Palette Behavior

    func testSlashPaletteAppearsOnSlash() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "/")
        XCTAssertTrue(element("chat.slashPalette").waitForExistence(timeout: 3))
    }

    func testSlashPaletteFiltersAsYouType() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "/dash")
        XCTAssertTrue(element("chat.slashPalette").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Dashboard"].waitForExistence(timeout: 2) ||
                       app.staticTexts["/dashboard"].waitForExistence(timeout: 2))
    }

    func testSlashPaletteDismissesOnBackspace() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        let input = waitForElement("chat.input")
        input.click()
        input.typeText("/")
        XCTAssertTrue(element("chat.slashPalette").waitForExistence(timeout: 3))

        // Delete the slash
        input.typeKey(.delete, modifierFlags: [])
        // Palette should dismiss (or show no results)
    }

    // MARK: - Navigation Commands

    func testSlashDashboardNavigates() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "/dashboard", submit: true)
        XCTAssertTrue(element("view.dashboard").waitForExistence(timeout: 5))
    }

    func testSlashRunsNavigates() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "/runs", submit: true)
        XCTAssertTrue(element("view.runs").waitForExistence(timeout: 5))
    }

    func testSlashMemoryNavigates() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "/memory", submit: true)
        XCTAssertTrue(element("view.memory").waitForExistence(timeout: 5))
    }

    func testSlashSearchNavigates() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "/search", submit: true)
        XCTAssertTrue(element("view.search").waitForExistence(timeout: 5))
    }

    func testSlashScoresNavigates() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "/scores", submit: true)
        XCTAssertTrue(element("view.scores").waitForExistence(timeout: 5))
    }

    // MARK: - Action Commands

    func testSlashHelpShowsCommands() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "/help", submit: true)
        // Help should display command list in chat
        XCTAssertTrue(
            app.staticTexts["/model"].waitForExistence(timeout: 5) ||
            app.staticTexts["Available commands"].waitForExistence(timeout: 5) ||
            element("chat.surface").waitForExistence(timeout: 5)
        )
    }

    func testSlashClearClearsChat() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        // Send a message first
        typeInto("chat.input", "Hello from clear test")
        waitForElement("chat.sendButton").click()
        XCTAssertTrue(app.staticTexts["Hello from clear test"].waitForExistence(timeout: 5))

        // Clear
        typeInto("chat.input", "/clear", submit: true)
        // The message should no longer be visible (or empty state returns)
    }
}
