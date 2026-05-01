import Foundation

/// Normalized response for authenticated HTTP calls.
///
/// Callers receive the full response envelope regardless of status so they can
/// continue handling rate limits (`429`), validation failures, and quota
/// failures without this client forcing an error for non-auth statuses.
public struct AuthenticatedHTTPResponse: Equatable, Sendable {
    public let body: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(body: Data, statusCode: Int, headers: [String: String]) {
        self.body = body
        self.statusCode = statusCode
        self.headers = headers
    }
}

public enum AuthenticatedHTTPClientError: Error, Equatable {
    /// Session is missing/expired or refresh failed. Callers should treat this
    /// as sign-out required rather than a generic backend failure.
    case authExpired
    /// Failed to build a request for send/replay.
    case requestBuildFailed(String)
    /// Transport failed before we received an HTTP response.
    case transport(String)
}

/// Retry contract required by `AuthenticatedHTTPClient`.
///
/// `TokenManager` already provides serialized refresh + single-retry behavior
/// via `performWithRetry`; this protocol keeps the client unit-testable with a
/// fake token manager.
public protocol AuthenticatedHTTPTokenManaging: AnyObject {
    func performWithRetry<T>(
        _ perform: (String) async throws -> T?
    ) async throws -> T
}

extension TokenManager: AuthenticatedHTTPTokenManaging {}

/// Shared authenticated transport wrapper for all bearer-protected calls.
///
/// Intended adoption pattern:
/// 1. Build your endpoint-specific `URLRequest`.
/// 2. Route it through `send(_:)` (or `send(buildRequest:)` for replay-safe
///    request construction).
/// 3. Handle `AuthenticatedHTTPClientError.authExpired` as session-expired;
///    parse `AuthenticatedHTTPResponse` for all other HTTP statuses.
///
/// This client never force-fails non-auth statuses. It only throws on:
/// - missing/expired session and refresh failures (`authExpired`)
/// - request build failures
/// - transport failures with no HTTP response.
public final class AuthenticatedHTTPClient {
    public typealias RequestBuilder = @Sendable () throws -> URLRequest

    private let tokenManager: AuthenticatedHTTPTokenManaging
    private let transport: HTTPTransport

    public init(
        tokenManager: AuthenticatedHTTPTokenManaging,
        transport: HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.tokenManager = tokenManager
        self.transport = transport
    }

    /// Sends a prebuilt request with bearer auth.
    ///
    /// Use this when the request body is replay-safe via `URLRequest` copy
    /// semantics. For non-replayable bodies, prefer `send(buildRequest:)`.
    public func send(_ request: URLRequest) async throws -> AuthenticatedHTTPResponse {
        try await send(buildRequest: { request })
    }

    /// Sends a request built per attempt (first call + possible refresh retry).
    ///
    /// The builder runs once per attempt so replay can rebuild request state
    /// when needed.
    public func send(buildRequest: @escaping RequestBuilder) async throws -> AuthenticatedHTTPResponse {
        do {
            return try await tokenManager.performWithRetry { [transport] accessToken in
                let request: URLRequest
                do {
                    request = try Self.authorizedRequest(buildRequest: buildRequest, accessToken: accessToken)
                } catch let error as AuthenticatedHTTPClientError {
                    throw error
                } catch {
                    throw AuthenticatedHTTPClientError.requestBuildFailed(error.localizedDescription)
                }

                do {
                    let (body, statusCode, headers) = try await transport.send(request)
                    let response = AuthenticatedHTTPResponse(body: body, statusCode: statusCode, headers: headers)
                    if statusCode == 401 {
                        // Trigger TokenManager's serialized refresh + one retry.
                        return nil
                    }
                    return response
                } catch let error as AuthenticatedHTTPClientError {
                    throw error
                } catch {
                    throw AuthenticatedHTTPClientError.transport(error.localizedDescription)
                }
            }
        } catch let error as AuthenticatedHTTPClientError {
            throw error
        } catch let error as TokenManagerError {
            throw Self.mapTokenManagerError(error)
        } catch {
            throw AuthenticatedHTTPClientError.transport(error.localizedDescription)
        }
    }

    private static func authorizedRequest(
        buildRequest: RequestBuilder,
        accessToken: String
    ) throws -> URLRequest {
        var request = try buildRequest()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func mapTokenManagerError(_ error: TokenManagerError) -> AuthenticatedHTTPClientError {
        switch error {
        case .notSignedIn:
            return .authExpired
        case .refreshFailed:
            return .authExpired
        case .persistenceFailed:
            return .authExpired
        case .whitelistDenied:
            return .authExpired
        }
    }
}
