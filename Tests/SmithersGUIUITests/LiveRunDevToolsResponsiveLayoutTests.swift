import XCTest

final class LiveRunDevToolsResponsiveLayoutTests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        var env: [String: String] = [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_OPEN_TREE_ON_LAUNCH": "1",
        ]

        if name.contains("Narrow") {
            env["SMITHERS_GUI_UITEST_FORCE_LIVERUN_LAYOUT"] = "narrow"
        } else {
            env["SMITHERS_GUI_UITEST_FORCE_LIVERUN_LAYOUT"] = "wide"
        }

        return env
    }

    func testWideLayoutShowsSplitDivider() {
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))
        XCTAssertTrue(element("liveRun.layout.divider").waitForExistence(timeout: 8))
    }

    func testNarrowLayoutShowsInspectorBottomSheet() {
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))
        XCTAssertFalse(element("liveRun.layout.divider").waitForExistence(timeout: 1))

        waitForElement("tree.row.5", timeout: 8).click()

        let sheetExists = element("liveRun.layout.inspectorSheet").waitForExistence(timeout: 8)
        let inspectorExists = element("view.node.inspector").waitForExistence(timeout: 2)
        XCTAssertTrue(sheetExists || inspectorExists)
    }
}
