import XCTest
@testable import SmithersGUI

#if os(macOS)
import AppKit
#endif

final class KeyboardShortcutSettingsTests: XCTestCase {
    private var originalDefaults: UserDefaults!
    private var originalFileStore: KeyboardShortcutSettingsFileStore!
    private var isolatedDefaults: UserDefaults!
    private var isolatedDefaultsSuiteName: String!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDefaults = KeyboardShortcutSettings.userDefaults
        originalFileStore = KeyboardShortcutSettings.settingsFileStore

        let suiteName = "KeyboardShortcutSettingsTests.\(UUID().uuidString)"
        isolatedDefaultsSuiteName = suiteName
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardShortcutSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        KeyboardShortcutSettings.userDefaults = isolatedDefaults
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            settingsFileURL: temporaryDirectory.appendingPathComponent("settings.json"),
            startWatching: false
        )
    }

    override func tearDownWithError() throws {
        KeyboardShortcutSettings.userDefaults = originalDefaults
        KeyboardShortcutSettings.settingsFileStore = originalFileStore
        if let isolatedDefaults, let isolatedDefaultsSuiteName {
            isolatedDefaults.removePersistentDomain(forName: isolatedDefaultsSuiteName)
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testDefaultTableLoadsWithUniqueKeysAndLabels() {
        let keys = ShortcutAction.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)

        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(KeyboardShortcutSettings.current(for: action), action.defaultShortcut)
        }
    }

    func testUserDefaultsOverrideReplacesDefaultShortcut() throws {
        let override = StoredShortcut(key: "j", command: true, option: true)
        let data = try JSONEncoder().encode(override)
        isolatedDefaults.set(data, forKey: ShortcutAction.newChat.defaultsKey)

        XCTAssertEqual(KeyboardShortcutSettings.current(for: .newChat), override)
    }

    func testFileOverrideReplacesUserDefaultsOverride() throws {
        let persistedOverride = StoredShortcut(key: "j", command: true, option: true)
        isolatedDefaults.set(try JSONEncoder().encode(persistedOverride), forKey: ShortcutAction.newChat.defaultsKey)

        let managedOverride = StoredShortcut(key: "b", command: true)
        let settingsFileURL = temporaryDirectory.appendingPathComponent("settings.json")
        try writeSettingsFile(
            shortcuts: ["newChat": managedOverride],
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            settingsFileURL: settingsFileURL,
            startWatching: false
        )

        XCTAssertEqual(KeyboardShortcutSettings.current(for: .newChat), managedOverride)
        XCTAssertTrue(KeyboardShortcutSettings.isManagedBySettingsFile(.newChat))
    }

    func testFileChangePostsDidChangeNotification() throws {
        let settingsFileURL = temporaryDirectory.appendingPathComponent("watched-settings.json")
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            settingsFileURL: settingsFileURL,
            startWatching: true
        )

        let expectation = expectation(description: "shortcut settings changed")
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        try writeSettingsFile(
            shortcuts: ["toggleSidebar": StoredShortcut(key: "b", command: true, option: true)],
            to: settingsFileURL
        )

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(
            KeyboardShortcutSettings.current(for: .toggleSidebar),
            StoredShortcut(key: "b", command: true, option: true)
        )
    }

    private func writeSettingsFile(shortcuts: [String: StoredShortcut], to url: URL) throws {
        let encodedShortcuts = try shortcuts.mapValues { shortcut -> [String: Any] in
            let data = try JSONEncoder().encode(shortcut)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let payload: [String: Any] = ["shortcuts": encodedShortcuts]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

#if os(macOS)
final class KeyboardShortcutDispatcherTests: XCTestCase {
    func testDispatcherFiresDirectAction() throws {
        var dispatcher = KeyboardShortcutDispatcher { action in
            action == .toggleSidebar
                ? StoredShortcut(key: "b", command: true)
                : action.defaultShortcut
        }

        let outcome = dispatcher.dispatch(
            event: try keyEvent(characters: "b", keyCode: 11, modifiers: [.command]),
            focusState: KeyboardShortcutFocusState(textInputFocused: false, terminalFocused: false, paletteVisible: false)
        )

        XCTAssertEqual(outcome, .command(.shortcut(.toggleSidebar)))
    }

    func testDispatcherUsesConfiguredDispatchPriorityForSharedDefaults() throws {
        var dispatcher = KeyboardShortcutDispatcher { action in
            action.defaultShortcut
        }

        let outcome = dispatcher.dispatch(
            event: try keyEvent(characters: "D", keyCode: 2, modifiers: [.command, .shift]),
            focusState: KeyboardShortcutFocusState(textInputFocused: false, terminalFocused: false, paletteVisible: false)
        )

        XCTAssertEqual(outcome, .command(.shortcut(.splitDown)))
    }

    func testDispatcherFiresNumberedAction() throws {
        var dispatcher = KeyboardShortcutDispatcher { action in
            action.defaultShortcut
        }

        let outcome = dispatcher.dispatch(
            event: try keyEvent(characters: "7", keyCode: 26, modifiers: [.command]),
            focusState: KeyboardShortcutFocusState(textInputFocused: false, terminalFocused: false, paletteVisible: false)
        )

        XCTAssertEqual(outcome, .command(.numbered(.selectWorkspaceByNumber, 7)))
    }

    func testDispatcherFiresConfiguredTmuxChord() throws {
        var dispatcher = KeyboardShortcutDispatcher { action in
            action == .tmuxPrefix
                ? StoredShortcut(key: "x", control: true)
                : action.defaultShortcut
        }
        let focus = KeyboardShortcutFocusState(textInputFocused: false, terminalFocused: false, paletteVisible: false)

        XCTAssertEqual(
            dispatcher.dispatch(
                event: try keyEvent(characters: "x", keyCode: 7, modifiers: [.control]),
                focusState: focus
            ),
            .consumed
        )
        XCTAssertEqual(
            dispatcher.dispatch(
                event: try keyEvent(characters: "c", keyCode: 8, modifiers: []),
                focusState: focus
            ),
            .command(.palette(.newTerminal))
        )
    }

    func testDispatcherDoesNotFireInsideTextFieldOrTerminal() throws {
        var dispatcher = KeyboardShortcutDispatcher { action in
            action.defaultShortcut
        }
        let event = try keyEvent(characters: "n", keyCode: 45, modifiers: [.command])

        XCTAssertEqual(
            dispatcher.dispatch(
                event: event,
                focusState: KeyboardShortcutFocusState(textInputFocused: true, terminalFocused: false, paletteVisible: false)
            ),
            .ignored
        )
        XCTAssertEqual(
            dispatcher.dispatch(
                event: event,
                focusState: KeyboardShortcutFocusState(textInputFocused: false, terminalFocused: true, paletteVisible: false)
            ),
            .ignored
        )
    }

    private func keyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
#endif
