import XCTest

final class SearchIssuesE2ETests: SmithersGUIUITestCase {
    func testSearchTabsAndSubmission() {
        navigate(to: "Search", expectedViewIdentifier: "view.search")

        for tab in ["Code", "Issues", "Repos"] {
            XCTAssertTrue(app.buttons["search.tab.\(tab)"].exists, "Missing search tab \(tab)")
        }

        typeInto("search.input", "fixture", submit: true)
        XCTAssertTrue(element("search.result.code-1").waitForExistence(timeout: 5))

        app.buttons["search.tab.Issues"].click()
        XCTAssertTrue(element("search.result.issue-101").waitForExistence(timeout: 5))

        app.buttons["search.tab.Repos"].click()
        XCTAssertTrue(element("search.result.repo-1").waitForExistence(timeout: 5))
    }

    func testIssuesCreateFormAndStateFilters() {
        navigate(to: "Issues", expectedViewIdentifier: "view.issues")

        XCTAssertTrue(app.buttons["issues.filter.Open"].exists)
        XCTAssertTrue(app.buttons["issues.filter.Closed"].exists)
        XCTAssertTrue(app.buttons["issues.filter.All"].exists)

        app.buttons["issues.filter.Closed"].click()
        XCTAssertTrue(app.staticTexts["Closed fixture issue"].waitForExistence(timeout: 5))

        app.buttons["issues.filter.All"].click()
        XCTAssertTrue(app.staticTexts["Open fixture issue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Closed fixture issue"].exists)

        app.buttons["issues.filter.Open"].click()
        waitForElement("issues.createButton").click()
        XCTAssertTrue(element("issues.create.form").waitForExistence(timeout: 5))

        typeInto("issues.create.title", "Created from UI test")
        typeInto("issues.create.body", "Body from UI test")
        waitForElement("issues.create.submit").click()

        XCTAssertTrue(app.staticTexts["Created from UI test"].waitForExistence(timeout: 5))
    }
}
