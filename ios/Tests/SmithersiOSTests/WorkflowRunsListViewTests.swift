#if os(iOS)
import Foundation
import SwiftUI
import XCTest
import ViewInspector
@testable import SmithersiOS

extension WorkflowRunsListView: Inspectable {}
extension WorkflowRunDetailView: Inspectable {}

@MainActor
final class WorkflowRunsListViewTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testReloadLoadsAndSortsRuns() async throws {
        let session = makeStubbedSession()
        let requestCount = LockedBox(0)

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/repos/acme/widgets/workflows/runs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                [URLQueryItem(name: "per_page", value: "100")]
            )
            requestCount.withValue { $0 += 1 }
            return try jsonResponse(
                for: request,
                statusCode: 200,
                jsonObject: [
                    "runs": [
                        Self.runPayload(id: 10, status: "succeeded", name: "Older run", createdAtMs: 1_700_000_000_000),
                        Self.runPayload(id: 11, status: "running", name: "Newer run", createdAtMs: 1_700_000_001_000),
                    ],
                ]
            )
        }

        let model = makeListModel(session: session)

        await model.reload()

        XCTAssertEqual(requestCount.withValue { $0 }, 1)
        XCTAssertEqual(model.runs.map(\.id), [11, 10])
        XCTAssertEqual(model.runs.first?.displayWorkflowName, "Newer run")
        XCTAssertNil(model.loadError)
    }

    func testEmptyStateRendersAfterEmptyLoad() async throws {
        let session = makeStubbedSession()

        URLProtocolStub.handler = { request in
            try jsonResponse(for: request, statusCode: 200, jsonObject: ["runs": []])
        }

        let model = makeListModel(session: session)
        await model.reload()

        let view = makeListView(session: session, viewModel: model)

        XCTAssertTrue(model.runs.isEmpty)
        XCTAssertNoThrow(try view.inspect().find(text: "No workflow runs"))
        XCTAssertNoThrow(try view.inspect().find(text: "acme/widgets"))
    }

    func testRowUsesRunValueNavigation() async throws {
        let session = makeStubbedSession()

        URLProtocolStub.handler = { request in
            try jsonResponse(
                for: request,
                statusCode: 200,
                jsonObject: [
                    "runs": [
                        Self.runPayload(id: 42, status: "running", name: "Build iOS", createdAtMs: 1_700_000_001_000),
                    ],
                ]
            )
        }

        let model = makeListModel(session: session)
        await model.reload()

        let view = makeListView(session: session, viewModel: model)
        let link = try view.inspect().find(ViewType.NavigationLink.self)
        let value = try link.value(WorkflowRunListItem.self)

        XCTAssertEqual(value.id, 42)
        XCTAssertEqual(value.displayWorkflowName, "Build iOS")
        XCTAssertNoThrow(try view.inspect().find(text: "Build iOS"))
    }

    func testCancelButtonFlowPostsCancelAndRefreshesStatus() async throws {
        let session = makeStubbedSession()
        let requestedPaths = LockedBox<[String]>([])

        URLProtocolStub.handler = { request in
            requestedPaths.withValue {
                $0.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            }

            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/repos/acme/widgets/workflows/runs"):
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [
                        "runs": [
                            Self.runPayload(id: 7, status: "running", name: "Deploy", createdAtMs: 1_700_000_001_000),
                        ],
                    ]
                )
            case ("POST", "/api/repos/acme/widgets/runs/7/cancel"):
                return try textResponse(for: request, statusCode: 204, body: "")
            case ("GET", "/api/repos/acme/widgets/runs/7"):
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: Self.runPayload(id: 7, status: "cancelled", name: "Deploy", createdAtMs: 1_700_000_001_000)
                )
            default:
                return try textResponse(for: request, statusCode: 404, body: "unexpected request")
            }
        }

        let listModel = makeListModel(session: session)
        await listModel.reload()
        let initialRun = try XCTUnwrap(listModel.runs.first)
        let detailView = makeDetailView(session: session, initialRun: initialRun)
        let detailModel = WorkflowRunDetailViewModel(
            client: makeClient(session: session),
            repo: Self.repo,
            runID: initialRun.id,
            initialDetail: WorkflowRunDetail(from: initialRun)
        )

        XCTAssertNoThrow(try detailView.inspect().find(button: "Cancel run"))
        let cancelled = await detailModel.cancel()
        XCTAssertTrue(cancelled)

        XCTAssertEqual(detailModel.detail.statusLabel, "Cancelled")
        XCTAssertEqual(
            requestedPaths.withValue { $0 },
            [
                "GET /api/repos/acme/widgets/workflows/runs",
                "POST /api/repos/acme/widgets/runs/7/cancel",
                "GET /api/repos/acme/widgets/runs/7",
            ]
        )
    }

    func testErrorBannerRetryReloadsList() async throws {
        let session = makeStubbedSession()
        let listRequestCount = LockedBox(0)

        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/repos/acme/widgets/workflows/runs":
                let call = listRequestCount.withValue {
                    $0 += 1
                    return $0
                }
                if call == 1 {
                    return try textResponse(for: request, statusCode: 500, body: "backend offline")
                }
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [
                        "runs": [
                            Self.runPayload(id: 12, status: "succeeded", name: "Retry recovered", createdAtMs: 1_700_000_002_000),
                        ],
                    ]
                )
            default:
                return try textResponse(for: request, statusCode: 404, body: "unexpected request")
            }
        }

        let model = makeListModel(session: session)
        await model.reload()
        let view = makeListView(session: session, viewModel: model)

        XCTAssertEqual(model.loadError, "backend offline")
        XCTAssertNoThrow(try view.inspect().find(text: "backend offline"))

        try view.inspect().find(button: "Retry").tap()

        let recovered = await waitUntil {
            model.runs.map(\.id) == [12]
        }

        XCTAssertTrue(recovered)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(listRequestCount.withValue { $0 }, 2)
    }

    private func makeListModel(session: URLSession) -> WorkflowRunsListViewModel {
        WorkflowRunsListViewModel(
            client: makeClient(session: session),
            repo: Self.repo
        )
    }

    private func makeListView(
        session: URLSession,
        viewModel: WorkflowRunsListViewModel
    ) -> WorkflowRunsListView {
        WorkflowRunsListView(
            client: makeClient(session: session),
            repo: Self.repo,
            viewModel: viewModel
        )
    }

    private func makeDetailView(
        session: URLSession,
        initialRun: WorkflowRunListItem
    ) -> WorkflowRunDetailView {
        WorkflowRunDetailView(
            client: makeClient(session: session),
            repo: Self.repo,
            runID: initialRun.id,
            initialRun: initialRun,
            onCancelled: {}
        )
    }

    private func makeClient(session: URLSession) -> URLSessionWorkflowRunsClient {
        URLSessionWorkflowRunsClient(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { "test-token" },
            session: session
        )
    }

    private static let repo = WorkflowRunsRepoRef(owner: "acme", name: "widgets")

    private static func runPayload(
        id: Int64,
        status: String,
        name: String,
        createdAtMs: Int64
    ) -> [String: Any] {
        [
            "id": id,
            "workflow_id": "workflow-\(id)",
            "status": status,
            "workflow_name": name,
            "created_at": createdAtMs,
        ]
    }
}
#endif
