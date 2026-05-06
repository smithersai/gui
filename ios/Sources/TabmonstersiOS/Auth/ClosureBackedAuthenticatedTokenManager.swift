#if os(iOS)
import Foundation
#if canImport(SmithersAuth)
import SmithersAuth
#endif

final class ClosureBackedAuthenticatedTokenManager: AuthenticatedHTTPTokenManaging {
    private let bearerProvider: @Sendable () -> String?

    init(bearerProvider: @escaping @Sendable () -> String?) {
        self.bearerProvider = bearerProvider
    }

    func performWithRetry<T>(_ perform: (String) async throws -> T?) async throws -> T {
        guard let first = bearerProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else {
            throw AuthenticatedHTTPClientError.authExpired
        }
        if let value = try await perform(first) {
            return value
        }

        guard let second = bearerProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !second.isEmpty else {
            throw AuthenticatedHTTPClientError.authExpired
        }
        if let value = try await perform(second) {
            return value
        }
        throw AuthenticatedHTTPClientError.authExpired
    }
}
#endif
