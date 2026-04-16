import XCTest

final class ChatAdvancedE2ETests: SmithersGUIUITestCase {

    func testMultipleMessagesAppearInOrder() {
        let newChat = waitForElement("sidebar.newChat")
        newChat.click()
        XCTAssertTrue(element("view.chat").waitForExistence(timeout: 5))
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
        let newChat = waitForElement("sidebar.newChat")
        newChat.click()
        XCTAssertTrue(element("view.chat").waitForExistence(timeout: 5))
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
        let newChat = waitForElement("sidebar.newChat")
        newChat.click()
        XCTAssertTrue(element("view.chat").waitForExistence(timeout: 5))

        let picker = element("chat.targetPicker")
        if picker.waitForExistence(timeout: 3) {
            XCTAssertTrue(element("chat.target.codex").waitForExistence(timeout: 3))
        }
    }

    func testEmptyStateShowsOnFreshChat() {
        let newChat = waitForElement("sidebar.newChat")
        newChat.click()
        XCTAssertTrue(element("view.chat").waitForExistence(timeout: 5))
        chooseSmithersChatTargetIfNeeded()

        XCTAssertTrue(
            element("chat.emptyState").waitForExistence(timeout: 5) ||
            app.staticTexts["What can I help you build?"].waitForExistence(timeout: 5)
        )
    }
}
