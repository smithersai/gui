#if os(macOS)
import AppKit
import SwiftUI

enum KeyboardShortcutRecorderActivity {
    static let didChangeNotification = Notification.Name("smithers.keyboardShortcutRecorderActivityDidChange")
    private static var activeRecorderCount = 0

    static var isAnyRecorderActive: Bool {
        activeRecorderCount > 0
    }

    static func beginRecording(center: NotificationCenter = .default) {
        let wasActive = isAnyRecorderActive
        activeRecorderCount += 1
        if wasActive != isAnyRecorderActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }

    static func endRecording(center: NotificationCenter = .default) {
        guard activeRecorderCount > 0 else { return }
        let wasActive = isAnyRecorderActive
        activeRecorderCount -= 1
        if wasActive != isAnyRecorderActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }
}

struct KeyboardShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut
    let displayString: (StoredShortcut) -> String
    let allowsModifierlessShortcut: Bool
    var isDisabled: Bool = false

    func makeNSView(context: Context) -> KeyboardShortcutRecorderButton {
        let button = KeyboardShortcutRecorderButton()
        button.shortcut = shortcut
        button.displayString = displayString
        button.allowsModifierlessShortcut = allowsModifierlessShortcut
        button.onShortcutRecorded = { shortcut in
            self.shortcut = shortcut
        }
        return button
    }

    func updateNSView(_ nsView: KeyboardShortcutRecorderButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.displayString = displayString
        nsView.allowsModifierlessShortcut = allowsModifierlessShortcut
        nsView.isEnabled = !isDisabled
        nsView.onShortcutRecorded = { shortcut in
            self.shortcut = shortcut
        }
        nsView.updateTitle()
    }
}

final class KeyboardShortcutRecorderButton: NSButton {
    var shortcut: StoredShortcut = StoredShortcut(key: "p", command: true)
    var displayString: (StoredShortcut) -> String = { $0.displayString }
    var allowsModifierlessShortcut = false
    var onShortcutRecorded: ((StoredShortcut) -> Void)?

    private var isRecording = false
    private var monitor: Any?
    private var registeredActivity = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func updateTitle() {
        title = isRecording
            ? String(localized: "shortcut.recorder.prompt", defaultValue: "Press shortcut…")
            : displayString(shortcut)
    }

    private func setup() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        updateTitle()
    }

    @objc private func clicked() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        registerActivityIfNeeded()
        updateTitle()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if ShortcutStroke.isEscapeEvent(event) {
                self.stopRecording()
                return nil
            }

            guard let stroke = ShortcutStroke.from(
                event: event,
                requireModifier: !self.allowsModifierlessShortcut
            ) else {
                NSSound.beep()
                return nil
            }

            let shortcut = StoredShortcut(first: stroke)
            self.shortcut = shortcut
            self.onShortcutRecorded?(shortcut)
            self.stopRecording()
            return nil
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        unregisterActivityIfNeeded()
        updateTitle()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
    }

    private func registerActivityIfNeeded() {
        guard !registeredActivity else { return }
        registeredActivity = true
        KeyboardShortcutRecorderActivity.beginRecording()
    }

    private func unregisterActivityIfNeeded() {
        guard registeredActivity else { return }
        registeredActivity = false
        KeyboardShortcutRecorderActivity.endRecording()
    }

    @objc private func windowResigned() {
        stopRecording()
    }

    deinit {
        stopRecording()
    }
}
#endif
