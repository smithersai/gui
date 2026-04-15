import XCTest
@testable import SmithersGUI

final class CWDResolverTests: XCTestCase {
    func testUsesExplicitCwdWithoutWarning() {
        var warnings: [(String, String)] = []

        let resolved = CWDResolver.resolve(
            "/tmp/project",
            currentDirectoryPath: { "/" },
            homeDirectoryPath: { "/Users/test" },
            logWarning: { warnings.append(($0, $1)) }
        )

        XCTAssertEqual(resolved, "/tmp/project")
        XCTAssertTrue(warnings.isEmpty)
    }

    func testUsesCurrentDirectoryWhenNoCwdProvided() {
        var warnings: [(String, String)] = []

        let resolved = CWDResolver.resolve(
            nil,
            currentDirectoryPath: { "/tmp/current" },
            homeDirectoryPath: { "/Users/test" },
            logWarning: { warnings.append(($0, $1)) }
        )

        XCTAssertEqual(resolved, "/tmp/current")
        XCTAssertTrue(warnings.isEmpty)
    }

    func testFallsBackToHomeWhenResolvedCwdIsRoot() {
        var warnings: [(String, String)] = []

        let resolved = CWDResolver.resolve(
            nil,
            currentDirectoryPath: { "/" },
            homeDirectoryPath: { "/Users/test" },
            logWarning: { warnings.append(($0, $1)) }
        )

        XCTAssertEqual(resolved, "/Users/test")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.0, "/")
        XCTAssertEqual(warnings.first?.1, "/Users/test")
    }

    @MainActor
    func testAgentServiceUsesSharedResolverForRootCwd() {
        let service = AgentService(workingDir: "/")
        XCTAssertEqual(service.workingDirectory, NSHomeDirectory())
    }

    @MainActor
    func testSmithersClientUsesSharedResolverForRootCwd() {
        let client = SmithersClient(cwd: "/")
        XCTAssertEqual(client.workingDirectory, NSHomeDirectory())
    }
}
