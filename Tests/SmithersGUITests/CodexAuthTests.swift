import XCTest
@testable import SmithersGUI

final class CodexAuthStateTests: XCTestCase {
    func testModeLabelCoversAllCredentialStates() {
        XCTAssertEqual(makeState(hasAuthFile: false, hasAPIKey: false).modeLabel, "Not configured")
        XCTAssertEqual(makeState(hasAuthFile: true, hasAPIKey: false).modeLabel, "ChatGPT")
        XCTAssertEqual(makeState(hasAuthFile: false, hasAPIKey: true).modeLabel, "API key")
        XCTAssertEqual(makeState(hasAuthFile: true, hasAPIKey: true).modeLabel, "ChatGPT + API key")
    }

    func testIsReadyWhenAnyCredentialSourceExists() {
        XCTAssertFalse(makeState(hasAuthFile: false, hasAPIKey: false).isReady)
        XCTAssertTrue(makeState(hasAuthFile: true, hasAPIKey: false).isReady)
        XCTAssertTrue(makeState(hasAuthFile: false, hasAPIKey: true).isReady)
    }

    private func makeState(hasAuthFile: Bool, hasAPIKey: Bool) -> CodexAuthState {
        CodexAuthState(
            hasCodexCLI: true,
            codexCLIPath: "/usr/bin/codex",
            hasAuthFile: hasAuthFile,
            hasAPIKey: hasAPIKey,
            authFilePath: "/tmp/auth.json"
        )
    }
}

@MainActor
final class SmithersClientCodexAuthTests: XCTestCase {
    func testLoginWithEmptyAPIKeyThrowsValidationError() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("SmithersClientCodexAuthTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let client = SmithersClient(
            cwd: tempRoot.path,
            smithersBin: "/usr/bin/false",
            jjhubBin: "/usr/bin/false",
            codexHome: tempRoot.path
        )

        XCTAssertThrowsError(try client.loginCodexWithAPIKey("   ")) { error in
            XCTAssertEqual(error.localizedDescription, "API key is required.")
        }
    }

    func testLoginAndLogoutCodexAuthFileLifecycle() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("SmithersClientCodexAuthTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let client = SmithersClient(
            cwd: tempRoot.path,
            smithersBin: "/usr/bin/false",
            jjhubBin: "/usr/bin/false",
            codexHome: tempRoot.path
        )

        let initialState = client.codexAuthState()
        XCTAssertEqual(initialState.authFilePath, tempRoot.appendingPathComponent("auth.json").path)
        XCTAssertFalse(initialState.hasAuthFile)

        try client.loginCodexWithAPIKey(" sk-test-key ")

        let loggedInState = client.codexAuthState()
        XCTAssertTrue(loggedInState.hasAuthFile)

        let authData = try Data(contentsOf: URL(fileURLWithPath: loggedInState.authFilePath))
        let authJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: authData) as? [String: Any])
        XCTAssertEqual(authJSON["OPENAI_API_KEY"] as? String, "sk-test-key")
        XCTAssertNotNil(authJSON["tokens"])
        XCTAssertNotNil(authJSON["last_refresh"])

        XCTAssertTrue(try client.logoutCodex())
        XCTAssertFalse(client.codexAuthState().hasAuthFile)

        XCTAssertFalse(try client.logoutCodex())
    }
}
