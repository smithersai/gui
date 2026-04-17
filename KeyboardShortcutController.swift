#if os(macOS)
import AppKit
#endif
import Foundation

struct KeyboardChordModifiers: OptionSet, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let shift = KeyboardChordModifiers(rawValue: 1 << 0)
    static let control = KeyboardChordModifiers(rawValue: 1 << 1)
    static let option = KeyboardChordModifiers(rawValue: 1 << 2)
    static let command = KeyboardChordModifiers(rawValue: 1 << 3)

#if os(macOS)
    init(_ flags: NSEvent.ModifierFlags) {
        var resolved: KeyboardChordModifiers = []
        if flags.contains(.shift) { resolved.insert(.shift) }
        if flags.contains(.control) { resolved.insert(.control) }
        if flags.contains(.option) { resolved.insert(.option) }
        if flags.contains(.command) { resolved.insert(.command) }
        self = resolved
    }
#endif
}

enum KeyboardChordOutcome: Equatable {
    case ignored
    case consumed
    case action(CommandPaletteAction)
}

enum KeyboardShortcutCommand: Equatable {
    case shortcut(ShortcutAction)
    case numbered(ShortcutAction, Int)
    case palette(CommandPaletteAction)
}

enum KeyboardShortcutDispatchOutcome: Equatable {
    case ignored
    case consumed
    case command(KeyboardShortcutCommand)
}

struct KeyboardChordParser {
    private enum PendingPrefix {
        case linearG
        case tmuxControlB
    }

    private var pendingPrefix: PendingPrefix?
    private var pendingSince: Date?
    var timeout: TimeInterval = 1.0

    mutating func handle(
        key: String,
        shiftedKey: String,
        modifiers: KeyboardChordModifiers,
        now: Date = Date(),
        isTextInputFocused: Bool,
        isTerminalFocused: Bool,
        shortcutProvider: (ShortcutAction) -> StoredShortcut = KeyboardShortcutSettings.current(for:)
    ) -> KeyboardChordOutcome {
        resetIfExpired(now: now)

        if let pendingPrefix {
            defer { clearPendingPrefix() }

            switch pendingPrefix {
            case .linearG:
                guard !isTextInputFocused, !isTerminalFocused, modifiers.isEmpty else {
                    return .ignored
                }
                switch key {
                case "h": return .action(.navigate(.dashboard))
                case "c": return .action(.navigate(.chat))
                case "t": return .action(.navigate(.terminal(id: "default")))
                case "r": return .action(.navigate(.runs))
                case "w": return .action(.navigate(.workflows))
                case "a": return .action(.navigate(.approvals))
                case "i": return .action(.navigate(.issues))
                case "s": return .action(.navigate(.search))
                case "l": return .action(.navigate(.logs))
                case "m": return .action(.navigate(.memory))
                default: return .ignored
                }

            case .tmuxControlB:
                guard !isTextInputFocused, !isTerminalFocused else {
                    return .ignored
                }

                if modifiers.isEmpty {
                    switch key {
                    case "c": return .action(.newTerminal)
                    case "n": return .action(.nextVisibleTab)
                    case "p": return .action(.previousVisibleTab)
                    case "w": return .action(.openTabSwitcher)
                    case "f": return .action(.findTab)
                    case ",": return .action(.unsupported("Rename tab is not available yet."))
                    case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                        return .action(.switchToTabIndex(Int(key) ?? 0))
                    default:
                        return .ignored
                    }
                }

                if modifiers == [.shift], shiftedKey == "&" {
                    return .action(.closeCurrentTab)
                }
                return .ignored
            }
        }

        guard !isTextInputFocused else { return .ignored }

        let stroke = ShortcutStroke(
            key: key,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )

        if !isTerminalFocused,
           shortcutProvider(.linearNavigationPrefix).firstStroke == stroke {
            pendingPrefix = .linearG
            pendingSince = now
            return .consumed
        }

        if !isTerminalFocused,
           shortcutProvider(.tmuxPrefix).firstStroke == stroke {
            pendingPrefix = .tmuxControlB
            pendingSince = now
            return .consumed
        }

        return .ignored
    }

    private mutating func resetIfExpired(now: Date) {
        guard let pendingSince else { return }
        if now.timeIntervalSince(pendingSince) > timeout {
            clearPendingPrefix()
        }
    }

    private mutating func clearPendingPrefix() {
        pendingPrefix = nil
        pendingSince = nil
    }
}

#if os(macOS)
struct KeyboardShortcutDispatcher {
    var shortcutProvider: (ShortcutAction) -> StoredShortcut = KeyboardShortcutSettings.current(for:)
    private var parser = KeyboardChordParser()

