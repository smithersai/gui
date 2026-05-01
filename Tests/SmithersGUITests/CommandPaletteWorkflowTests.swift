import XCTest
@testable import SmithersGUI

@MainActor
final class CommandPaletteWorkflowTests: XCTestCase {
    func testWorkflowQuerySurfacesRunnableWorkflowItem() throws {
        let workflow = makeWorkflow()

        let items = CommandPaletteBuilder.items(
            for: "implement",
            context: makeContext(workflows: [workflow]),
            limit: 20,
            primaryItems: []
        )

        let item = try XCTUnwrap(items.first { $0.title == "Implement" })
        XCTAssertEqual(item.section, "Workflows")
        XCTAssertEqual(item.icon, "arrow.triangle.branch")

        guard case .runWorkflow(let selectedWorkflow) = item.action else {
            return XCTFail("Expected workflow palette item to run a workflow")
        }

        XCTAssertEqual(selectedWorkflow, workflow)
    }

    func testWorkflowQueryWithTrailingPromptResolvesQuickLaunchRequest() throws {
        let workflow = makeWorkflow()
        let rawQuery = "implement add health endpoint"

        let items = CommandPaletteBuilder.items(
            for: rawQuery,
            context: makeContext(workflows: [workflow]),
            limit: 20,
            primaryItems: []
        )

        let item = try XCTUnwrap(items.first { $0.title == "Implement" })
        let request = try XCTUnwrap(
            CommandPaletteQuickLaunchResolver.request(
                for: item.action,
                rawQuery: rawQuery,
                slashCommands: []
            )
        )

        XCTAssertEqual(request.workflow, workflow)
        XCTAssertEqual(request.prompt, "add health endpoint")
    }

    func testWorkflowResultsDeduplicateAgainstLibPaletteMatches() throws {
        let workflow = makeWorkflow()
        let libPaletteWorkflow = CommandPaletteItem(
            id: "workflow:implement",
            title: "Implement",
            subtitle: workflow.filePath ?? "Run workflow.",
            icon: "arrow.triangle.branch",
            section: "Workflows",
            keywords: ["Implement", workflow.filePath ?? ""],
            shortcut: nil,
            action: .unsupported("workflow:implement"),
            isEnabled: true
        )

        let items = CommandPaletteBuilder.items(
            for: "implement",
            context: makeContext(workflows: [workflow]),
            limit: 20,
            primaryItems: [libPaletteWorkflow]
        )

        let matches = items.filter { $0.title == "Implement" }
        XCTAssertEqual(matches.count, 1)

        let item = try XCTUnwrap(matches.first)
        guard case .runWorkflow(let selectedWorkflow) = item.action else {
            return XCTFail("Expected deduplicated workflow palette item to run a workflow")
        }

        XCTAssertEqual(selectedWorkflow, workflow)
    }

    private func makeWorkflow(
        id: String = "workflow:implement",
        name: String = "Implement",
        relativePath: String = ".smithers/workflows/implement.tsx"
    ) -> Workflow {
        Workflow(
            id: id,
            workspaceId: "workspace-1",
            name: name,
            relativePath: relativePath,
            status: .active,
            updatedAt: "2026-04-10T12:00:00Z"
        )
    }

    private func makeContext(workflows: [Workflow]) -> CommandPaletteContext {
        CommandPaletteContext(
            destination: .dashboard,
            sidebarTabs: [],
            runTabs: [],
            workflows: workflows,
            prompts: [],
            issues: [],
            tickets: [],
            landings: [],
            slashCommands: [],
            files: [],
            developerToolsEnabled: false
        )
    }
}
