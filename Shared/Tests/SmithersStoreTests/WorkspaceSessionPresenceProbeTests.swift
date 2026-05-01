import Foundation
import XCTest
@testable import SmithersStore

final class WorkspaceSessionPresenceProbeTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testFetchReturnsPresentOn200() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(
                request.url?.path,
                "/api/repos/acme/widgets/workspace/sessions/sess_123"
            )

            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let probe = URLSessionRemoteWorkspaceSessionPresenceProbe(
            baseURL: URL(string: "http://localhost:4000")!,
            bearer: { "test-token" },
            session: makeSession()
        )

        let presence = try await probe.fetch(
            repoOwner: "acme",
            repoName: "widgets",
            sessionID: "sess_123"
        )

        XCTAssertEqual(presence, .present)
    }

    func testFetchReturnsMissingOn404() async throws {
        URLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let probe = URLSessionRemoteWorkspaceSessionPresenceProbe(
            baseURL: URL(string: "http://localhost:4000")!,
            bearer: { "test-token" },
            session: makeSession()
        )

        let presence = try await probe.fetch(
            repoOwner: "acme",
            repoName: "widgets",
            sessionID: "sess_404"
        )

        XCTAssertEqual(presence, .missing)
    }

    func testFetchThrowsAuthExpiredWithoutBearer() async {
        let probe = URLSessionRemoteWorkspaceSessionPresenceProbe(
            baseURL: URL(string: "http://localhost:4000")!,
            bearer: { nil },
            session: makeSession()
        )

        do {
            _ = try await probe.fetch(
                repoOwner: "acme",
                repoName: "widgets",
                sessionID: "sess_401"
            )
            XCTFail("expected authExpired when no bearer token is available")
        } catch let error as RemoteWorkspaceSessionPresenceError {
            XCTAssertEqual(error, .authExpired)
        } catch {
            XCTFail("expected RemoteWorkspaceSessionPresenceError.authExpired, got \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "WorkspaceSessionPresenceProbeTests",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "URLProtocolStub.handler not configured"]
                )
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
