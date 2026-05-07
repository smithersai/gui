import XCTest
@testable import SmithersGUI

@MainActor
final class WorkflowFrontendResolverTests: XCTestCase {
    func test_loadDescriptor_readsAdjacentManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workflowsDir = root.appendingPathComponent(".smithers/workflows", isDirectory: true)
        let workflowURL = workflowsDir.appendingPathComponent("ticket-kanban.tsx", isDirectory: false)
        let frontendDir = workflowsDir.appendingPathComponent("ticket-kanban.frontend", isDirectory: true)
        let manifestURL = frontendDir.appendingPathComponent("manifest.json", isDirectory: false)
        let serverURL = frontendDir.appendingPathComponent("server.ts", isDirectory: false)

        try FileManager.default.createDirectory(at: frontendDir, withIntermediateDirectories: true)
        try "export default null;\n".write(to: workflowURL, atomically: true, encoding: .utf8)
        try """
        {
          "version": 1,
          "id": "ticket-kanban",
          "name": "Ticket Kanban",
          "framework": "react",
          "entry": "dist/index.html",
          "apiBasePath": "/api",
          "defaultPath": "/"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)
        try "// server placeholder\n".write(to: serverURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let client = SmithersClient(cwd: root.path)
        let workflow = Workflow(
            id: "ticket-kanban",
            workspaceId: nil,
            name: "Ticket Kanban",
            relativePath: workflowURL.path,
            status: .active,
            updatedAt: nil
        )

        let loadedDescriptor = try await WorkflowFrontendResolver.loadDescriptor(for: workflow, smithers: client)
        let descriptor = try XCTUnwrap(loadedDescriptor)

        XCTAssertEqual(descriptor.manifest.id, "ticket-kanban")
        XCTAssertEqual(descriptor.manifest.framework, "react")
        XCTAssertEqual(descriptor.frontendDirectoryPath, frontendDir.path)
        XCTAssertEqual(descriptor.serverScriptPath, serverURL.path)
        XCTAssertEqual(descriptor.entryPath, frontendDir.appendingPathComponent("dist/index.html").path)
    }

    func test_loadDescriptor_returnsNilWhenManifestIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workflowsDir = root.appendingPathComponent(".smithers/workflows", isDirectory: true)
        let workflowURL = workflowsDir.appendingPathComponent("ticket-kanban.tsx", isDirectory: false)
        try FileManager.default.createDirectory(at: workflowsDir, withIntermediateDirectories: true)
        try "export default null;\n".write(to: workflowURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let client = SmithersClient(cwd: root.path)
        let workflow = Workflow(
            id: "ticket-kanban",
            workspaceId: nil,
            name: "Ticket Kanban",
            relativePath: workflowURL.path,
            status: .active,
            updatedAt: nil
        )

        let descriptor = try await WorkflowFrontendResolver.loadDescriptor(for: workflow, smithers: client)
        XCTAssertNil(descriptor)
    }

    func test_loadDescriptor_supportsStaticFrontendWithoutServerScript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workflowsDir = root.appendingPathComponent(".smithers/workflows", isDirectory: true)
        let workflowURL = workflowsDir.appendingPathComponent("ticket-kanban.tsx", isDirectory: false)
        let frontendDir = workflowsDir.appendingPathComponent("ticket-kanban.frontend", isDirectory: true)
        let distDir = frontendDir.appendingPathComponent("dist", isDirectory: true)
        let manifestURL = frontendDir.appendingPathComponent("manifest.json", isDirectory: false)
        let entryURL = distDir.appendingPathComponent("index.html", isDirectory: false)

        try FileManager.default.createDirectory(at: distDir, withIntermediateDirectories: true)
        try "export default null;\n".write(to: workflowURL, atomically: true, encoding: .utf8)
        try """
        {
          "version": 1,
          "id": "ticket-kanban",
          "name": "Ticket Kanban",
          "framework": "svelte",
          "entry": "dist/index.html",
          "defaultPath": "/"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)
        try "<main></main>\n".write(to: entryURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let client = SmithersClient(cwd: root.path)
        let workflow = Workflow(
            id: "ticket-kanban",
            workspaceId: nil,
            name: "Ticket Kanban",
            relativePath: workflowURL.path,
            status: .active,
            updatedAt: nil
        )

        let loadedDescriptor = try await WorkflowFrontendResolver.loadDescriptor(for: workflow, smithers: client)
        let descriptor = try XCTUnwrap(loadedDescriptor)

        XCTAssertEqual(descriptor.manifest.framework, "svelte")
        XCTAssertNil(descriptor.serverScriptPath)
        XCTAssertEqual(descriptor.entryPath, entryURL.path)
    }
}
