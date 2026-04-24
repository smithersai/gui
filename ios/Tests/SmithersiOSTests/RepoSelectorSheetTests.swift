#if os(iOS)
import Foundation
import XCTest
@testable import SmithersiOS

@MainActor
final class RepoSelectorSheetTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testUserReposRouteDecodesEnvelope() async throws {
        let session = makeStubbedSession()
        let requestedPaths = LockedBox<[String]>([])

        URLProtocolStub.handler = { request in
            requestedPaths.withValue { $0.append(request.url?.path ?? "") }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return try jsonResponse(
                for: request,
                statusCode: 200,
                jsonObject: [
                    "repos": [
                        ["owner": "zed", "name": "api"],
                        ["owner": "acme", "name": "widgets"],
                    ],
                ]
            )
        }

        let client = URLSessionUserReposClient(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { "test-token" },
            session: session
        )

        let repos = try await client.fetchRepos()

        XCTAssertEqual(repos.map(\.label), ["acme/widgets", "zed/api"])
        XCTAssertEqual(requestedPaths.withValue { $0 }, ["/api/user/repos"])
    }

    func testMissingUserReposRouteFallsBackToWorkspaceRepos() async throws {
        let session = makeStubbedSession()
        let requestedPaths = LockedBox<[String]>([])

        URLProtocolStub.handler = { request in
            requestedPaths.withValue { $0.append(request.url?.path ?? "") }
            switch request.url?.path {
            case "/api/user/repos":
                return try textResponse(for: request, statusCode: 404, body: "missing")
            case "/api/user/workspaces":
                XCTAssertEqual(
                    URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                    [URLQueryItem(name: "limit", value: "100")]
                )
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [
                        "workspaces": [
                            [
                                "workspace_id": "ws-1",
                                "repo_owner": "acme",
                                "repo_name": "widgets",
                                "name": "one",
                            ],
                            [
                                "workspace_id": "ws-2",
                                "repo_owner": "acme",
                                "repo_name": "widgets",
                                "name": "two",
                            ],
                            [
                                "workspace_id": "ws-3",
                                "repo_owner": "zed",
                                "repo_name": "api",
                                "name": "three",
                            ],
                        ],
                    ]
                )
            default:
                return try textResponse(for: request, statusCode: 500, body: "unexpected")
            }
        }

        let client = URLSessionUserReposClient(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { "test-token" },
            session: session
        )

        let repos = try await client.fetchRepos()

        XCTAssertEqual(repos.map(\.label), ["acme/widgets", "zed/api"])
        XCTAssertEqual(requestedPaths.withValue { $0 }, ["/api/user/repos", "/api/user/workspaces"])
    }

    func testViewModelFiltersSearchText() async throws {
        let model = RepoSelectorViewModel(
            client: StaticUserReposClient(repos: [
                SwitcherRepoRef(owner: "acme", name: "widgets"),
                SwitcherRepoRef(owner: "zed", name: "api"),
            ])
        )

        await model.reload()

        XCTAssertEqual(model.filteredRepos(matching: "wid").map(\.label), ["acme/widgets"])
        XCTAssertEqual(model.filteredRepos(matching: "zed").map(\.label), ["zed/api"])
        XCTAssertEqual(model.filteredRepos(matching: " ").map(\.label), ["acme/widgets", "zed/api"])
    }
}

private struct StaticUserReposClient: UserReposClient {
    let repos: [SwitcherRepoRef]

    func fetchRepos() async throws -> [SwitcherRepoRef] {
        repos
    }
}
#endif
