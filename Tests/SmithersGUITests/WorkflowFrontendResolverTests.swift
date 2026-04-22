import XCTest
@testable import SmithersGUI

@MainActor
final class WorkflowFrontendResolverTests: XCTestCase {
    func test_loadDescriptor_readsAdjacentManifest() throws {
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

        let descriptor = try XCTUnwrap(
            WorkflowFrontendResolver.loadDescriptor(for: workflow, smithers: client)
        )

        XCTAssertEqual(descriptor.manifest.id, "ticket-kanban")
        XCTAssertEqual(descriptor.manifest.framework, "react")
        XCTAssertEqual(descriptor.frontendDirectoryPath, frontendDir.path)
        XCTAssertEqual(descriptor.serverScriptPath, serverURL.path)
    }

    func test_loadDescriptor_returnsNilWhenManifestIsMissing() throws {
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

        XCTAssertNil(try WorkflowFrontendResolver.loadDescriptor(for: workflow, smithers: client))
    }
}
