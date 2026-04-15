import SwiftUI
import AppKit
import QuartzCore
import GhosttyKit

private struct SendableGhosttyAppRef: @unchecked Sendable {
    let value: ghostty_app_t
}

private enum TerminalClipboard {
    private static let selectionPasteboard = NSPasteboard(name: .init("com.smithers.terminal.selection"))
    private static let plainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func readString(from pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string) {
            return string
        }

        if let string = pasteboard.string(forType: plainTextType) {
            return string
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? $0.path : $0.absoluteString }
                .joined(separator: " ")
        }

        return nil
    }

    static func readString(for location: ghostty_clipboard_e) -> String? {
        guard let pasteboard = pasteboard(for: location) else { return nil }
        if let string = readString(from: pasteboard) {
            return string
        }

        if location == GHOSTTY_CLIPBOARD_SELECTION {
            return readString(from: .general)
        }

        return nil
    }

    static func pasteboardType(for mime: String) -> NSPasteboard.PasteboardType {
        if mime.hasPrefix("text/plain") {
            return .string
        }

        if mime.hasPrefix("text/html") {
            return .html
        }

        return NSPasteboard.PasteboardType(mime)
    }

    static func write(
        _ content: UnsafePointer<ghostty_clipboard_content_s>,
        count: Int,
        to pasteboard: NSPasteboard
    ) {
        var entries: [(type: NSPasteboard.PasteboardType, string: String)] = []
        var types: [NSPasteboard.PasteboardType] = []

        for index in 0..<count {
            let item = content[index]
            guard let mimePtr = item.mime,
                  let dataPtr = item.data else { continue }

            let type = pasteboardType(for: String(cString: mimePtr))
            let string = String(cString: dataPtr)

            entries.append((type, string))
            if !types.contains(type) {
                types.append(type)
            }
        }

        guard !entries.isEmpty else { return }
        pasteboard.declareTypes(types, owner: nil)
        for entry in entries {
            pasteboard.setString(entry.string, forType: entry.type)
        }
    }
}

enum TerminalKeyForwardingPolicy {
    static func shouldForwardKeyEvent(_ type: NSEvent.EventType, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .keyDown, .keyUp:
            return !modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        case .flagsChanged:
            return true
        default:
            return false
        }
    }

    static func controlEquivalentCharacters(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control),
              !flags.contains(.command),
              !flags.contains(.option) else {
            return nil
        }

        switch charactersIgnoringModifiers {
        case "\r":
            return "\r"
        case "/":
            guard !flags.contains(.shift) else { return nil }
            return "_"
        default:
            return nil
        }
    }
}

// MARK: - Ghostty Terminal App (singleton)

@MainActor
class GhosttyApp: ObservableObject {
    @Published var app: ghostty_app_t?
    @Published var ready = false

    private var config: ghostty_config_t?
    private var tickTimer: Timer?

    static let shared = GhosttyApp()

    private init() {
        if UITestSupport.isEnabled {
            ready = true
            return
        }
        if UITestSupport.isRunningUnitTests {
            return
        }

        // Initialize ghostty runtime
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("ghostty_init failed")
            return
        }

        // Create config
        guard let cfg = ghostty_config_new() else {
            NSLog("ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        self.config = cfg

        // Create runtime callbacks
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { app.appTick() }
        }
        runtime.action_cb = { app, target, action in
            return false
        }
        runtime.read_clipboard_cb = { userdata, loc, state in
            guard let userdata else { return false }
            let surfaceView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let str = TerminalClipboard.readString(for: loc) else { return false }
            return surfaceView.completeClipboardRequest(data: str, state: state, confirmed: false)
        }
        runtime.confirm_read_clipboard_cb = { userdata, str, state, request in
            guard let userdata else { return }
            let surfaceView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            let value = str.map { String(cString: $0) } ?? ""
            surfaceView.completeClipboardRequest(data: value, state: state, confirmed: true)
        }
        runtime.write_clipboard_cb = { userdata, loc, content, len, confirm in
            guard let content, len > 0 else { return }
            guard let pasteboard = TerminalClipboard.pasteboard(for: loc) else { return }

            TerminalClipboard.write(content, count: len, to: pasteboard)
            if loc == GHOSTTY_CLIPBOARD_SELECTION {
                TerminalClipboard.write(content, count: len, to: .general)
            }
        }
        runtime.close_surface_cb = { userdata, processAlive in
            // Surface closed — we could remove the tab
        }

        // Create the app
        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("ghostty_app_new failed")
            return
        }
        self.app = app
        self.ready = true

