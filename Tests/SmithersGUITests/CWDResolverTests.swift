import XCTest
@testable import SmithersGUI

final class CWDResolverTests: XCTestCase {
    func testUsesExplicitCwdWithoutWarning() throws {
        var warnings: [(String, String)] = []
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        defer { try? FileManager.default.removeItem(at: home) }

        let resolved = CWDResolver.resolve(
            project.path,
            currentDirectoryPath: { "/" },
            homeDirectoryPath: { home.path },
            logWarning: { warnings.append(($0, $1)) }
        )

        XCTAssertEqual(resolved, project.path)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testUsesCurrentDirectoryWhenNoCwdProvided() throws {
        var warnings: [(String, String)] = []
        let current = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: current) }
        defer { try? FileManager.default.removeItem(at: home) }

        let resolved = CWDResolver.resolve(
            nil,
            currentDirectoryPath: { current.path },
            homeDirectoryPath: { home.path },
            logWarning: { warnings.append(($0, $1)) }
        )

        XCTAssertEqual(resolved, current.path)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testFallsBackToHomeWhenResolvedCwdIsRoot() throws {
        var warnings: [(String, String)] = []
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let resolved = CWDResolver.resolve(
            nil,
            currentDirectoryPath: { "/" },
            homeDirectoryPath: { home.path },
            logWarning: { warnings.append(($0, $1)) }
        )

        XCTAssertEqual(resolved, home.path)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.0, "/")
        XCTAssertEqual(warnings.first?.1, home.path)
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
