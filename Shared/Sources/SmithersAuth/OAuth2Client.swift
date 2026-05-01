// OAuth2Client.swift — wire-level OAuth2 exchange, refresh, revoke.
//
// Ticket 0109. Mirrors plue's `/api/oauth2/token`, `/api/oauth2/revoke`,
// and `/api/oauth2/revoke-all` routes. Network I/O is injected via
// `HTTPTransport` so unit tests can feed fixed responses and assert request
// shapes without touching the real wire.

import Foundation

/// Config pairs with the plue-registered public client from 0106.
public struct OAuth2ClientConfig: Equatable, Sendable {
    public let baseURL: URL
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]
    public let audience: String?

    public init(
        baseURL: URL,
        clientID: String,
        redirectURI: String,
        scopes: [String] = ["read", "write"],
        audience: String? = nil
    ) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.audience = audience
    }
}

public enum OAuth2Error: Error, Equatable {
    case unauthorized // 401 on token exchange / refresh
    case invalidGrant(String) // server returned `invalid_grant` or similar
    case whitelistDenied(String) // structured error from plue; render static page
    case badStatus(Int, String)
    case invalidResponse
    case transport(String)
}

/// Cheap authenticated probe used by restored-session bootstrap paths.
/// `.indeterminate` preserves the existing session when the backend is
/// temporarily unavailable, while `.invalid` is reserved for clear auth
/// failures from plue.
public enum AccessTokenValidationResult: Equatable {
    case valid
    case invalid
    case indeterminate
}

/// Small `URLSession`-style indirection so we can stub the wire in tests.
public protocol HTTPTransport: AnyObject {
    /// Returns (data, HTTP status, headers). Callers assume the body is
    /// already complete — no streaming use cases here.
    func send(_ request: URLRequest) async throws -> (Data, Int, [String: String])
}

public final class URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, Int, [String: String]) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OAuth2Error.invalidResponse
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let key = k as? String, let value = v as? String {
                    headers[key] = value
                }
            }
            return (data, http.statusCode, headers)
        } catch let err as OAuth2Error {
            throw err
        } catch {
            throw OAuth2Error.transport(error.localizedDescription)
        }
    }
}

/// Plue structured error body. Matches what 0106 returns on non-2xx.
/// See RFC 6749 §5.2 for the `error`/`error_description` convention.
public struct OAuth2ErrorBody: Decodable, Equatable {
    public let error: String
    public let error_description: String?
}

enum RevokeAllResult: Equatable {
    case revoked
    case unavailable
    case failed
}

public final class OAuth2Client {
    public let config: OAuth2ClientConfig
    public let transport: HTTPTransport

    public init(config: OAuth2ClientConfig, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.config = config
        self.transport = transport
    }

    /// Builds the authorize URL the `ASWebAuthenticationSession` will open.
    /// The verifier is held in memory by the view model — only the
    /// challenge travels in the URL.
    public func authorizeURL(pkce: PKCEPair, state: String) -> URL {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent("api/oauth2/authorize"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
        ]
        if let audience = config.audience {
            items.append(.init(name: "audience", value: audience))
        }
        comps.queryItems = items
        return comps.url!
    }

    /// Exchanges an authorization code + verifier for tokens.
    public func exchange(code: String, verifier: String) async throws -> OAuth2Tokens {
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "client_id", value: config.clientID),
            .init(name: "code_verifier", value: verifier),
        ]
        return try await postToken(body: form.percentEncodedQuery ?? "")
    }

    /// Refresh-token rotation. Atomicity is the *caller's* problem — this
    /// method merely returns the new tokens. `TokenManager.refresh()` wires
    /// the write-before-retry contract on top.
    public func refresh(refreshToken: String) async throws -> OAuth2Tokens {
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "client_id", value: config.clientID),
        ]
        return try await postToken(body: form.percentEncodedQuery ?? "")
    }

    /// Verifies whether an access token still authenticates against plue's
    /// cheap `/api/user` endpoint.
    public func validateAccessToken(_ accessToken: String) async -> AccessTokenValidationResult {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("api/user"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, status, _) = try await transport.send(req)
            switch status {
            case 200...299:
                return .valid
            case 400, 401, 403:
                return .invalid
            default:
                return .indeterminate
            }
        } catch {
            return .indeterminate
        }
    }

    /// Best-effort app-wide revoke. When the route does not exist on the
    /// target plue build, returns `.unavailable` so callers can fall back
    /// to per-token revocation. All other failures are non-fatal.
    func revokeAll(accessToken: String) async -> RevokeAllResult {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("api/oauth2/revoke-all"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, status, _) = try await transport.send(req)
            switch status {
            case 200...299:
                return .revoked
            case 404, 405:
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Best-effort revoke. We treat network errors here as
    /// non-fatal — the local wipe must still happen (per 0133 threat model).
    public func revoke(accessToken: String) async {
        await revoke(token: accessToken, tokenTypeHint: "access_token")
    }

    /// Best-effort revoke. We treat network errors here as
    /// non-fatal — the local wipe must still happen (per 0133 threat model).
    public func revoke(refreshToken: String) async {
        await revoke(token: refreshToken, tokenTypeHint: "refresh_token")
    }

    // MARK: - Internals

    private func revoke(token: String, tokenTypeHint: String) async {
        var form = URLComponents()
        form.queryItems = [
            .init(name: "token", value: token),
            .init(name: "client_id", value: config.clientID),
            .init(name: "token_type_hint", value: tokenTypeHint),
        ]
        var req = URLRequest(url: config.baseURL.appendingPathComponent("api/oauth2/revoke"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = (form.percentEncodedQuery ?? "").data(using: .utf8)
        _ = try? await transport.send(req)
    }

    private func postToken(body: String) async throws -> OAuth2Tokens {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("api/oauth2/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body.data(using: .utf8)

        let (data, status, _) = try await transport.send(req)

        guard (200...299).contains(status) else {
            if let err = try? JSONDecoder().decode(OAuth2ErrorBody.self, from: data) {
                if err.error == "access_not_yet_granted" || err.error == "whitelist_denied" {
                    throw OAuth2Error.whitelistDenied(err.error_description ?? "Access not yet granted.")
                }
                if err.error == "invalid_grant" || err.error == "invalid_request" {
                    throw OAuth2Error.invalidGrant(err.error_description ?? err.error)
                }
            }
            if status == 401 { throw OAuth2Error.unauthorized }
            let snippet = String(data: data.prefix(256), encoding: .utf8) ?? ""
            throw OAuth2Error.badStatus(status, snippet)
        }

        struct Response: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
            let scope: String?
        }

        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OAuth2Error.invalidResponse
        }
        let expiresAt = resp.expires_in.map { Date().addingTimeInterval($0) }
        return OAuth2Tokens(
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token,
            expiresAt: expiresAt,
            scope: resp.scope
        )
    }
}