        // Start tick timer for event processing
        let appRef = SendableGhosttyAppRef(value: app)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { _ in
            ghostty_app_tick(appRef.value)
        }
    }

    func appTick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    deinit {
        tickTimer?.invalidate()
        // Singleton — never deallocated in practice
    }
}

// MARK: - Terminal Surface NSView

class TerminalSurfaceView: NSView {
    var surface: ghostty_surface_t?
    private var trackingArea: NSTrackingArea?
    private var keyEventMonitor: Any?
    private var forwardedKeyDownKeyCodes = Set<UInt16>()

    // Keep C strings alive for the lifetime of the surface
    private var commandCString: UnsafeMutablePointer<CChar>?
    private var workingDirCString: UnsafeMutablePointer<CChar>?

    private enum ClipboardShortcut {
        case copy
        case paste
    }

    init(app: ghostty_app_t, command: String? = nil, workingDirectory: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true

        // Use the factory function for default config, then customize
        var surfaceCfg = ghostty_surface_config_new()
        surfaceCfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfaceCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceCfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        surfaceCfg.scale_factor = Double(effectiveBackingScale)
        surfaceCfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        if let command {
            commandCString = strdup(command)
            surfaceCfg.command = UnsafePointer(commandCString!)
        }
        if let workingDirectory {
            workingDirCString = strdup(workingDirectory)
            surfaceCfg.working_directory = UnsafePointer(workingDirCString!)
        }

        guard let s = ghostty_surface_new(app, &surfaceCfg) else {
            NSLog("ghostty_surface_new failed")
            return
        }
        self.surface = s
        syncSurfaceBackingMetrics(sendSize: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeKeyEventMonitor()
        if let surface { ghostty_surface_free(surface) }
        free(commandCString)
        free(workingDirCString)
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard canReceiveTerminalKeyEvents else {
            return super.performKeyEquivalent(with: event)
        }

        if handleClipboardShortcut(event) {
            return true
        }

        guard TerminalKeyForwardingPolicy.shouldForwardKeyEvent(
            event.type,
            modifierFlags: event.modifierFlags
        ) else {
            return super.performKeyEquivalent(with: event)
        }

        return forwardKeyDown(with: terminalKeyEvent(for: event))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSurfaceBackingMetrics()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSurfaceBackingMetrics()
        updateKeyEventMonitor()
        requestKeyboardFocus()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceBackingMetrics()
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        if !forwardKeyDown(with: terminalKeyEvent(for: event)) {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if !forwardKeyUp(with: event) {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if !forwardFlagsChanged(with: event) {
            super.flagsChanged(with: event)
        }
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, mouseButton(from: event.buttonNumber), modsFromEvent(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, mouseButton(from: event.buttonNumber), modsFromEvent(event))
    }

    override func mouseEntered(with event: NSEvent) { sendMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        if NSEvent.pressedMouseButtons == 0 {
            sendMousePos(x: -1, y: -1, mods: modsFromEvent(event))
        }
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            scrollModsFromEvent(event)
        )
    }

    // MARK: - Clipboard

    @IBAction func copy(_ sender: Any?) {
        if performGhosttyAction("copy_to_clipboard") {
            return
        }

        copySelection(to: .general)
    }

    @IBAction func paste(_ sender: Any?) {
        if performGhosttyAction("paste_from_clipboard") {
            return
        }

        pasteDirectly(from: .general)
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    @IBAction func pasteSelection(_ sender: Any?) {
        if performGhosttyAction("paste_from_selection") {
            return
        }

        if let pasteboard = TerminalClipboard.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION) {
            pasteDirectly(from: pasteboard)
        }
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        let textTypes: [NSPasteboard.PasteboardType] = [
            .string,
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
        ]

        if let sendType, !textTypes.contains(sendType) {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        if let returnType, !textTypes.contains(returnType) {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        if sendType != nil {
            guard let surface, ghostty_surface_has_selection(surface) else {
                return super.validRequestor(forSendType: sendType, returnType: returnType)
            }
        }

        return self
    }

    func writeSelection(
        to pasteboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        copySelection(to: pasteboard)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        pasteDirectly(from: pasteboard)
    }

    // MARK: - Helpers

    private var effectiveBackingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func syncSurfaceBackingMetrics(sendSize: Bool = true) {
        updateLayerContentsScale()
        guard let surface else { return }

        let pointBounds = bounds
        let scale = effectiveBackingScale
        let backingBounds: NSRect
        if window != nil {
            backingBounds = convertToBacking(pointBounds)
        } else {
            backingBounds = NSRect(
                x: 0,
                y: 0,
                width: pointBounds.width * scale,
                height: pointBounds.height * scale
            )
        }

        let xScale = pointBounds.width > 0 ? backingBounds.width / pointBounds.width : scale
        let yScale = pointBounds.height > 0 ? backingBounds.height / pointBounds.height : scale
        ghostty_surface_set_content_scale(surface, Double(xScale), Double(yScale))

        guard sendSize else { return }
        ghostty_surface_set_size(
            surface,
            UInt32(max(0, backingBounds.width.rounded(.toNearestOrAwayFromZero))),
            UInt32(max(0, backingBounds.height.rounded(.toNearestOrAwayFromZero)))
        )
    }

    private func updateLayerContentsScale() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = effectiveBackingScale
        CATransaction.commit()
    }

    private var canReceiveTerminalKeyEvents: Bool {
        guard surface != nil, let window else { return false }
        return window.firstResponder === self
    }

    private func requestKeyboardFocus() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    private func updateKeyEventMonitor() {
        if window == nil {
            removeKeyEventMonitor()
            return
        }

        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredKeyEvent(event)
        }
    }

    private func removeKeyEventMonitor() {
        guard let keyEventMonitor else { return }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    private func handleMonitoredKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard canReceiveTerminalKeyEvents,
              isEventFromCurrentWindow(event) else {
            return event
        }

        switch event.type {
        case .keyDown:
            if handleClipboardShortcut(event) {
                return nil
            }

            guard TerminalKeyForwardingPolicy.shouldForwardKeyEvent(
                event.type,
                modifierFlags: event.modifierFlags
            ) else {
                return event
            }

            _ = forwardKeyDown(with: terminalKeyEvent(for: event))
            return nil

        case .keyUp:
            guard TerminalKeyForwardingPolicy.shouldForwardKeyEvent(
                event.type,
                modifierFlags: event.modifierFlags
            ) else {
                return event
            }

            _ = forwardKeyUp(with: event)
            return nil

        case .flagsChanged:
            return forwardFlagsChanged(with: event) ? nil : event

        default:
            return event
        }
    }

    private func isEventFromCurrentWindow(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        if let eventWindow = event.window {
            return eventWindow === window
        }

        return event.windowNumber == window.windowNumber
    }

    @discardableResult
    private func forwardKeyDown(with event: NSEvent) -> Bool {
        guard let surface else { return false }
        if handleClipboardShortcut(event) { return true }

        let translationFlags = translatedModifierFlags(for: event, surface: surface)
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        forwardedKeyDownKeyCodes.insert(event.keyCode)
        _ = sendKey(
            action,
            event: event,
            translationFlags: translationFlags,
            text: ghosttyCharacters(for: event, translationFlags: translationFlags)
        )
        return true
    }

    @discardableResult
    private func forwardKeyUp(with event: NSEvent) -> Bool {
        guard surface != nil else { return false }
        guard forwardedKeyDownKeyCodes.remove(event.keyCode) != nil else { return false }
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
        return true
    }

    @discardableResult
    private func forwardFlagsChanged(with event: NSEvent) -> Bool {
        guard surface != nil else { return false }

        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return false
        }

        var action: ghostty_input_action_e = GHOSTTY_ACTION_RELEASE
        let mods = modsFromEvent(event)
        if mods.rawValue & mod != 0, modifierSideIsPressed(event) {
            action = GHOSTTY_ACTION_PRESS
        }

        _ = sendKey(action, event: event)
        return true
    }

    private func terminalKeyEvent(for event: NSEvent) -> NSEvent {
        guard event.type == .keyDown,
              let equivalent = TerminalKeyForwardingPolicy.controlEquivalentCharacters(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags
              ) else {
            return event
        }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func translatedModifierFlags(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent.ModifierFlags {
        let translated = modifierFlags(from: ghostty_surface_key_translation_mods(surface, modsFromEvent(event)))
        var flags = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) {
                flags.insert(flag)
            } else {
                flags.remove(flag)
            }
        }
        return flags
    }

    @discardableResult
    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationFlags: NSEvent.ModifierFlags? = nil,
        text: String? = nil
    ) -> Bool {
        guard let surface else { return false }

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = modsFromEvent(event)
        key.consumed_mods = modsFromFlags((translationFlags ?? event.modifierFlags).subtracting([.control, .command]))
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.unshifted_codepoint = unshiftedCodepoint(for: event)
        key.composing = false

        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }

