// WorkspaceSessionPresenceProbe.swift — lightweight HTTP probe for a
// single workspace_sessions row.
//
// The iOS terminal placeholder uses this to decide whether the terminal
// surface should mount for a seeded workspace session in E2E mode. The
// input session id still comes from the harness environment, but the
// source of truth for mount vs empty state is the backend response from
// `GET /api/repos/{owner}/{repo}/workspace/sessions/{id}`.

import Foundation

public enum RemoteWorkspaceSessionPresence: Equatable {
    case present
    case missing
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

        var request = URLRequest(url: workspaceSessionURL(
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

    private func workspaceSessionURL(
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
}
