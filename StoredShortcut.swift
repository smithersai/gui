import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ShortcutStroke: Codable, Equatable, Hashable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var keyCode: UInt16?

    init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false,
        keyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case command
        case shift
        case option
        case control
        case keyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            command: try container.decodeIfPresent(Bool.self, forKey: .command) ?? false,
            shift: try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false,
            option: try container.decodeIfPresent(Bool.self, forKey: .option) ?? false,
            control: try container.decodeIfPresent(Bool.self, forKey: .control) ?? false,
            keyCode: try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        )
    }

    var displayString: String {
        modifierDisplayString + keyDisplayString
    }

    var modifierDisplayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }

    var keyDisplayString: String {
        switch key {
        case "\t":
            return "Tab"
        case "\r":
            return "↩"
        case " ":
            return "Space"
        case "←", "→", "↑", "↓":
            return key
        default:
            return key.uppercased()
        }
    }

    var hasPrimaryModifier: Bool {
        command || option || control
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "←":
            return .leftArrow
        case "→":
            return .rightArrow
        case "↑":
            return .upArrow
        case "↓":
            return .downArrow
        case "\t":
            return .tab
        case "\r":
            return KeyEquivalent(Character("\r"))
        default:
            guard key.count == 1, let character = key.lowercased().first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

#if os(macOS)
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    static func normalizedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
    }

    static func isEscapeEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            return true
        }
        let escape = UnicodeScalar(0x1B)!
        return event.characters?.unicodeScalars.contains(escape) == true ||
            event.charactersIgnoringModifiers?.unicodeScalars.contains(escape) == true
    }

    static func from(event: NSEvent, requireModifier: Bool = true) -> ShortcutStroke? {
        guard !isEscapeEvent(event),
              let key = storedKey(from: event)
        else {
            return nil
        }

        let flags = normalizedModifierFlags(from: event.modifierFlags)
        let stroke = ShortcutStroke(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            keyCode: event.keyCode
        )
        if requireModifier && !stroke.command && !stroke.shift && !stroke.option && !stroke.control {
            return nil
        }
        return stroke
    }

    func matches(event: NSEvent) -> Bool {
        let flags = Self.normalizedModifierFlags(from: event.modifierFlags)
        guard flags == modifierFlags else { return false }

        switch key {
        case "←":
            return event.keyCode == 123
        case "→":
            return event.keyCode == 124
        case "↓":
            return event.keyCode == 125
        case "↑":
            return event.keyCode == 126
        case "\t":
            return event.keyCode == 48
        case "\r":
            return event.keyCode == 36 || event.keyCode == 76
        default:
            let normalized = Self.normalizedCharacter(
                event.charactersIgnoringModifiers,
                shiftedCharacter: event.characters,
                keyCode: event.keyCode,
                shift: flags.contains(.shift)
            )
            return normalized == key.lowercased()
        }
    }

    private static func storedKey(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76:
            return "\r"
        case 48:
            return "\t"
        case 123:
            return "←"
        case 124:
            return "→"
        case 125:
            return "↓"
        case 126:
            return "↑"
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased(),
                  let first = character.first else {
                return nil
            }
            return String(first)
        }
    }

    private static func normalizedCharacter(
        _ character: String?,
        shiftedCharacter: String?,
        keyCode: UInt16,
        shift: Bool
    ) -> String? {
        if let character, !character.isEmpty {
            return String(character.prefix(1)).lowercased()
        }
        guard shift, let shiftedCharacter, !shiftedCharacter.isEmpty else { return nil }
        return normalizedShiftedCharacter(
            String(shiftedCharacter.prefix(1)).lowercased(),
            keyCode: keyCode
        )
    }

    private static func normalizedShiftedCharacter(_ value: String, keyCode: UInt16) -> String {
        switch value {
        case "{": return "["
        case "}": return "]"
        case "<": return keyCode == 43 ? "," : value
        case ">": return keyCode == 47 ? "." : value
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "+": return "="
        case "_": return "-"
        case "!": return keyCode == 18 ? "1" : value
        case "@": return keyCode == 19 ? "2" : value
        case "#": return keyCode == 20 ? "3" : value
        case "$": return keyCode == 21 ? "4" : value
        case "%": return keyCode == 23 ? "5" : value
        case "^": return keyCode == 22 ? "6" : value
        case "&": return keyCode == 26 ? "7" : value
        case "*": return keyCode == 28 ? "8" : value
        case "(": return keyCode == 25 ? "9" : value
        case ")": return keyCode == 29 ? "0" : value
        default: return value
        }
    }
