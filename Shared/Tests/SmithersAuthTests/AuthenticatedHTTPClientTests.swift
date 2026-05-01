import Foundation
import XCTest
@testable import SmithersAuth

final class AuthenticatedHTTPClientTests: XCTestCase {
    private func makeConfig() -> OAuth2ClientConfig {
        OAuth2ClientConfig(
            baseURL: URL(string: "https://plue.test")!,
            clientID: "FAKE-client-id",
            redirectURI: "smithers://auth/callback"
        )
    }

    private func makeClient(
        transport: HTTPTransport,
        initialTokens: OAuth2Tokens = OAuth2Tokens(accessToken: "ACCESS_1", refreshToken: "REFRESH_1")
    ) -> (AuthenticatedHTTPClient, TokenManager, InMemoryTokenStore) {
        let oauth = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore(initial: initialTokens)
        let manager = TokenManager(client: oauth, store: store)
        let client = AuthenticatedHTTPClient(tokenManager: manager, transport: transport)
        return (client, manager, store)
    }

    private func protectedRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://plue.test/api/protected")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func test_concurrent_401_requests_collapse_to_single_refresh() async throws {
        let transport = TokenRefreshingEndpointTransport()
        transport.staleDelayNanoseconds = 20_000_000
        let (client, _, _) = makeClient(transport: transport)

        async let first = client.send(protectedRequest())
        async let second = client.send(protectedRequest())
        let responses = try await [first, second]

        XCTAssertEqual(responses.map(\.statusCode), [200, 200])
        XCTAssertEqual(transport.refreshCalls, 1)

        let protectedHits = transport.recordedRequests.filter { $0.url.path == "/api/protected" }
        let staleHits = protectedHits.filter { $0.headers["Authorization"] == "Bearer ACCESS_1" }
        let refreshedHits = protectedHits.filter { $0.headers["Authorization"] == "Bearer ACCESS_2" }
        XCTAssertEqual(staleHits.count, 2)
        XCTAssertEqual(refreshedHits.count, 2)
    }

    func test_successful_refresh_retries_with_new_access_token() async throws {
        let transport = TokenRefreshingEndpointTransport()
        transport.refreshedBody = Data("retried-ok".utf8)
        let (client, _, store) = makeClient(transport: transport)

        let response = try await client.send(protectedRequest())

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "retried-ok")
        XCTAssertEqual(transport.refreshCalls, 1)
        XCTAssertEqual(try store.load()?.accessToken, "ACCESS_2")

        let protectedHits = transport.recordedRequests.filter { $0.url.path == "/api/protected" }
        XCTAssertEqual(protectedHits.count, 2)
        XCTAssertEqual(protectedHits[0].headers["Authorization"], "Bearer ACCESS_1")
        XCTAssertEqual(protectedHits[1].headers["Authorization"], "Bearer ACCESS_2")
    }

    func test_refresh_failure_returns_auth_expired_without_infinite_retry() async throws {
        let transport = TokenRefreshingEndpointTransport()
        transport.refreshBehavior = .failure(status: 401, code: "unauthorized")
        let (client, manager, store) = makeClient(transport: transport)

        do {
            _ = try await client.send(protectedRequest())
            XCTFail("expected authExpired")
        } catch let error as AuthenticatedHTTPClientError {
            XCTAssertEqual(error, .authExpired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(transport.refreshCalls, 1)
        let protectedHits = transport.recordedRequests.filter { $0.url.path == "/api/protected" }
        XCTAssertEqual(protectedHits.count, 1)
        XCTAssertFalse(manager.hasSession)
        XCTAssertNil(try store.load())
    }

    func test_non_auth_statuses_are_returned_without_forcing_signout() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            .init(
                status: 429,
                body: Data("slow down".utf8),
                headers: ["Retry-After": "30"]
            ),
            .init(
                status: 500,
                body: Data("server blew up".utf8),
                headers: ["X-Error": "boom"]
            ),
        ]

        let (client, manager, _) = makeClient(transport: transport)
        let request = protectedRequest()

        let first = try await client.send(request)
        let second = try await client.send(request)

        XCTAssertEqual(first.statusCode, 429)
        XCTAssertEqual(String(data: first.body, encoding: .utf8), "slow down")
        XCTAssertEqual(first.headers["Retry-After"], "30")

        XCTAssertEqual(second.statusCode, 500)
        XCTAssertEqual(String(data: second.body, encoding: .utf8), "server blew up")
        XCTAssertEqual(second.headers["X-Error"], "boom")

        XCTAssertTrue(manager.hasSession)
        let refreshHits = transport.recorded.filter {
            $0.url.absoluteString.hasSuffix("/api/oauth2/token")
                && ($0.bodyString ?? "").contains("grant_type=refresh_token")
        }
        XCTAssertEqual(refreshHits.count, 0)
    }
}

private final class TokenRefreshingEndpointTransport: HTTPTransport, @unchecked Sendable {
    enum RefreshBehavior {
        case success(accessToken: String, refreshToken: String)
        case failure(status: Int, code: String)
    }

    struct Recorded {
        let url: URL
        let method: String
        let headers: [String: String]
        let bodyString: String?
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var refreshCallCount = 0

    var staleDelayNanoseconds: UInt64 = 0
    var staleStatus = 401
    var staleBody = Data("expired".utf8)
    var refreshedStatus = 200
    var refreshedBody = Data("ok".utf8)
    var refreshBehavior: RefreshBehavior = .success(accessToken: "ACCESS_2", refreshToken: "REFRESH_2")

    var refreshCalls: Int {
        lock.withLock { refreshCallCount }
    }

    var recordedRequests: [Recorded] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, Int, [String: String]) {
        let url = try unwrapURL(for: request)
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }

        lock.withLock {
            recorded.append(Recorded(url: url, method: method, headers: headers, bodyString: bodyString))
        }

        let path = url.path
        if path == "/api/oauth2/token",
           (bodyString ?? "").contains("grant_type=refresh_token") {
            return lock.withLock {
                refreshCallCount += 1
                switch refreshBehavior {
                case .success(let accessToken, let refreshToken):
                    let body = Self.jsonData([
                        "access_token": accessToken,
                        "refresh_token": refreshToken,
                    ])
                    return (body, 200, ["Content-Type": "application/json"])
                case .failure(let status, let code):
                    let body = Self.jsonData(["error": code])
                    return (body, status, ["Content-Type": "application/json"])
                }
            }
        }

        if path == "/api/protected" {
            let auth = headers["Authorization"] ?? ""
            if auth == "Bearer ACCESS_1" {
                if staleDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: staleDelayNanoseconds)
                }
                return (staleBody, staleStatus, ["Content-Type": "text/plain"])
            }
            if auth == "Bearer ACCESS_2" {
                return (refreshedBody, refreshedStatus, ["Content-Type": "text/plain"])
            }
            return (Data("missing bearer".utf8), 401, ["Content-Type": "text/plain"])
        }

        return (Data("not found".utf8), 404, ["Content-Type": "text/plain"])
    }

    private static func jsonData(_ object: [String: String]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func unwrapURL(for request: URLRequest) throws -> URL {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        return url
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
