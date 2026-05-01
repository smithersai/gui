// AuthPKCETests.swift — iOS-target wrapper around the shared PKCE tests.
//
// Ticket 0109. The canonical PKCE unit suite lives in
// Shared/Tests/SmithersAuthTests (runs under `swift test` in the Shared
// sub-package). This file re-verifies the RFC 7636 vector and basic
// invariants from the iOS xctest host, so the iOS simulator test loop
// catches any platform-specific CryptoKit/Security regression.

#if os(iOS)
import XCTest
@testable import SmithersiOS

final class AuthPKCETests: XCTestCase {
    func test_RFC7636_vector_matches_on_iOS() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(PKCE.challenge(forVerifier: verifier), expected)
    }

    func test_generate_is_random_per_call_on_iOS() throws {
        let a = try PKCE.generate().verifier
        let b = try PKCE.generate().verifier
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.utf8.count, 43)
        XCTAssertLessThanOrEqual(a.utf8.count, 128)
    }

    func test_keychain_store_roundtrip_on_simulator() throws {
        let service = "com.smithers.ios.tests.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service, account: "roundtrip")
        let t = OAuth2Tokens(accessToken: "i_a", refreshToken: "i_r")

        do {
            try store.save(t)
            XCTAssertEqual(try store.load(), t)
            try store.clear()
            XCTAssertNil(try store.load())
        } catch let error as TokenStoreError {
            if case .keychainWriteFailed(-34018) = error {
                throw XCTSkip("Simulator keychain is unavailable in this environment (\(error)).")
            }
            throw error
        }
    }
}
#endif
