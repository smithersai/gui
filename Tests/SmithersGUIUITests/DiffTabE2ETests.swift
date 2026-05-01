import XCTest

final class DiffTabE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_OPEN_TREE_ON_LAUNCH": "1",
        ]
    }

    func testDiffTabRendersAndSupportsNavigation() {
        openLiveRunTreeHarness()

        selectTaskRowForInspectorTabs()
        waitForElement("inspector.tab.diff", timeout: 20).click()

        XCTAssertTrue(element("diffTab.fileList").waitForExistence(timeout: 5))

        let fileButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "diffTab.fileButton."))
        XCTAssertGreaterThan(fileButtons.count, 0)
        fileButtons.element(boundBy: 0).click()

        let toggles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "diffFile.toggle."))
        if toggles.count > 0 {
            toggles.element(boundBy: 0).click()
        } else {
            let sections = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "diffFile.section."))
            XCTAssertGreaterThan(sections.count, 0)
        }
    }

    private func openLiveRunTreeHarness() {
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 15))
        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 15))
    }

    private func selectTaskRowForInspectorTabs() {
        if element("inspector.tab.diff").waitForExistence(timeout: 6.0) {
            return
        }

        for rowID in [5, 6, 7, 3] {
            let row = element("tree.row.\(rowID)")
            guard row.waitForExistence(timeout: 1.0) else { continue }
            row.click()
            if element("inspector.tab.diff").waitForExistence(timeout: 2.0) {
                return
            }
        }
    }
}
