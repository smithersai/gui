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
        isTerminalFocused: Bool
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

        if !isTerminalFocused, modifiers.isEmpty, key == "g" {
            pendingPrefix = .linearG
            pendingSince = now
            return .consumed
        }

        if !isTerminalFocused, modifiers == [.control], key == "b" {
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
struct KeyboardShortcutFocusState {
    var textInputFocused: Bool
    var terminalFocused: Bool
    var paletteVisible: Bool
}

@MainActor
final class KeyboardShortcutController {
    private var monitor: Any?
    private var parser = KeyboardChordParser()

    func install(
        onAction: @escaping (CommandPaletteAction) -> Void,
        focusState: @escaping () -> KeyboardShortcutFocusState,
        shouldHandleCommandW: @escaping () -> Bool
    ) {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let state = focusState()
            if state.paletteVisible {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let shiftedKey = event.characters?.lowercased() ?? key

            if Self.isCommandW(key: key, flags: flags) {
                if state.terminalFocused || !shouldHandleCommandW() {
                    return event
                }
                onAction(.closeCurrentTab)
                return nil
            }

            let outcome = parser.handle(
                key: key,
                shiftedKey: shiftedKey,
                modifiers: KeyboardChordModifiers(flags),
                isTextInputFocused: state.textInputFocused,
                isTerminalFocused: state.terminalFocused
            )

            switch outcome {
            case .ignored:
                return event
            case .consumed:
                return nil
            case .action(let action):
                onAction(action)
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

    private static func isCommandW(key: String, flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) &&
            !flags.contains(.shift) &&
            !flags.contains(.control) &&
            !flags.contains(.option) &&
            key == "w"
    }
}
#endif
