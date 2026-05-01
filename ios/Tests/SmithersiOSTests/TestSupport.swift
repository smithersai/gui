#if os(iOS)
import Foundation
import XCTest

final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "SmithersiOSTests.URLProtocolStub",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "URLProtocolStub.handler not configured"]
                )
            )
            return
        }

        do {
            let (response, data) = try handler(Self.requestWithMaterializedBody(request))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func requestWithMaterializedBody(_ request: URLRequest) throws -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        var request = request
        request.httpBody = try Data(reading: stream)
        return request
    }
}

private extension Data {
    init(reading stream: InputStream) throws {
        self.init()
        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError ?? NSError(
                    domain: "SmithersiOSTests.URLProtocolStub",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read request body stream"]
                )
            }
            if count == 0 {
                break
            }
            append(buffer, count: count)
        }
    }
}

func makeStubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    return URLSession(configuration: configuration)
}

func jsonResponse(
    for request: URLRequest,
    statusCode: Int,
    jsonObject: Any
) throws -> (HTTPURLResponse, Data) {
    let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
    let response = try XCTUnwrap(
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://plue.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return (response, data)
}

func textResponse(
    for request: URLRequest,
    statusCode: Int,
    body: String
) throws -> (HTTPURLResponse, Data) {
    let response = try XCTUnwrap(
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://plue.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain"]
        )
    )
    return (response, Data(body.utf8))
}

@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    pollInterval: TimeInterval = 0.02,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let timeoutDate = Date().addingTimeInterval(timeout)
    while Date() < timeoutDate {
        if condition() {
            return true
        }
        let sleepNs = UInt64(max(pollInterval, 0.001) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: sleepNs)
    }
    return condition()
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
#endif
