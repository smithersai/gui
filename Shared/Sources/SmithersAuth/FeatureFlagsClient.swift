import Combine
import Foundation

public enum FeatureFlagsEnvironment {
    public static let remoteSandboxEnvVar = "PLUE_REMOTE_SANDBOX_ENABLED"

    public static func remoteSandboxEnabledOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        guard let raw = environment[remoteSandboxEnvVar]?.lowercased() else {
            return nil
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

public struct FeatureFlagsSnapshot: Equatable, Sendable {
    public static let empty = FeatureFlagsSnapshot(flags: [:])

    public let flags: [String: Bool]

    public init(flags: [String: Bool]) {
        self.flags = flags
    }

    public var isRemoteSandboxEnabled: Bool {
        flag(named: "remote_sandbox_enabled")
    }

    public var isApprovalsFlowEnabled: Bool {
        flag(named: "approvals_flow_enabled")
    }

    public var isElectricClientEnabled: Bool {
        flag(named: "electric_client_enabled")
    }

    public var isDevtoolsSnapshotEnabled: Bool {
        flag(named: "devtools_snapshot_enabled")
    }

    public var isRunShapeEnabled: Bool {
        flag(named: "run_shape_enabled")
    }

    public func effectiveRemoteSandboxEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        FeatureFlagsEnvironment.remoteSandboxEnabledOverride(
            environment: environment
        ) ?? isRemoteSandboxEnabled
    }

    public func flag(named name: String) -> Bool {
        flags[name] == true
    }
}

public enum FeatureFlagsError: Error, Equatable {
    case notSignedIn
    case unauthorized
    case badStatus(Int, String)
    case invalidResponse
    case transport(String)
}

@MainActor
public final class FeatureFlagsClient: ObservableObject {
    public typealias BearerProvider = @Sendable () throws -> String?
    public typealias MockResponseProvider = @Sendable () async throws -> FeatureFlagsSnapshot?

    @Published public private(set) var snapshot: FeatureFlagsSnapshot
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastRefreshAt: Date?
    @Published public private(set) var lastErrorDescription: String?

    public let ttl: TimeInterval

    private let baseURL: URL
    private let transport: HTTPTransport
    private let bearerProvider: BearerProvider
    private let now: @Sendable () -> Date
    private var cachedAt: Date?
    private var inFlightRefresh: Task<FeatureFlagsSnapshot, Error>?
    private var mockResponseProvider: MockResponseProvider?

    public init(
        baseURL: URL,
        transport: HTTPTransport = URLSessionHTTPTransport(),
        bearerProvider: @escaping BearerProvider,
        ttl: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        initialSnapshot: FeatureFlagsSnapshot = .empty,
        mockResponseProvider: MockResponseProvider? = nil
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.bearerProvider = bearerProvider
        self.ttl = ttl
        self.now = now
        self.snapshot = initialSnapshot
        self.mockResponseProvider = mockResponseProvider
    }

    public var isRemoteSandboxEnabled: Bool { snapshot.isRemoteSandboxEnabled }
    public func effectiveRemoteSandboxEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        snapshot.effectiveRemoteSandboxEnabled(environment: environment)
    }
    public var isApprovalsFlowEnabled: Bool { snapshot.isApprovalsFlowEnabled }
    public var isElectricClientEnabled: Bool { snapshot.isElectricClientEnabled }
    public var isDevtoolsSnapshotEnabled: Bool { snapshot.isDevtoolsSnapshotEnabled }
    public var isRunShapeEnabled: Bool { snapshot.isRunShapeEnabled }

    @discardableResult
    public func refresh(force: Bool = false) async throws -> FeatureFlagsSnapshot {
        if !force,
           let cachedAt,
           now().timeIntervalSince(cachedAt) < ttl {
            return snapshot
        }

        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }

        isRefreshing = true
        let task = Task<FeatureFlagsSnapshot, Error> { [baseURL, transport, bearerProvider, mockResponseProvider] in
            if let mockResponseProvider,
               let mocked = try await mockResponseProvider() {
                return mocked
            }

            guard let token = try bearerProvider(), !token.isEmpty else {
                throw FeatureFlagsError.notSignedIn
            }

            var request = URLRequest(url: baseURL.appendingPathComponent("api/feature-flags"))
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            do {
                let (data, status, _) = try await transport.send(request)
                guard (200...299).contains(status) else {
                    if status == 401 {
                        throw FeatureFlagsError.unauthorized
                    }
                    let snippet = String(data: data.prefix(256), encoding: .utf8) ?? ""
                    throw FeatureFlagsError.badStatus(status, snippet)
                }
                return try Self.decodeSnapshot(from: data)
            } catch let error as FeatureFlagsError {
                throw error
            } catch let error as OAuth2Error {
                switch error {
                case .unauthorized:
                    throw FeatureFlagsError.unauthorized
                case .transport(let message):
                    throw FeatureFlagsError.transport(message)
                case .badStatus(let status, let snippet):
                    throw FeatureFlagsError.badStatus(status, snippet)
                default:
                    throw FeatureFlagsError.transport(AuthViewModel.describe(error))
                }
            } catch {
                throw FeatureFlagsError.transport(error.localizedDescription)
            }
        }

        inFlightRefresh = task

        do {
            let refreshed = try await task.value
            apply(snapshot: refreshed, at: now())
            inFlightRefresh = nil
            isRefreshing = false
            lastErrorDescription = nil
            return refreshed
        } catch {
            inFlightRefresh = nil
            isRefreshing = false
            lastErrorDescription = Self.describe(error)
            throw error
        }
    }

    private func apply(snapshot: FeatureFlagsSnapshot, at date: Date) {
        self.snapshot = snapshot
        self.cachedAt = date
        self.lastRefreshAt = date
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let featureFlagsError as FeatureFlagsError:
            switch featureFlagsError {
            case .notSignedIn:
                return "Not signed in."
            case .unauthorized:
                return "Unauthorized."
            case .badStatus(let status, _):
                return "Server returned status \(status)."
            case .invalidResponse:
                return "Server returned an unexpected response."
            case .transport(let message):
                return message
            }
        default:
            return error.localizedDescription
        }
    }

    private static func decodeSnapshot(from data: Data) throws -> FeatureFlagsSnapshot {
        if let envelope = try? JSONDecoder().decode(FeatureFlagsEnvelope.self, from: data) {
            return FeatureFlagsSnapshot(flags: envelope.flags)
        }
        if let direct = try? JSONDecoder().decode([String: Bool].self, from: data) {
            return FeatureFlagsSnapshot(flags: direct)
        }
        throw FeatureFlagsError.invalidResponse
    }
}

private struct FeatureFlagsEnvelope: Decodable {
    let flags: [String: Bool]
}
