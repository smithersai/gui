import XCTest
@testable import SmithersGUI

final class KeyboardShortcutSettingsFileStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var settingsFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardShortcutSettingsFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        settingsFileURL = temporaryDirectory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        settingsFileURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeStore(
        url: URL? = nil,
        startWatching: Bool = false
    ) -> KeyboardShortcutSettingsFileStore {
        KeyboardShortcutSettingsFileStore(
            settingsFileURL: url ?? settingsFileURL,
            startWatching: startWatching
        )
    }

    private func writeSettings(
        _ shortcuts: [String: StoredShortcut],
        wrappedKey: String = "bindings",
        to url: URL? = nil
    ) throws {
        let target = url ?? settingsFileURL!
        let encoded = try shortcuts.mapValues { shortcut -> [String: Any] in
            let data = try JSONEncoder().encode(shortcut)
            let object = try JSONSerialization.jsonObject(with: data)
            return try XCTUnwrap(object as? [String: Any])
        }
        let payload: [String: Any] = ["shortcuts": [wrappedKey: encoded]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: target, options: .atomic)
    }

    private func writeFlatShortcuts(
        _ shortcuts: [String: StoredShortcut],
        to url: URL? = nil
    ) throws {
        let target = url ?? settingsFileURL!
        let encoded = try shortcuts.mapValues { shortcut -> [String: Any] in
            let data = try JSONEncoder().encode(shortcut)
            let object = try JSONSerialization.jsonObject(with: data)
            return try XCTUnwrap(object as? [String: Any])
        }
        let payload: [String: Any] = ["shortcuts": encoded]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: target, options: .atomic)
    }

    private func writeRaw(_ string: String, to url: URL? = nil) throws {
        let target = url ?? settingsFileURL!
        try string.write(to: target, atomically: true, encoding: .utf8)
    }

    // MARK: - Initial load

    func testInitWithMissingFileLoadsEmptyOverrides() {
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithMissingFileCreatesParentDirectory() {
        let nested = temporaryDirectory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("settings.json")
        _ = makeStore(url: nested)
        let parent = nested.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
    }

    func testInitWithExistingValidJSONLoadsOverrides() throws {
        let shortcut = StoredShortcut(key: "b", command: true)
        try writeSettings(["toggleSidebar": shortcut])
        let store = makeStore()
        XCTAssertEqual(store.override(for: .toggleSidebar), shortcut)
    }

    func testInitWithFlatShortcutsSectionLoadsOverrides() throws {
        let shortcut = StoredShortcut(key: "b", command: true)
        try writeFlatShortcuts(["toggleSidebar": shortcut])
        let store = makeStore()
        XCTAssertEqual(store.override(for: .toggleSidebar), shortcut)
    }

    // MARK: - Malformed / edge JSON

    func testInitWithMalformedJSONReturnsEmptyOverrides() throws {
        try writeRaw("{ this is not valid json", to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithTruncatedJSONReturnsEmptyOverrides() throws {
        try writeRaw("{\"shortcuts\":{\"bindings\":{\"toggleSidebar\":{\"key\":\"b\",\"command\":tr", to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithInvalidUTF8ReturnsEmptyOverrides() throws {
        let bad = Data([0xFF, 0xFE, 0xFD, 0xFC, 0x00, 0x80])
        try bad.write(to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithEmptyFileReturnsEmptyOverrides() throws {
        try Data().write(to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithEmptyObjectReturnsEmptyOverrides() throws {
        try writeRaw("{}", to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithJSONArrayRootReturnsEmptyOverrides() throws {
        try writeRaw("[]", to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithJSONNullRootReturnsEmptyOverrides() throws {
        try writeRaw("null", to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithWrongShapeForShortcutsReturnsEmptyOverrides() throws {
        try writeRaw("{\"shortcuts\":\"this is wrong\"}", to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testInitWithUnknownActionIsIgnored() throws {
        let shortcut = StoredShortcut(key: "b", command: true)
        try writeSettings([
            "toggleSidebar": shortcut,
            "noSuchAction": StoredShortcut(key: "z", command: true),
        ])
        let store = makeStore()
        XCTAssertEqual(store.override(for: .toggleSidebar), shortcut)
        XCTAssertEqual(store.overrides.count, 1)
    }

    func testInitWithBindingValueWrongShapeIsIgnored() throws {
        let payload: [String: Any] = [
            "shortcuts": [
                "bindings": [
                    "toggleSidebar": "not-an-object",
                    "newTerminal": ["key": "x", "command": true],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: settingsFileURL)
        let store = makeStore()
        XCTAssertNil(store.override(for: .toggleSidebar))
        XCTAssertEqual(store.override(for: .newTerminal), StoredShortcut(key: "x", command: true))
    }

    func testInitWithBindingMissingKeyFieldIsIgnored() throws {
        let payload: [String: Any] = [
            "shortcuts": [
                "bindings": [
                    "toggleSidebar": ["command": true], // missing required `key`
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: settingsFileURL)
        let store = makeStore()
        XCTAssertNil(store.override(for: .toggleSidebar))
    }

    // MARK: - Numbered normalization

    func testNumberedActionWithNonDigitIsRejected() throws {
        // selectWorkspaceByNumber is numbered; non-digit should fail normalization
        try writeSettings(["selectWorkspaceByNumber": StoredShortcut(key: "x", command: true)])
        let store = makeStore()
        XCTAssertNil(store.override(for: .selectWorkspaceByNumber))
    }

    func testNumberedActionWithDigitIsNormalizedToOne() throws {
        try writeSettings(["selectWorkspaceByNumber": StoredShortcut(key: "5", command: true)])
        let store = makeStore()
        let stored = store.override(for: .selectWorkspaceByNumber)
        XCTAssertEqual(stored?.key, "1")
        XCTAssertEqual(stored?.command, true)
    }

    // MARK: - Reload roundtrip / replacement

    func testReloadAfterExternalWriteUpdatesOverrides() throws {
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)

        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true, option: true)])
        store.reload(notify: false)

        XCTAssertEqual(
            store.override(for: .toggleSidebar),
            StoredShortcut(key: "b", command: true, option: true)
        )
    }

    func testReloadReplacesExistingOverride() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore()
        XCTAssertEqual(store.override(for: .toggleSidebar)?.key, "b")

        try writeSettings(["toggleSidebar": StoredShortcut(key: "z", command: true, shift: true)])
        store.reload(notify: false)

        XCTAssertEqual(
            store.override(for: .toggleSidebar),
            StoredShortcut(key: "z", command: true, shift: true)
        )
    }

    func testReloadAfterFileDeletionClearsOverrides() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore()
        XCTAssertFalse(store.overrides.isEmpty)

        try FileManager.default.removeItem(at: settingsFileURL)
        store.reload(notify: false)
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testReloadNotifiesListenersWhenContentChanges() throws {
        let store = makeStore()
        let expectation = expectation(description: "settings change notification")
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        store.reload()

        wait(for: [expectation], timeout: 2.0)
    }

    func testReloadDoesNotNotifyWhenContentUnchanged() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore()

        let expectation = expectation(description: "no notification")
        expectation.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.reload()
        wait(for: [expectation], timeout: 0.5)
    }

    // MARK: - Public API

    func testIsManagedByFileTrueWhenOverridePresent() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore()
        XCTAssertTrue(store.isManagedByFile(.toggleSidebar))
        XCTAssertFalse(store.isManagedByFile(.newTerminal))
    }

    func testSettingsFileURLForEditingReturnsConfiguredURL() {
        let store = makeStore()
        XCTAssertEqual(store.settingsFileURLForEditing(), settingsFileURL)
    }

    func testSettingsFileDisplayPathAbbreviatesHome() {
        let store = makeStore()
        let path = store.settingsFileDisplayPath()
        // For a /var/folders/... temp path this won't include `~`; just ensure
        // it's the abbreviated form (matches NSString abbreviation rules).
        let expected = (settingsFileURL.path as NSString).abbreviatingWithTildeInPath
        XCTAssertEqual(path, expected)
    }

    // MARK: - Concurrency / locking

    func testConcurrentReadsDoNotCrash() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore()

        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            _ = store.overrides
            _ = store.override(for: .toggleSidebar)
            _ = store.isManagedByFile(.newTerminal)
        }
        XCTAssertEqual(store.override(for: .toggleSidebar)?.key, "b")
    }

    func testConcurrentReadsAndReloadsAreSafe() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore()

        let group = DispatchGroup()
        let readerQueue = DispatchQueue(label: "reader", attributes: .concurrent)
        let writerQueue = DispatchQueue(label: "writer")

        for _ in 0..<300 {
            group.enter()
            readerQueue.async {
                _ = store.overrides
                _ = store.override(for: .toggleSidebar)
                group.leave()
            }
        }
        for i in 0..<20 {
            group.enter()
            writerQueue.async {
                let key = (i % 2 == 0) ? "b" : "z"
                try? self.writeSettings(["toggleSidebar": StoredShortcut(key: key, command: true)])
                store.reload(notify: false)
                group.leave()
            }
        }

        let waited = group.wait(timeout: .now() + 10)
        XCTAssertEqual(waited, .success)
    }

    func testConcurrentReadsViaTaskGroupSeeConsistentSnapshot() async throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore()

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let snapshot = store.overrides
                    // Either empty (race with reload) or contains the entry; must always be valid.
                    if let entry = snapshot[.toggleSidebar] {
                        return entry.key == "b"
                    }
                    return snapshot.isEmpty
                }
            }
            for await ok in group {
                XCTAssertTrue(ok)
            }
        }
    }

    // MARK: - File watcher

    func testFileWatcherFiresOnExternalModify() throws {
        let store = makeStore(startWatching: true)
        XCTAssertTrue(store.overrides.isEmpty)

        let expectation = expectation(description: "watcher fired on modify")
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(store.override(for: .toggleSidebar)?.key, "b")
    }

    func testFileWatcherFiresOnExternalDelete() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore(startWatching: true)
        XCTAssertEqual(store.override(for: .toggleSidebar)?.key, "b")

        let expectation = expectation(description: "watcher fired on delete")
        expectation.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try FileManager.default.removeItem(at: settingsFileURL)
        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testFileWatcherFiresOnRename() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore(startWatching: true)

        let expectation = expectation(description: "watcher fired on rename")
        expectation.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let renamed = settingsFileURL.deletingLastPathComponent().appendingPathComponent("renamed.json")
        try FileManager.default.moveItem(at: settingsFileURL, to: renamed)
        wait(for: [expectation], timeout: 5.0)
    }

    func testFileWatcherRecoversWhenFileIsRecreatedAfterDelete() throws {
        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        let store = makeStore(startWatching: true)

        try FileManager.default.removeItem(at: settingsFileURL)
        // Allow the watcher's delete event to fire and re-attach to the directory.
        let firstFlush = expectation(description: "post-delete reload")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { firstFlush.fulfill() }
        wait(for: [firstFlush], timeout: 2.0)

        let expectation = expectation(description: "watcher fired on recreate")
        expectation.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try writeSettings(["newTerminal": StoredShortcut(key: "t", command: true, option: true)])
        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(store.override(for: .newTerminal)?.option, true)
    }

    // MARK: - Content edge cases

    func testMultipleShortcutsWithSameBindingAreAllPersisted() throws {
        // The store does not enforce unique bindings; two actions can share keys.
        let same = StoredShortcut(key: "x", command: true)
        try writeSettings([
            "toggleSidebar": same,
            "newTerminal": same,
        ])
        let store = makeStore()
        XCTAssertEqual(store.override(for: .toggleSidebar), same)
        XCTAssertEqual(store.override(for: .newTerminal), same)
    }

    func testUnicodeShortcutKeyRoundtrips() throws {
        let unicode = StoredShortcut(key: "ñ", command: true, option: true)
        try writeSettings(["toggleSidebar": unicode])
        let store = makeStore()
        XCTAssertEqual(store.override(for: .toggleSidebar), unicode)
    }

    func testEmojiShortcutKeyRoundtrips() throws {
        let emoji = StoredShortcut(key: "🚀", command: true)
        try writeSettings(["toggleSidebar": emoji])
        let store = makeStore()
        XCTAssertEqual(store.override(for: .toggleSidebar), emoji)
    }

    func testVeryLongShortcutKeyRoundtrips() throws {
        let longKey = String(repeating: "a", count: 10_000)
        let shortcut = StoredShortcut(key: longKey, command: true)
        try writeSettings(["toggleSidebar": shortcut])
        let store = makeStore()
        XCTAssertEqual(store.override(for: .toggleSidebar)?.key.count, 10_000)
    }

    func testEmptyShortcutsObjectYieldsEmptyOverrides() throws {
        try writeRaw("{\"shortcuts\":{}}", to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testEmptyBindingsObjectYieldsEmptyOverrides() throws {
        try writeRaw("{\"shortcuts\":{\"bindings\":{}}}", to: settingsFileURL)
        let store = makeStore()
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testManyShortcutsAreAllLoadedWithin100Bound() throws {
        // ShortcutAction has a fixed set; "many" exercises the load loop with
        // unknown actions which should be ignored. We add 100 unknown plus all valid actions.
        var dict: [String: StoredShortcut] = [:]
        for action in ShortcutAction.allCases where !action.isNumbered {
            dict[action.rawValue] = StoredShortcut(key: "a", command: true)
        }
        for i in 0..<100 {
            dict["unknown_action_\(i)"] = StoredShortcut(key: "z", command: true)
        }
        try writeSettings(dict)
        let store = makeStore()
        let validNonNumbered = ShortcutAction.allCases.filter { !$0.isNumbered }.count
        XCTAssertEqual(store.overrides.count, validNonNumbered)
    }

    func testManyShortcutsAreAllLoadedWithin1000Bound() throws {
        var dict: [String: StoredShortcut] = [:]
        for action in ShortcutAction.allCases where !action.isNumbered {
            dict[action.rawValue] = StoredShortcut(key: "a", command: true)
        }
        for i in 0..<1000 {
            dict["unknown_\(i)"] = StoredShortcut(key: "z", command: true)
        }
        try writeSettings(dict)
        let store = makeStore()
        let validNonNumbered = ShortcutAction.allCases.filter { !$0.isNumbered }.count
        XCTAssertEqual(store.overrides.count, validNonNumbered)
        XCTAssertNotNil(store.override(for: .toggleSidebar))
    }

    // MARK: - Watcher startup variants

    func testStartWatchingFalseDoesNotFireOnExternalModify() throws {
        let store = makeStore(startWatching: false)

        let expectation = expectation(description: "no watcher fired")
        expectation.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try writeSettings(["toggleSidebar": StoredShortcut(key: "b", command: true)])
        wait(for: [expectation], timeout: 1.0)
        // The store still reflects the in-memory snapshot from init time.
        XCTAssertTrue(store.overrides.isEmpty)
    }

    // MARK: - Read-only directory

    func testReadOnlyDirectoryDoesNotCrashInit() throws {
        let lockedDir = temporaryDirectory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        // Set directory perms to 0o500 (read+exec only) so `createDirectory` for nested
        // children would fail. Init still must not throw.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        }

        let nested = lockedDir
            .appendingPathComponent("child", isDirectory: true)
            .appendingPathComponent("settings.json")
        let store = makeStore(url: nested)
        XCTAssertTrue(store.overrides.isEmpty)
    }
}