        return ghostty_surface_key(surface, key)
    }

    private func ghosttyCharacters(for event: NSEvent, translationFlags: NSEvent.ModifierFlags) -> String? {
        let characters = event.characters(byApplyingModifiers: translationFlags) ?? event.characters
        guard let characters, !characters.isEmpty else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: translationFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }

    private func unshiftedCodepoint(for event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first
        else { return 0 }
        return scalar.value
    }

    @discardableResult
    func completeClipboardRequest(
        data: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) -> Bool {
        guard let surface, let state else { return false }
        data.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
        return true
    }

    @discardableResult
    private func performGhosttyAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.lengthOfBytes(using: .utf8)))
        }
    }

    @discardableResult
    private func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard let surface else { return false }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let textPtr = text.text else { return false }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(String(cString: textPtr), forType: .string)
        return true
    }

    @discardableResult
    private func pasteDirectly(from pasteboard: NSPasteboard) -> Bool {
        guard let string = TerminalClipboard.readString(from: pasteboard) else { return false }
        return sendText(string)
    }

    @discardableResult
    private func sendText(_ string: String) -> Bool {
        guard let surface else { return false }

        let byteCount = string.lengthOfBytes(using: .utf8)
        guard byteCount > 0 else { return true }

        string.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(byteCount))
        }
        return true
    }

    private func handleClipboardShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = clipboardShortcut(for: event) else { return false }

        switch shortcut {
        case .copy:
            copy(nil)
        case .paste:
            paste(nil)
        }

        return true
    }

    private func clipboardShortcut(for event: NSEvent) -> ClipboardShortcut? {
        guard event.type == .keyDown else { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else {
            return nil
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            return .copy
        case "v":
            return .paste
        default:
            return nil
        }
    }

    private func sendMousePos(_ event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        sendMousePos(
            x: Double(pt.x),
            y: Double(bounds.height - pt.y),
            mods: modsFromEvent(event)
        )
    }

    private func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(
            surface,
            x,
            y,
            mods
        )
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        modsFromFlags(event.modifierFlags)
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }

        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(rawValue: raw)
    }

    private func modifierFlags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 { flags.insert(.capsLock) }
        return flags
    }

    private func modifierSideIsPressed(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x38:
            return event.modifierFlags.rawValue & UInt(NX_DEVICELSHIFTKEYMASK) != 0
        case 0x3C:
            return event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 0x3B:
            return event.modifierFlags.rawValue & UInt(NX_DEVICELCTLKEYMASK) != 0
        case 0x3E:
            return event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 0x3A:
            return event.modifierFlags.rawValue & UInt(NX_DEVICELALTKEYMASK) != 0
        case 0x3D:
            return event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        case 0x37:
            return event.modifierFlags.rawValue & UInt(NX_DEVICELCMDKEYMASK) != 0
        case 0x36:
            return event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
        default:
            return true
        }
    }

    private func mouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT
        case 4: return GHOSTTY_MOUSE_NINE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_FOUR
        case 8: return GHOSTTY_MOUSE_FIVE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    private func scrollModsFromEvent(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        var raw: Int32 = event.hasPreciseScrollingDeltas ? 0b0000_0001 : 0
        raw |= Int32(scrollMomentumRawValue(event.momentumPhase)) << 1
        return raw
    }

    private func scrollMomentumRawValue(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: return 1
        case .stationary: return 2
        case .changed: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .mayBegin: return 6
        default: return 0
        }
    }
}

// MARK: - SwiftUI Wrapper

struct TerminalSurfaceRepresentable: NSViewRepresentable {
    let app: ghostty_app_t
    var command: String? = nil
    var workingDirectory: String? = nil

    func makeNSView(context: Context) -> TerminalSurfaceView {
        let view = TerminalSurfaceView(app: app, command: command, workingDirectory: workingDirectory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard view.window != nil else { return }
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalSurfaceView, context: Context) {}
}

// MARK: - Terminal Tab View

struct TerminalView: View {
    @ObservedObject private var ghostty = GhosttyApp.shared
    var command: String? = nil
    var workingDirectory: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            if UITestSupport.isEnabled {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.textTertiary)
                    Text("Terminal ready")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.base)
                .accessibilityIdentifier("terminal.placeholder")
            } else if let app = ghostty.app {
                TerminalSurfaceRepresentable(app: app, command: command, workingDirectory: workingDirectory)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.textTertiary)
                    Text("Terminal failed to initialize")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.base)
            }
        }
        .background(Theme.base)
        .accessibilityIdentifier("terminal.root")
    }
}
