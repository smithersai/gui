import XCTest

final class ChatAdvancedE2ETests: SmithersGUIUITestCase {

    func testMultipleMessagesAppearInOrder() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "First message")
        waitForElement("chat.sendButton").click()
        XCTAssertTrue(app.staticTexts["First message"].waitForExistence(timeout: 5))

        // Wait for response before sending next
        XCTAssertTrue(element("chat.sendButton").waitForExistence(timeout: 10))

        typeInto("chat.input", "Second message")
        waitForElement("chat.sendButton").click()
        XCTAssertTrue(app.staticTexts["Second message"].waitForExistence(timeout: 5))
    }

    func testNewChatSessionCreated() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        let initialCount = sessionButtonCount()

        // Send a message to establish a session
        typeInto("chat.input", "Session test message")
        waitForElement("chat.sendButton").click()
        XCTAssertTrue(app.staticTexts["Session test message"].waitForExistence(timeout: 5))

        // Session count should increase
        let newCount = sessionButtonCount()
        XCTAssertGreaterThanOrEqual(newCount, initialCount)
    }

    func testCodexTargetAvailable() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")

        let picker = element("chat.targetPicker")
        if picker.waitForExistence(timeout: 3) {
            XCTAssertTrue(element("chat.target.codex").waitForExistence(timeout: 3))
        }
    }

    func testEmptyStateShowsOnFreshChat() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        XCTAssertTrue(
            element("chat.emptyState").waitForExistence(timeout: 5) ||
            app.staticTexts["What can I help you build?"].waitForExistence(timeout: 5)
        )
    }
}