#endif
}

struct StoredShortcut: Codable, Equatable, Hashable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var keyCode: UInt16?
    var chordKey: String?
    var chordCommand: Bool
    var chordShift: Bool
    var chordOption: Bool
    var chordControl: Bool
    var chordKeyCode: UInt16?

    init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false,
        keyCode: UInt16? = nil,
        chordKey: String? = nil,
        chordCommand: Bool = false,
        chordShift: Bool = false,
        chordOption: Bool = false,
        chordControl: Bool = false,
        chordKeyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
        self.chordKey = chordKey?.isEmpty == true ? nil : chordKey
        self.chordCommand = chordCommand
        self.chordShift = chordShift
        self.chordOption = chordOption
        self.chordControl = chordControl
        self.chordKeyCode = chordKeyCode
    }

    init(first: ShortcutStroke, second: ShortcutStroke? = nil) {
        self.init(
            key: first.key,
            command: first.command,
            shift: first.shift,
            option: first.option,
            control: first.control,
            keyCode: first.keyCode,
            chordKey: second?.key,
            chordCommand: second?.command ?? false,
            chordShift: second?.shift ?? false,
            chordOption: second?.option ?? false,
            chordControl: second?.control ?? false,
            chordKeyCode: second?.keyCode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case command
        case shift
        case option
        case control
        case keyCode
        case chordKey
        case chordCommand
        case chordShift
        case chordOption
        case chordControl
        case chordKeyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            command: try container.decodeIfPresent(Bool.self, forKey: .command) ?? false,
            shift: try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false,
            option: try container.decodeIfPresent(Bool.self, forKey: .option) ?? false,
            control: try container.decodeIfPresent(Bool.self, forKey: .control) ?? false,
            keyCode: try container.decodeIfPresent(UInt16.self, forKey: .keyCode),
            chordKey: try container.decodeIfPresent(String.self, forKey: .chordKey),
            chordCommand: try container.decodeIfPresent(Bool.self, forKey: .chordCommand) ?? false,
            chordShift: try container.decodeIfPresent(Bool.self, forKey: .chordShift) ?? false,
            chordOption: try container.decodeIfPresent(Bool.self, forKey: .chordOption) ?? false,
            chordControl: try container.decodeIfPresent(Bool.self, forKey: .chordControl) ?? false,
            chordKeyCode: try container.decodeIfPresent(UInt16.self, forKey: .chordKeyCode)
        )
    }

    var firstStroke: ShortcutStroke {
        ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: keyCode
        )
    }

    var secondStroke: ShortcutStroke? {
        guard let chordKey else { return nil }
        return ShortcutStroke(
            key: chordKey,
            command: chordCommand,
            shift: chordShift,
            option: chordOption,
            control: chordControl,
            keyCode: chordKeyCode
        )
    }

    var hasChord: Bool {
        secondStroke != nil
    }

    var displayString: String {
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.displayString)"
        }
        return firstStroke.displayString
    }

    var numberedDisplayString: String {
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.modifierDisplayString)1…9"
        }
        return "\(firstStroke.modifierDisplayString)1…9"
    }

    var keyEquivalent: KeyEquivalent? {
        guard !hasChord else { return nil }
        return firstStroke.keyEquivalent
    }

    var eventModifiers: EventModifiers {
        firstStroke.eventModifiers
    }

#if os(macOS)
    static func from(event: NSEvent) -> StoredShortcut? {
        guard let stroke = ShortcutStroke.from(event: event) else { return nil }
        return StoredShortcut(first: stroke)
    }

    func matches(event: NSEvent) -> Bool {
        guard !hasChord else { return false }
        return firstStroke.matches(event: event)
    }
#endif
}

extension View {
    @ViewBuilder
    func appKeyboardShortcut(_ action: ShortcutAction) -> some View {
        let shortcut = KeyboardShortcutSettings.current(for: action)
        if let keyEquivalent = shortcut.keyEquivalent {
            keyboardShortcut(keyEquivalent, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }

    @ViewBuilder
    func appNumberedKeyboardShortcut(_ action: ShortcutAction, digit: Int) -> some View {
        let shortcut = KeyboardShortcutSettings.current(for: action)
        if !shortcut.hasChord, (1...9).contains(digit), let character = String(digit).first {
            keyboardShortcut(KeyEquivalent(character), modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}