    init(shortcutProvider: @escaping (ShortcutAction) -> StoredShortcut = KeyboardShortcutSettings.current(for:)) {
        self.shortcutProvider = shortcutProvider
    }

    mutating func dispatch(
        event: NSEvent,
        focusState: KeyboardShortcutFocusState
    ) -> KeyboardShortcutDispatchOutcome {
        if focusState.paletteVisible {
            return .ignored
        }

        if focusState.textInputFocused || focusState.terminalFocused {
            return .ignored
        }

        if let direct = directCommand(for: event) {
            return .command(direct)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shiftedKey = event.characters?.lowercased() ?? key
        let outcome = parser.handle(
            key: key,
            shiftedKey: shiftedKey,
            modifiers: KeyboardChordModifiers(flags),
            isTextInputFocused: focusState.textInputFocused,
            isTerminalFocused: focusState.terminalFocused,
            shortcutProvider: shortcutProvider
        )

        switch outcome {
        case .ignored:
            return .ignored
        case .consumed:
            return .consumed
        case .action(let action):
            return .command(.palette(action))
        }
    }

    private func directCommand(for event: NSEvent) -> KeyboardShortcutCommand? {
        for action in ShortcutAction.dispatchOrder where !action.isPrefixOnly {
            let shortcut = shortcutProvider(action)
            if action.isNumbered {
                if let digit = numberedShortcutDigit(event: event, shortcut: shortcut) {
                    return .numbered(action, digit)
                }
                continue
            }
            if shortcut.matches(event: event) {
                return .shortcut(action)
            }
        }
        return nil
    }

    private func numberedShortcutDigit(event: NSEvent, shortcut: StoredShortcut) -> Int? {
        guard !shortcut.hasChord else { return nil }
        let stroke = shortcut.firstStroke
        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        guard flags == stroke.modifierFlags else { return nil }

        if let digit = digit(from: event.charactersIgnoringModifiers, keyCode: event.keyCode) {
            return digit
        }
        if flags.contains(.shift),
           let digit = digit(from: event.characters, keyCode: event.keyCode) {
            return digit
        }
        return digitForNumberKeyCode(event.keyCode)
    }

    private func digit(from characters: String?, keyCode: UInt16) -> Int? {
        guard let characters, !characters.isEmpty else { return nil }
        let normalized = normalizedDigitCharacter(String(characters.prefix(1)).lowercased(), keyCode: keyCode)
        guard let digit = Int(normalized), (1...9).contains(digit) else { return nil }
        return digit
    }

    private func normalizedDigitCharacter(_ value: String, keyCode: UInt16) -> String {
        switch value {
        case "!": return keyCode == 18 ? "1" : value
        case "@": return keyCode == 19 ? "2" : value
        case "#": return keyCode == 20 ? "3" : value
        case "$": return keyCode == 21 ? "4" : value
        case "%": return keyCode == 23 ? "5" : value
        case "^": return keyCode == 22 ? "6" : value
        case "&": return keyCode == 26 ? "7" : value
        case "*": return keyCode == 28 ? "8" : value
        case "(": return keyCode == 25 ? "9" : value
        default: return value
        }
    }

    private func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }
}

struct KeyboardShortcutFocusState {
    var textInputFocused: Bool
    var terminalFocused: Bool
    var paletteVisible: Bool
}

@MainActor
final class KeyboardShortcutController {
    private var monitor: Any?
    private var dispatcher = KeyboardShortcutDispatcher()

    func install(
        onCommand: @escaping (KeyboardShortcutCommand) -> Void,
        focusState: @escaping () -> KeyboardShortcutFocusState
    ) {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let state = focusState()
            if state.paletteVisible {
                return event
            }
            if KeyboardShortcutRecorderActivity.isAnyRecorderActive {
                return event
            }

            let outcome = dispatcher.dispatch(event: event, focusState: state)
            switch outcome {
            case .ignored:
                return event
            case .consumed:
                return nil
            case .command(let command):
                onCommand(command)
                return nil
            }
        }
    }

    func uninstall() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    static func isTextInputFocused(window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is TerminalSurfaceView {
            return false
        }
        if let textView = responder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }
        if responder is NSTextField || responder is NSSearchField || responder is NSSecureTextField {
            return true
        }
        return false
    }

    static func isTerminalFocused(window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else {
            return TerminalSurfaceRegistry.shared.focusedSessionId != nil
        }
        return responder is TerminalSurfaceView
    }

}
#endif
