// PKCE.swift — RFC 7636 verifier + challenge derivation.
//
// SECURITY:
//   - Verifier is 32 cryptographically-random bytes per sign-in attempt. We
//     base64url-encode without padding, yielding 43 characters — within the
//     43–128 character bound of RFC 7636 section 4.1.
//   - Challenge is SHA-256 of the verifier ASCII bytes, base64url-encoded
//     without padding (method `S256`).
//   - The verifier is never persisted to disk or logged. The owning view
//     model holds it in memory for exactly one authorize round-trip.
//
// Ticket 0109. Reviewed against the RFC 7636 Appendix B test vectors —
// `Base64URLEncoding.decode("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")`
// produces the 32-byte sequence whose SHA-256 is the published challenge.

import Foundation
import CryptoKit
import Security

public enum PKCEError: Error, Equatable {
    case randomGenerationFailed(OSStatus)
    case invalidVerifierLength(Int)
    case invalidVerifierCharacters
}

public struct PKCEPair: Equatable, Sendable {
    public let verifier: String
    public let challenge: String
    public let method: String // always "S256"

    public init(verifier: String, challenge: String, method: String = "S256") {
        self.verifier = verifier
        self.challenge = challenge
        self.method = method
    }
}

public enum PKCE {
    /// Allowed verifier character set per RFC 7636 §4.1 (`[A-Z] [a-z] [0-9] - . _ ~`).
    /// Our base64url alphabet is a strict subset — `-` and `_` only, no `.` or `~`.
    static let verifierAllowedBytes: Set<UInt8> = {
        var s = Set<UInt8>()
        for b in UInt8(ascii: "A")...UInt8(ascii: "Z") { s.insert(b) }
        for b in UInt8(ascii: "a")...UInt8(ascii: "z") { s.insert(b) }
        for b in UInt8(ascii: "0")...UInt8(ascii: "9") { s.insert(b) }
        s.insert(UInt8(ascii: "-"))
        s.insert(UInt8(ascii: "."))
        s.insert(UInt8(ascii: "_"))
        s.insert(UInt8(ascii: "~"))
        return s
    }()

    /// Generates a fresh random verifier + S256 challenge.
    ///
    /// - Parameter randomSource: pluggable RNG for tests. Default uses
    ///   `SecRandomCopyBytes(kSecRandomDefault, _)`.
    public static func generate(
        randomSource: (Int) throws -> Data = PKCE.secureRandomBytes
    ) throws -> PKCEPair {
        let raw = try randomSource(32)
        let verifier = Base64URL.encode(raw)
        let challenge = challenge(forVerifier: verifier)
        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    /// Computes the S256 challenge for an arbitrary verifier string.
    /// Public so tests can feed in RFC 7636 Appendix B vectors directly.
    public static func challenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Base64URL.encode(Data(digest))
    }

    /// Validates that a string meets the RFC 7636 §4.1 verifier grammar.
    public static func validateVerifier(_ verifier: String) throws {
        let bytes = Array(verifier.utf8)
        guard (43...128).contains(bytes.count) else {
            throw PKCEError.invalidVerifierLength(bytes.count)
        }
        for b in bytes where !verifierAllowedBytes.contains(b) {
            throw PKCEError.invalidVerifierCharacters
        }
    }

    /// Default RNG bridging `SecRandomCopyBytes`.
    public static func secureRandomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw PKCEError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}

/// Minimal base64url (no padding) encoder/decoder. Used for PKCE and the
/// authorize-request `state` parameter.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: pad)
        return Data(base64Encoded: s)
    }
}
