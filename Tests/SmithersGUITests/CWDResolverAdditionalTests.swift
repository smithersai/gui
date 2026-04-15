import XCTest
@testable import SmithersGUI

final class CWDResolverAdditionalTests: XCTestCase {

    func testResolveWithExplicitPath() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let result = CWDResolver.resolve(project.path, logWarning: { _, _ in })
        XCTAssertEqual(result, project.path)
    }

    func testResolveNilFallsToCurrentDir() throws {
        let current = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: current) }
        defer { try? FileManager.default.removeItem(at: home) }

        let result = CWDResolver.resolve(
            nil,
            currentDirectoryPath: { current.path },
            homeDirectoryPath: { home.path },
            logWarning: { _, _ in }
        )
        XCTAssertEqual(result, current.path)
    }

    func testResolveRootFallsToHome() throws {
        var didWarn = false
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = CWDResolver.resolve(
            "/",
            currentDirectoryPath: { "/" },
            homeDirectoryPath: { home.path },
            logWarning: { _, _ in didWarn = true }
        )
        XCTAssertEqual(result, home.path)
        XCTAssertTrue(didWarn)
    }

    func testResolveNilWithRootCurrentDir() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = CWDResolver.resolve(
            nil,
            currentDirectoryPath: { "/" },
            homeDirectoryPath: { home.path },
            logWarning: { _, _ in }
        )
        XCTAssertEqual(result, home.path)
    }

    func testResolveNonRootDoesNotWarn() throws {
        var didWarn = false
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        _ = CWDResolver.resolve(
            project.path,
            logWarning: { _, _ in didWarn = true }
        )
        XCTAssertFalse(didWarn)
    }
}
