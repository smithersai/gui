// PKCETests.swift — RFC 7636 test vectors + randomness + bounds.
//
// Ticket 0109.

import XCTest
@testable import SmithersAuth

final class PKCETests: XCTestCase {

    // RFC 7636 Appendix B:
    //   code_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    //   code_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    func test_RFC7636_AppendixB_vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(PKCE.challenge(forVerifier: verifier), expectedChallenge)
    }

    func test_generate_verifier_length_and_charset() throws {
        let pair = try PKCE.generate()
        let count = pair.verifier.utf8.count
        XCTAssertGreaterThanOrEqual(count, 43)
        XCTAssertLessThanOrEqual(count, 128)
        try PKCE.validateVerifier(pair.verifier)
        XCTAssertEqual(pair.method, "S256")
        XCTAssertEqual(pair.challenge, PKCE.challenge(forVerifier: pair.verifier))
    }

    func test_generate_is_random_per_call() throws {
        var set = Set<String>()
        for _ in 0..<32 {
            set.insert(try PKCE.generate().verifier)
        }
        XCTAssertEqual(set.count, 32, "PKCE verifier must be unique every invocation")
    }

    func test_generate_uses_injected_random_source() throws {
        let fixed = Data(repeating: 0xAB, count: 32)
        let pair = try PKCE.generate(randomSource: { count in
            XCTAssertEqual(count, 32)
            return fixed
        })
        XCTAssertEqual(pair.verifier, Base64URL.encode(fixed))
    }

    func test_validateVerifier_rejects_too_short() {
        XCTAssertThrowsError(try PKCE.validateVerifier("short"))
    }

    func test_validateVerifier_rejects_illegal_character() {
        // Include a `+` which is NOT in the RFC's unreserved set.
        let bad = String(repeating: "a", count: 42) + "+"
        XCTAssertThrowsError(try PKCE.validateVerifier(bad))
    }

    func test_base64URL_roundtrip() {
        let cases: [(raw: Data, encoded: String)] = [
            (Data([0x01]), "AQ"),
            (Data([0xFB, 0xEF]), "--8"),
            (Data([0x00, 0x00, 0x00]), "AAAA"),
        ]
        for c in cases {
            XCTAssertEqual(Base64URL.encode(c.raw), c.encoded)
            XCTAssertEqual(Base64URL.decode(c.encoded), c.raw)
        }
    }
}
