// MockHTTPTransport.swift — scripted HTTP transport for the mocked-server
// integration tests. Records requests (so assertions can inspect the
// exact wire shape) and replays pre-canned responses.
//
// Ticket 0109. Clearly labeled as test-only.

import Foundation
@testable import SmithersAuth

final class MockHTTPTransport: HTTPTransport {
    struct Recorded {
        let url: URL
        let method: String
        let body: Data?
        var bodyString: String? {
            body.flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    struct CannedResponse {
        let status: Int
        let body: Data
        let headers: [String: String]

        static func json(status: Int = 200, payload: [String: Any]) -> CannedResponse {
            let data = try! JSONSerialization.data(withJSONObject: payload, options: [])
            return CannedResponse(status: status, body: data, headers: ["Content-Type": "application/json"])
        }

        static func error(status: Int, code: String, description: String? = nil) -> CannedResponse {
            var payload: [String: Any] = ["error": code]
            if let description = description { payload["error_description"] = description }
            return .json(status: status, payload: payload)
        }
    }

    var responses: [CannedResponse] = []
    private(set) var recorded: [Recorded] = []

    func send(_ request: URLRequest) async throws -> (Data, Int, [String: String]) {
        recorded.append(Recorded(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            body: request.httpBody
        ))
        guard !responses.isEmpty else {
            return (Data(), 500, [:])
        }
        let r = responses.removeFirst()
        return (r.body, r.status, r.headers)
    }
}
