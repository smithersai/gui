import Foundation
import XCTest
@testable import SmithersGUI

final class TerminalShellPreferenceTests: XCTestCase {
    func testResolvedShellUsesConfiguredExecutableBeforeEnvironmentShell() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = try makeExecutable(named: "custom-shell", in: root)
        let envShell = try makeExecutable(named: "env-shell", in: root)

        let resolved = TerminalShellPreference.resolvedShellPath(
            configuredPath: configured.path,
            environment: ["SHELL": envShell.path],
            detectedLoginShellPath: nil
        )

        XCTAssertEqual(resolved, configured.path)
    }

    func testResolvedShellFallsBackToEnvironmentWhenConfiguredPathIsInvalid() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let envShell = try makeExecutable(named: "env-shell", in: root)

        let resolved = TerminalShellPreference.resolvedShellPath(
            configuredPath: root.appendingPathComponent("missing-shell").path,
            environment: ["SHELL": envShell.path],
            detectedLoginShellPath: nil
        )

        XCTAssertEqual(resolved, envShell.path)
    }

    func testAvailableShellsDeduplicateConfiguredAndEnvironmentPaths() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = try makeExecutable(named: "dedup-shell", in: root)
        let defaultsContext = try makeDefaults()
        defer { defaultsContext.defaults.removePersistentDomain(forName: defaultsContext.suiteName) }
        defaultsContext.defaults.set(shell.path, forKey: AppPreferenceKeys.defaultShellPath)

        let paths = TerminalShellPreference.availableShellPaths(
            userDefaults: defaultsContext.defaults,
            environment: ["SHELL": shell.path],
            detectedLoginShellPath: nil
        )

        XCTAssertEqual(paths.filter { $0 == shell.path }.count, 1)
    }

    func testUsableShellRejectsRelativePath() {
        XCTAssertFalse(TerminalShellPreference.isUsableShellPath("zsh"))
    }

    func testResolvedShellUsesDetectedLoginShellBeforeEnvironmentShell() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loginShell = try makeExecutable(named: "login-shell", in: root)
        let envShell = try makeExecutable(named: "env-shell", in: root)

        let resolved = TerminalShellPreference.resolvedShellPath(
            configuredPath: nil,
            environment: ["SHELL": envShell.path],
            detectedLoginShellPath: loginShell.path
        )

        XCTAssertEqual(resolved, loginShell.path)
    }

    func testSmithersTerminalUserConfiguredShellUsesPasswdShellBeforeEnvironment() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loginShell = try makeExecutable(named: "login-shell", in: root)
        let envShell = try makeExecutable(named: "env-shell", in: root)

        let resolved = Smithers.Terminal.userConfiguredShell(
            passwdShell: loginShell.path,
            environment: ["SHELL": envShell.path],
            fallback: "/bin/zsh"
        )

        XCTAssertEqual(resolved, loginShell.path)
    }

    func testSmithersTerminalParsesEnvOutput() {
        let parsed = Smithers.Terminal.parseEnvironmentOutput("""
        PATH=/opt/homebrew/bin:/usr/bin
        EMPTY=
        VALUE=left=right
        ignored
        """)

        XCTAssertEqual(parsed["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(parsed["EMPTY"], "")
        XCTAssertEqual(parsed["VALUE"], "left=right")
        XCTAssertNil(parsed["ignored"])
    }

    func testSmithersTerminalToolEnvironmentPrependsBundledBinAndAppendsFallbacks() {
        let env = Smithers.Terminal.enrichToolEnvironment(
            baseEnvironment: [
                "PATH": "/Users/me/.local/bin:/usr/bin",
                "HOME": "/Users/me",
            ],
            shell: "/opt/homebrew/bin/fish",
            bundledPathEntries: ["/Applications/Smithers.app/Contents/Resources/bin"],
            fallbackPathEntries: ["/opt/homebrew/bin", "/usr/bin", "/bin"]
        )

        XCTAssertEqual(env["SHELL"], "/opt/homebrew/bin/fish")
        XCTAssertEqual(
            env["PATH"],
            "/Applications/Smithers.app/Contents/Resources/bin:/Users/me/.local/bin:/usr/bin:/opt/homebrew/bin:/bin"
        )
        XCTAssertEqual(env["HOME"], "/Users/me")
    }

    private func makeDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "TerminalShellPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalShellPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
