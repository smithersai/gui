#if os(iOS)
import XCTest

final class SmithersiOSSettingsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_settings_sections_render_from_signed_in_shell() throws {
        let baseURL = ProcessInfo.processInfo.environment["SMITHERS_SETTINGS_UI_BASE_URL"]
            ?? "http://127.0.0.1:4173"
        try XCTSkipUnless(
            Self.mockServerIsReachable(baseURL: baseURL),
            "Start a mock Plue server at \(baseURL) or set SMITHERS_SETTINGS_UI_BASE_URL to run this focused UI test."
        )
        let bearer = ProcessInfo.processInfo.environment["SMITHERS_SETTINGS_UI_BEARER"] ?? "settings-ui-bearer"

        let app = XCUIApplication()
        app.launchEnvironment["PLUE_E2E_MODE"] = "1"
        app.launchEnvironment["PLUE_BASE_URL"] = baseURL
        app.launchEnvironment["SMITHERS_E2E_BEARER"] = bearer
        app.launchEnvironment["PLUE_E2E_SEEDED"] = "0"
        app.launchEnvironment["PLUE_REMOTE_SANDBOX_ENABLED"] = "1"
        app.launchArguments += ["-smithers.onboarding.completed", "YES"]
        app.launch()

        XCTAssertTrue(element("app.root.ios", in: app).waitForExistence(timeout: 15))
        dismissOnboardingIfPresent(in: app)
        tapNavigationButton("content.ios.nav.settings", in: app)

        XCTAssertTrue(element("settings.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.account.email", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.account.github-username", in: app).exists)
        XCTAssertTrue(element("settings.sign-out", in: app).exists)
        XCTAssertTrue(element("settings.delete-account", in: app).exists)
        XCTAssertTrue(element("settings.backend-url", in: app).exists)
        XCTAssertTrue(element("settings.replay-tour", in: app).exists)
        XCTAssertTrue(element("settings.reset-cache", in: app).exists)

        app.swipeUp()
        XCTAssertTrue(element("settings.version", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("settings.privacy-policy", in: app).exists)
        XCTAssertTrue(element("settings.terms-of-service", in: app).exists)
        XCTAssertTrue(element("settings.open-source-licenses", in: app).exists)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func tapNavigationButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))

        for _ in 0..<6 where !button.isHittable {
            app.swipeUp()
        }

        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    private func dismissOnboardingIfPresent(in app: XCUIApplication) {
        let skip = app.buttons["onboarding.skip"].firstMatch
        if skip.waitForExistence(timeout: 1), skip.isHittable {
            skip.tap()
        }
    }

    private static func mockServerIsReachable(baseURL: String) -> Bool {
        guard let url = URL(string: baseURL)?.appendingPathComponent("api/health") else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var isReachable = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            isReachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 3)
        return isReachable
    }
}
#endif
