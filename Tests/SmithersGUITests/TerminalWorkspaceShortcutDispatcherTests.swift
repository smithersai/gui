import XCTest
import AppKit
@testable import SmithersGUI

#if os(macOS)
@MainActor
final class TerminalWorkspaceShortcutDispatcherTests: XCTestCase {
    func testDispatcherInvokesPaletteShortcutCallbacks() throws {
        let dispatcher = TerminalWorkspaceShortcutDispatcher { action in
            action.defaultShortcut
        }
        var commands: [KeyboardShortcutCommand] = []

        XCTAssertTrue(
            dispatcher.dispatch(
                event: try keyEvent(characters: "p", keyCode: 35, modifiers: [.command])
            ) { command in
                commands.append(command)
            }
        )
        XCTAssertTrue(
            dispatcher.dispatch(
                event: try keyEvent(characters: "P", keyCode: 35, modifiers: [.command, .shift])
            ) { command in
                commands.append(command)
            }
        )
        XCTAssertTrue(
            dispatcher.dispatch(
                event: try keyEvent(characters: "k", keyCode: 40, modifiers: [.command])
            ) { command in
                commands.append(command)
            }
        )

        XCTAssertEqual(
            commands,
            [
                .shortcut(.commandPalette),
                .shortcut(.commandPaletteCommandMode),
                .shortcut(.commandPaletteAskAI),
            ]
        )
    }

    func testDispatcherInvokesOtherAppGlobalShortcutCallbacks() throws {
        let dispatcher = TerminalWorkspaceShortcutDispatcher { action in
            action.defaultShortcut
        }
        var commands: [KeyboardShortcutCommand] = []

        XCTAssertTrue(
            dispatcher.dispatch(
                event: try keyEvent(characters: "b", keyCode: 11, modifiers: [.command])
            ) { command in
                commands.append(command)
            }
        )
        XCTAssertTrue(
            dispatcher.dispatch(
                event: try keyEvent(characters: "7", keyCode: 26, modifiers: [.command])
            ) { command in
                commands.append(command)
            }
        )

        XCTAssertEqual(
            commands,
            [
                .shortcut(.toggleSidebar),
                .numbered(.selectWorkspaceByNumber, 7),
            ]
        )
    }

    func testDispatcherDoesNotInterceptTerminalSpecificShortcut() throws {
        let dispatcher = TerminalWorkspaceShortcutDispatcher { action in
            action.defaultShortcut
        }

        XCTAssertFalse(
            dispatcher.dispatch(
                event: try keyEvent(characters: "d", keyCode: 2, modifiers: [.command])
            ) { _ in
                XCTFail("splitRight should continue through terminal-specific handling")
            }
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
