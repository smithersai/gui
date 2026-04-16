import XCTest

final class ModelSelectionE2ETests: SmithersGUIUITestCase {

    func testSlashModelOpensModelPicker() {
        let newChat = waitForElement("sidebar.newChat")
        newChat.click()
        XCTAssertTrue(element("view.chat").waitForExistence(timeout: 5))
        chooseSmithersChatTargetIfNeeded()

        // Type /model to trigger model selection
        typeInto("chat.input", "/model")
        XCTAssertTrue(element("chat.slashPalette").waitForExistence(timeout: 3))

        // The model command should appear in results
        XCTAssertTrue(app.staticTexts["/model"].waitForExistence(timeout: 2) ||
                       app.staticTexts["Switch Model"].waitForExistence(timeout: 2))
    }
}
