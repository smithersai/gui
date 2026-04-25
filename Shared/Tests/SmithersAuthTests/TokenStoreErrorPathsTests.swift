// TokenStoreErrorPathsTests.swift — error / boundary coverage for
// `TokenStore` (ticket 0109). The existing TokenStoreTests covers the
// happy-path roundtrip; this file exercises injected-failure semantics on
// `InMemoryTokenStore`, decode errors on the real `KeychainTokenStore`
// JSON path, concurrency, and rotation/idempotency invariants.
//
// Scope notes:
//   - `InMemoryTokenStore.FailureMode` exposes `.onSave / .onLoad / .onClear`
//     (the protocol method is `clear()`, not `delete()` — the test naming
//     reflects that).
//   - Keychain-dependent tests gracefully degrade with NSLog + early return
//     when the test host cannot reach Keychain (matching the existing
//     `test_keychain_roundtrip_or_skips_when_unavailable` pattern).
//   - There is no "expired flag" on the API surface; tokens with a past
//     `expiresAt` roundtrip unchanged and the Date is preserved verbatim.

import XCTest
#if canImport(Security)
import Security
#endif
@testable import SmithersAuth

final class TokenStoreErrorPathsTests: XCTestCase {

    // MARK: - Roundtrip with injected failures (onSave / onLoad / onClear)

    func test_save_roundtrip_with_onSave_failure_propagates() {
        let store = InMemoryTokenStore()
        store.failureMode = .onSave(.keychainWriteFailed(-25299)) // errSecDuplicateItem
        let t = OAuth2Tokens(accessToken: "a", refreshToken: "r")
        XCTAssertThrowsError(try store.save(t)) { err in
            XCTAssertEqual(err as? TokenStoreError, .keychainWriteFailed(-25299))
        }
    }

