// LoopbackCallbackServer.swift — minimal one-shot HTTP listener used for
// the macOS desktop-remote OAuth2 callback path.
//
// Ticket 0109. In practice on macOS we can pick between:
//   (a) a custom URL scheme like `smithers://auth/callback` (identical to
//       iOS), OR
//   (b) the RFC 8252 recommended loopback address
//       `http://127.0.0.1:<port>/callback`.
// We support both. `ASWebAuthenticationSession` delivers a callback for
// the custom-scheme path without any help from us. The loopback path
// uses this helper when a redirect URI with `http://127.0.0.1` is
// registered with plue (0106).
//
// The server listens only long enough to capture ONE request, then stops.
// It binds to 127.0.0.1 (IPv4 loopback) — the external network is never
// reachable — and only accepts a single path (`/callback`). Any other
// request is refused with 404.

#if os(macOS)
import Foundation
import Network

public enum LoopbackCallbackError: Error, Equatable {
    case bindFailed(String)
    case receiveFailed(String)
    case invalidRequest
    case pathMismatch
}

public final class LoopbackCallbackServer {
    public let expectedPath: String

    private let queue = DispatchQueue(label: "smithers.loopback.oauth2")
    private var listener: NWListener?

    public init(expectedPath: String = "/callback") {
        self.expectedPath = expectedPath
    }

    /// Binds to a random loopback port, returns it, and installs a
    /// one-shot handler. Call `waitForCallback()` to await it.
    public func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw LoopbackCallbackError.bindFailed(error.localizedDescription)
        }
        self.listener = listener
        listener.start(queue: queue)
        // `.any` resolves only after `ready`; poll up to 1s for the bound port.
        let deadline = Date().addingTimeInterval(1.0)
        while listener.port == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let port = listener.port else {
            throw LoopbackCallbackError.bindFailed("no port assigned")
        }
        return port.rawValue
    }

    /// Awaits a single well-formed `GET <expectedPath>?...` request.
    /// Returns the full URL so the caller can parse query items via
    /// `parseCallback(url:expectedState:)`.
    public func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            guard let listener = listener else {
                cont.resume(throwing: LoopbackCallbackError.bindFailed("listener not started"))
                return
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection, cont: cont)
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - internals

    private func handle(connection: NWConnection, cont: CheckedContinuation<URL, Error>) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, err in
            defer { connection.cancel(); self?.stop() }
            if let err = err {
                cont.resume(throwing: LoopbackCallbackError.receiveFailed(err.localizedDescription))
                return
            }
            guard let data = data, let requestLine = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first else {
                cont.resume(throwing: LoopbackCallbackError.invalidRequest)
                return
            }
            // `GET /callback?... HTTP/1.1`
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                Self.send(connection: connection, status: "400 Bad Request", body: "bad request")
                cont.resume(throwing: LoopbackCallbackError.invalidRequest)
                return
            }
            let pathAndQuery = String(parts[1])
            guard let expected = self?.expectedPath, pathAndQuery.hasPrefix(expected) else {
                Self.send(connection: connection, status: "404 Not Found", body: "not found")
                cont.resume(throwing: LoopbackCallbackError.pathMismatch)
                return
            }
            let full = "http://127.0.0.1" + pathAndQuery
            guard let url = URL(string: full) else {
                cont.resume(throwing: LoopbackCallbackError.invalidRequest)
                return
            }
            Self.send(
                connection: connection,
                status: "200 OK",
                body: "Sign-in complete — you can close this tab."
            )
            cont.resume(returning: url)
        }
    }

    private static func send(connection: NWConnection, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in })
    }
}
#endif
