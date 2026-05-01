// WorkspaceSessionPresenceProbe.swift — lightweight HTTP probe for a
// single workspace_sessions row.
//
// Production iOS workspace detail uses this probe to determine whether a
// terminal can attach for the selected workspace/session context sourced
// from backend workspace data. E2E can still opt into seeded env vars as
// an explicit shortcut, but probe behavior and route contract are the
// same for production and tests.

import Foundation

public enum RemoteWorkspaceSessionPresence: Equatable {
    case present
    case missing
}

public enum WorkspaceSessionRoutes {
    /// Canonical workspace-session REST path used by iOS probe and tests.
    public static func sessionURL(
        baseURL: URL,
        repoOwner: String,
        repoName: String,
        sessionID: String
    ) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("repos")
            .appendingPathComponent(repoOwner)
            .appendingPathComponent(repoName)
            .appendingPathComponent("workspace")
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
    }

    /// Canonical terminal websocket fallback route when backend does not
    /// return a concrete attach URL.
    public static func fallbackTerminalWebSocketURL(
        baseURL: URL,
        repoOwner: String,
        repoName: String,
        sessionID: String
    ) -> URL {
        var components = URLComponents(
            url: sessionURL(
                baseURL: baseURL,
                repoOwner: repoOwner,
                repoName: repoName,
                sessionID: sessionID
            ).appendingPathComponent("terminal"),
            resolvingAgainstBaseURL: false
        )
        switch components?.scheme?.lowercased() {
        case "http":
            components?.scheme = "ws"
        case "https":
            components?.scheme = "wss"
        default:
            break
        }
        return components?.url ?? baseURL
    }
}

public protocol RemoteWorkspaceSessionPresenceProbe: Sendable {
    func fetch(
        repoOwner: String,
        repoName: String,
        sessionID: String
    ) async throws -> RemoteWorkspaceSessionPresence
}

public enum RemoteWorkspaceSessionPresenceError: Error, Equatable {
    case authExpired
    case backendUnavailable(String)
}

public final class URLSessionRemoteWorkspaceSessionPresenceProbe: RemoteWorkspaceSessionPresenceProbe, @unchecked Sendable {
    public typealias BearerProvider = @Sendable () -> String?

    private let baseURL: URL
    private let bearer: BearerProvider
    private let session: URLSession

    public init(
        baseURL: URL,
        bearer: @escaping BearerProvider,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearer = bearer
        self.session = session
    }

    public func fetch(
        repoOwner: String,
        repoName: String,
        sessionID: String
    ) async throws -> RemoteWorkspaceSessionPresence {
        guard let token = bearer() else {
            throw RemoteWorkspaceSessionPresenceError.authExpired
        }

        var request = URLRequest(url: WorkspaceSessionRoutes.sessionURL(
            baseURL: baseURL,
            repoOwner: repoOwner,
            repoName: repoName,
            sessionID: sessionID
        ))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode {
            case 200:
                return .present
            case 404:
                return .missing
            case 401, 403:
                throw RemoteWorkspaceSessionPresenceError.authExpired
            default:
                throw RemoteWorkspaceSessionPresenceError.backendUnavailable("HTTP \(http?.statusCode ?? -1)")
            }
        } catch let error as RemoteWorkspaceSessionPresenceError {
            throw error
        } catch {
            throw RemoteWorkspaceSessionPresenceError.backendUnavailable("\(error)")
        }
    }
}