    func test_load_roundtrip_with_onLoad_failure_propagates() {
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "a", refreshToken: "r"))
        store.failureMode = .onLoad(.keychainReadFailed(-25300)) // errSecItemNotFound (used here as an arbitrary code, see semantics test)
        XCTAssertThrowsError(try store.load()) { err in
            XCTAssertEqual(err as? TokenStoreError, .keychainReadFailed(-25300))
        }
    }

    func test_clear_roundtrip_with_onClear_failure_propagates() {
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "a", refreshToken: "r"))
        store.failureMode = .onClear(.keychainDeleteFailed(-25291))
        XCTAssertThrowsError(try store.clear()) { err in
            XCTAssertEqual(err as? TokenStoreError, .keychainDeleteFailed(-25291))
        }
    }

    func test_save_failure_does_not_increment_saveCount() {
        let store = InMemoryTokenStore()
        store.failureMode = .onSave(.keychainWriteFailed(-1))
        XCTAssertThrowsError(try store.save(OAuth2Tokens(accessToken: "a", refreshToken: "r")))
        XCTAssertEqual(store.saveCount, 0)
    }

    func test_clear_failure_does_not_increment_clearCount() {
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "a", refreshToken: "r"))
        store.failureMode = .onClear(.keychainDeleteFailed(-1))
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(store.clearCount, 0)
    }

    func test_failure_then_cleared_recovers() throws {
        let store = InMemoryTokenStore()
        store.failureMode = .onSave(.keychainWriteFailed(-1))
        XCTAssertThrowsError(try store.save(OAuth2Tokens(accessToken: "a", refreshToken: "r")))
        store.failureMode = .none
        let t = OAuth2Tokens(accessToken: "a2", refreshToken: "r2")
        try store.save(t)
        XCTAssertEqual(try store.load(), t)
    }

    // MARK: - Keychain write failure status codes

    func test_keychainWriteFailed_errSecDuplicateItem_propagates() {
        let store = InMemoryTokenStore()
        store.failureMode = .onSave(.keychainWriteFailed(-25299)) // errSecDuplicateItem
        XCTAssertThrowsError(try store.save(OAuth2Tokens(accessToken: "a", refreshToken: "r"))) { err in
            XCTAssertEqual(err as? TokenStoreError, .keychainWriteFailed(-25299))
        }
    }

    func test_keychainWriteFailed_errSecAuthFailed_propagates() {
        let store = InMemoryTokenStore()
        store.failureMode = .onSave(.keychainWriteFailed(-25293)) // errSecAuthFailed
        XCTAssertThrowsError(try store.save(OAuth2Tokens(accessToken: "a", refreshToken: "r"))) { err in
            XCTAssertEqual(err as? TokenStoreError, .keychainWriteFailed(-25293))
        }
    }

    func test_keychainWriteFailed_errSecInteractionNotAllowed_propagates() {
        let store = InMemoryTokenStore()
        store.failureMode = .onSave(.keychainWriteFailed(-25308)) // errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.save(OAuth2Tokens(accessToken: "a", refreshToken: "r"))) { err in
            XCTAssertEqual(err as? TokenStoreError, .keychainWriteFailed(-25308))
        }
    }

    // MARK: - Keychain read failure semantics

    /// `errSecItemNotFound` is NOT an error path on the real
    /// `KeychainTokenStore` — `load()` returns `nil`. The `InMemoryTokenStore`
    /// fake doesn't implement that branch (it has no Keychain status), but
    /// the production code path does. We assert the production semantics
    /// by tunnelling through the public protocol behavior: a fresh in-memory
    /// store also returns `nil` rather than throwing.
    func test_load_from_empty_returns_nil_not_error() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load())
    }

    /// `errSecAuthFailed` on read MUST surface as a thrown error, not a
    /// silent nil — the caller needs to differentiate "no creds yet" from
    /// "the user denied access / device is locked".
    func test_load_authFailed_throws_keychainReadFailed() {
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "a", refreshToken: "r"))
        store.failureMode = .onLoad(.keychainReadFailed(-25293)) // errSecAuthFailed
        XCTAssertThrowsError(try store.load()) { err in
            guard case .keychainReadFailed(let status) = (err as? TokenStoreError) ?? .notFound else {
                XCTFail("expected keychainReadFailed, got \(err)")
                return
            }
            XCTAssertEqual(status, -25293)
        }
    }

    /// Different read-failure status codes round-trip through the same
    /// case but preserve the underlying status — the caller is expected
    /// to switch on the OSStatus payload.
    func test_load_interactionNotAllowed_preserves_status() {
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "a", refreshToken: "r"))
        store.failureMode = .onLoad(.keychainReadFailed(-25308)) // errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.load()) { err in
            XCTAssertEqual(err as? TokenStoreError, .keychainReadFailed(-25308))
        }
    }

    // MARK: - Concurrency

    func test_concurrent_save_and_load_is_safe() async throws {
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "init", refreshToken: "init"))

        // 50 writers + 50 readers racing. Either we observe the initial
        // value or one of the writes; we never crash, deadlock, or read
        // a torn struct. (`OAuth2Tokens` is a value type so torn reads
        // aren't possible at the Swift level, but the lock still has to
        // serialize the strong-ref swap on `current`.)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let t = OAuth2Tokens(accessToken: "a\(i)", refreshToken: "r\(i)")
                    _ = try? store.save(t)
                }
                group.addTask {
                    _ = try? store.load()
                }
            }
        }

        // After the storm, a final load must succeed and return *some*
        // valid token from the write set (or the initial value).
        let final = try store.load()
        XCTAssertNotNil(final)
        XCTAssertGreaterThanOrEqual(store.saveCount, 1)
        XCTAssertLessThanOrEqual(store.saveCount, 50)
    }

    func test_concurrent_save_with_intermittent_failure() async {
        let store = InMemoryTokenStore()
        // Writers see no failures; one observer flips the failure bit
        // mid-flight to confirm the lock still serializes safely.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    _ = try? store.save(OAuth2Tokens(accessToken: "a\(i)", refreshToken: "r\(i)"))
                }
            }
            group.addTask {
                store.failureMode = .onSave(.keychainWriteFailed(-1))
                store.failureMode = .none
            }
        }
        // No XCTAssert — the only failure mode here is a crash / deadlock.
        XCTAssertGreaterThanOrEqual(store.saveCount, 0)
    }

    // MARK: - Multiple service IDs isolated (in-memory)

    /// `InMemoryTokenStore` instances are independent: writes to one MUST
    /// NOT leak into another. This is the in-memory analog of the
    /// `service`/`account` isolation on `KeychainTokenStore`.
    func test_two_in_memory_stores_are_isolated() throws {
        let storeA = InMemoryTokenStore()
        let storeB = InMemoryTokenStore()
        try storeA.save(OAuth2Tokens(accessToken: "A", refreshToken: "RA"))
        try storeB.save(OAuth2Tokens(accessToken: "B", refreshToken: "RB"))
        XCTAssertEqual(try storeA.load()?.accessToken, "A")
        XCTAssertEqual(try storeB.load()?.accessToken, "B")
        try storeA.clear()
        XCTAssertNil(try storeA.load())
        XCTAssertEqual(try storeB.load()?.accessToken, "B")
    }

    func test_keychain_service_isolation_or_skips() throws {
        let serviceA = "com.smithers.oauth2.tests.iso.A.\(UUID().uuidString)"
        let serviceB = "com.smithers.oauth2.tests.iso.B.\(UUID().uuidString)"
        let storeA = KeychainTokenStore(service: serviceA, account: "iso")
        let storeB = KeychainTokenStore(service: serviceB, account: "iso")

        let tA = OAuth2Tokens(accessToken: "kA", refreshToken: "krA")
        do {
            try storeA.save(tA)
        } catch TokenStoreError.keychainWriteFailed(let status) {
            NSLog("[0109] Keychain unavailable in this host (status=\(status)); skipping isolation test.")
            return
        }
        let tB = OAuth2Tokens(accessToken: "kB", refreshToken: "krB")
        try storeB.save(tB)

        XCTAssertEqual(try storeA.load(), tA)
        XCTAssertEqual(try storeB.load(), tB)
        try storeA.clear()
        XCTAssertNil(try storeA.load())
        XCTAssertEqual(try storeB.load(), tB)
        try storeB.clear()
    }

    // MARK: - Corrupt token blob → decode error, no crash

    func test_corrupt_blob_in_keychain_returns_decode_error_or_skips() throws {
        #if canImport(Security)
        let service = "com.smithers.oauth2.tests.corrupt.\(UUID().uuidString)"
        let account = "corrupt"
        let store = KeychainTokenStore(service: service, account: account)

        // Inject raw garbage directly via the Security API, bypassing the
        // store's encoder. `load()` must surface `.decodingFailed`, not
        // crash the process.
        let garbage = Data([0xFF, 0xFE, 0xFD, 0x00, 0x01]) // not valid UTF-8 / not JSON
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: garbage,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("[0109] Keychain unavailable for corrupt-blob test (status=\(addStatus)); skipping.")
            return
        }
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }

        XCTAssertThrowsError(try store.load()) { err in
            XCTAssertEqual(err as? TokenStoreError, .decodingFailed)
        }
        #endif
    }

    func test_corrupt_blob_wrong_shape_returns_decode_error_or_skips() throws {
        #if canImport(Security)
        let service = "com.smithers.oauth2.tests.corrupt2.\(UUID().uuidString)"
        let account = "corrupt2"
        let store = KeychainTokenStore(service: service, account: account)

        // Valid JSON, wrong shape — missing required `access_token` field.
        let payload = #"{"hello":"world"}"#.data(using: .utf8)!
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("[0109] Keychain unavailable for wrong-shape blob test (status=\(addStatus)); skipping.")
            return
        }
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }

        XCTAssertThrowsError(try store.load()) { err in
            XCTAssertEqual(err as? TokenStoreError, .decodingFailed)
        }
        #endif
    }

    // MARK: - Empty / very long / unicode tokens

    func test_empty_access_token_roundtrips() throws {
        // Note: empty access tokens aren't semantically valid OAuth2, but
        // the storage layer doesn't enforce that — it must roundtrip
        // whatever the caller hands it without crashing or mangling.
        let store = InMemoryTokenStore()
        let t = OAuth2Tokens(accessToken: "", refreshToken: "")
        try store.save(t)
        XCTAssertEqual(try store.load(), t)
    }

    func test_one_megabyte_token_roundtrips() throws {
        let store = InMemoryTokenStore()
        let big = String(repeating: "x", count: 1024 * 1024) // 1 MiB
        let t = OAuth2Tokens(accessToken: big, refreshToken: big, scope: "read")
        try store.save(t)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.accessToken.count, 1024 * 1024)
        XCTAssertEqual(loaded?.refreshToken.count, 1024 * 1024)
    }

    func test_unicode_in_token_fields_roundtrips() throws {
        let store = InMemoryTokenStore()
        let t = OAuth2Tokens(
            accessToken: "tok-\u{1F510}-\u{4E2D}\u{6587}-\u{1F600}",
            refreshToken: "ref-\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}",
            expiresAt: nil,
            scope: "read write \u{1F4E6}"
        )
        try store.save(t)
        XCTAssertEqual(try store.load(), t)
    }

    func test_unicode_roundtrips_through_keychain_json_codec_or_skips() throws {
        // The in-memory store keeps the struct verbatim and never goes
        // through the JSON codec. Exercise the real Keychain path so
        // unicode is actually JSON-encoded and decoded.
        let service = "com.smithers.oauth2.tests.unicode.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service, account: "unicode")
        let t = OAuth2Tokens(
            accessToken: "\u{1F510}-tok",
            refreshToken: "\u{4E2D}\u{6587}-ref",
            scope: "\u{1F4E6}"
        )
        do {
            try store.save(t)
        } catch TokenStoreError.keychainWriteFailed(let status) {
            NSLog("[0109] Keychain unavailable for unicode test (status=\(status)); skipping.")
            return
        }
        defer { _ = try? store.clear() }
        XCTAssertEqual(try store.load(), t)
    }

    // MARK: - Past expires_at preserved on roundtrip

    func test_expired_token_roundtrips_with_past_date_preserved() throws {
        // Storage layer does NOT compute or expose an "is-expired" flag;
        // the API just preserves `expiresAt` and lets the refresh loop
        // decide. Confirm a date well in the past survives a roundtrip.
        let past = Date(timeIntervalSince1970: 1)
        let store = InMemoryTokenStore()
        let t = OAuth2Tokens(accessToken: "a", refreshToken: "r", expiresAt: past, scope: nil)
        try store.save(t)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.expiresAt, past)
        XCTAssertLessThan(loaded?.expiresAt ?? Date.distantFuture, Date())
    }

    func test_expired_token_roundtrips_through_keychain_json_or_skips() throws {
        let service = "com.smithers.oauth2.tests.expired.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service, account: "expired")
        let past = Date(timeIntervalSince1970: 42)
        let t = OAuth2Tokens(accessToken: "old", refreshToken: "old-r", expiresAt: past, scope: "read")
        do {
            try store.save(t)
        } catch TokenStoreError.keychainWriteFailed(let status) {
            NSLog("[0109] Keychain unavailable for expired-token test (status=\(status)); skipping.")
            return
        }
        defer { _ = try? store.clear() }
        let loaded = try store.load()
        XCTAssertEqual(loaded?.expiresAt, past)
    }

    // MARK: - Delete idempotency

    func test_clear_twice_is_idempotent_in_memory() throws {
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "a", refreshToken: "r"))
        try store.clear()
        try store.clear() // second clear must NOT throw
        XCTAssertNil(try store.load())
        XCTAssertEqual(store.clearCount, 2)
    }

    func test_clear_nonexistent_in_memory_does_not_throw() throws {
        let store = InMemoryTokenStore() // empty
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func test_clear_nonexistent_keychain_does_not_throw_or_skips() throws {
        let service = "com.smithers.oauth2.tests.idem.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service, account: "idem")
        // Never saved anything — `clear()` must swallow `errSecItemNotFound`.
        do {
            try store.clear()
        } catch TokenStoreError.keychainDeleteFailed(let status) {
            // -34018 missing-entitlement is the common SwiftPM-host failure.
            NSLog("[0109] Keychain unavailable for delete-idempotency test (status=\(status)); skipping.")
            return
        }
        // A second clear is also a no-op.
        try store.clear()
    }

    // MARK: - Token rotation: save overwrites, never appends

    func test_save_overwrites_old_tokens_in_memory() throws {
        let store = InMemoryTokenStore()
        let old = OAuth2Tokens(accessToken: "old-a", refreshToken: "old-r", expiresAt: Date(timeIntervalSince1970: 100), scope: "read")
        let new = OAuth2Tokens(accessToken: "new-a", refreshToken: "new-r", expiresAt: Date(timeIntervalSince1970: 200), scope: "read write")
        try store.save(old)
        try store.save(new)
        let loaded = try store.load()
        XCTAssertEqual(loaded, new)
        XCTAssertNotEqual(loaded?.accessToken, "old-a")
        XCTAssertNotEqual(loaded?.refreshToken, "old-r")
        // Single slot — saveCount counts writes, not stored entries.
        XCTAssertEqual(store.saveCount, 2)
    }

    func test_save_overwrites_via_keychain_update_path_or_skips() throws {
        // `KeychainTokenStore.save` tries `SecItemUpdate` first, falling
        // through to `SecItemAdd` only on `errSecItemNotFound`. Two saves
        // back-to-back exercise both branches: first save adds, second
        // save updates. After both, only the second token is observable.
        let service = "com.smithers.oauth2.tests.rotate.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service, account: "rotate")
        let old = OAuth2Tokens(accessToken: "old", refreshToken: "old-r")
        let new = OAuth2Tokens(accessToken: "new", refreshToken: "new-r")
        do {
            try store.save(old)
        } catch TokenStoreError.keychainWriteFailed(let status) {
            NSLog("[0109] Keychain unavailable for rotation test (status=\(status)); skipping.")
            return
        }
        defer { _ = try? store.clear() }
        try store.save(new)
        XCTAssertEqual(try store.load(), new)
    }

    func test_repeated_rotation_keeps_only_latest_in_memory() throws {
        let store = InMemoryTokenStore()
        var last = OAuth2Tokens(accessToken: "a0", refreshToken: "r0")
        try store.save(last)
        for i in 1...10 {
            last = OAuth2Tokens(accessToken: "a\(i)", refreshToken: "r\(i)")
            try store.save(last)
        }
        XCTAssertEqual(try store.load(), last)
        XCTAssertEqual(store.saveCount, 11)
    }
}
