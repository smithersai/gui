import SwiftUI
import AppKit
import QuartzCore
import GhosttyKit

private struct SendableGhosttyAppRef: @unchecked Sendable {
    let value: ghostty_app_t
}

private struct SendableRawPointer: @unchecked Sendable {
    let value: UnsafeMutableRawPointer?
}

private struct SendableClipboardLocation: @unchecked Sendable {
    let value: ghostty_clipboard_e
}

private struct SendableClipboardRequest: @unchecked Sendable {
    let value: ghostty_clipboard_request_e
}

private enum TerminalClipboard {
    fileprivate struct Item: Sendable {
        let mime: String
        let data: String
    }

    private static let selectionPasteboard = NSPasteboard(name: .init("com.smithers.terminal.selection"))
    private static let plainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")

    fileprivate static func isSelectionClipboard(_ location: ghostty_clipboard_e) -> Bool {
        if location == GHOSTTY_CLIPBOARD_SELECTION {
            return true
        }
        return location.rawValue == 2
    }

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        if isSelectionClipboard(location) {
            return selectionPasteboard
        }

        if location == GHOSTTY_CLIPBOARD_STANDARD {
            return .general
        }

        return nil
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

        if isSelectionClipboard(location) {
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

    static func items(
        _ content: UnsafePointer<ghostty_clipboard_content_s>,
        count: Int
    ) -> [Item] {
        (0..<count).compactMap { index in
            let item = content[index]
            guard let mimePtr = item.mime,
                  let dataPtr = item.data else { return nil }

            return Item(
                mime: String(cString: mimePtr),
                data: String(cString: dataPtr)
            )
        }
    }

    static func write(_ items: [Item], to pasteboard: NSPasteboard) {
        var entries: [(type: NSPasteboard.PasteboardType, string: String)] = []
        var types: [NSPasteboard.PasteboardType] = []

        for item in items {
            let type = pasteboardType(for: item.mime)
            entries.append((type, item.data))
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

private enum TerminalClipboardConfirmation {
    static func requestApproval(
        for request: ghostty_clipboard_request_e,
        preview: String,
        window _: NSWindow?
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow terminal clipboard access?"
        alert.informativeText = "\(description(for: request))\n\n\(previewText(preview))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        return alert.runModal() == .alertFirstButtonReturn
    }

    static func requestApprovalForWrite(
        items: [TerminalClipboard.Item],
        window: NSWindow?
    ) -> Bool {
        let preview = items.first(where: { $0.mime.hasPrefix("text/plain") })?.data
            ?? items.first?.data
            ?? ""
        return requestApproval(
            for: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
            preview: preview,
            window: window
        )
    }

    private static func description(for request: ghostty_clipboard_request_e) -> String {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            return "A terminal process wants to paste clipboard contents into the terminal."
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            return "A terminal process wants to read the clipboard using OSC 52."
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            return "A terminal process wants to write to the clipboard using OSC 52."
        default:
            return "A terminal process is requesting clipboard access."
        }
    }

    private static func previewText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Clipboard preview is empty." }

        let maxLength = 1_000
        if trimmed.count <= maxLength {
            return trimmed
        }

        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return "\(trimmed[..<endIndex])..."
    }
}

private final class TerminalCallbackCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    weak var app: GhosttyApp?
    weak var surfaceView: TerminalSurfaceView?

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalCallbackCoordinator? {
        guard let userdata else { return nil }
        let coordinator = Unmanaged<TerminalCallbackCoordinator>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        return coordinator.isValid ? coordinator : nil
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
        surfaceView = nil
    }

    func wakeupApp() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isValid else { return }
            self.app?.appTick()
        }
    }

    @discardableResult
    func readClipboard(location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        syncOnMain { surfaceView in
            surfaceView.readClipboard(location: location, state: state)
        } ?? false
    }

    func confirmReadClipboard(
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        let value = string.map { String(cString: $0) } ?? ""
        let stateRef = SendableRawPointer(value: state)
        let requestRef = SendableClipboardRequest(value: request)
        asyncOnMain { surfaceView in
            surfaceView.confirmReadClipboard(
                data: value,
                state: stateRef.value,
                request: requestRef.value
            )
        }
    }

    func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let content, count > 0 else { return }
        let items = TerminalClipboard.items(content, count: count)
        guard !items.isEmpty else { return }

        let locationRef = SendableClipboardLocation(value: location)
        asyncOnMain { surfaceView in
            surfaceView.writeClipboard(
                items,
                location: locationRef.value,
                confirm: confirm
            )
        }
    }

    func closeSurface(processAlive: Bool) {
        asyncOnMain { surfaceView in
            surfaceView.handleGhosttyClose(processAlive: processAlive)
        }
    }

    @discardableResult
    func handleAction(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            let direction = action.action.new_split
            asyncOnMain { surfaceView in
                switch direction {
                case GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_SPLIT_DIRECTION_UP:
                    surfaceView.handleSplitDownRequest()
                default:
                    surfaceView.handleSplitRightRequest()
                }
            }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let title = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let body = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            asyncOnMain { surfaceView in
                surfaceView.handleDesktopNotification(title: title, body: body)
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            asyncOnMain { surfaceView in
                surfaceView.handleBell()
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            asyncOnMain { surfaceView in
                surfaceView.handleTitleChange(title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let pwd = action.action.pwd.pwd
                .flatMap { String(cString: $0) } ?? ""
            asyncOnMain { surfaceView in
                surfaceView.handleWorkingDirectoryChange(pwd)
            }
            return true

        default:
            return false
        }
    }

    @discardableResult
    private func syncOnMain<T>(_ body: @escaping @MainActor (TerminalSurfaceView) -> T) -> T? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                guard let surfaceView = currentSurfaceView() else { return nil }
                return body(surfaceView)
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let surfaceView = currentSurfaceView() else { return nil }
                return body(surfaceView)
            }
        }
    }

    private func asyncOnMain(_ body: @escaping @MainActor (TerminalSurfaceView) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let surfaceView = self.currentSurfaceView() else { return }
                body(surfaceView)
            }
        }
    }

    private func currentSurfaceView() -> TerminalSurfaceView? {
        guard isValid else { return nil }
        return surfaceView
    }
}

private enum TerminalRuntimeActionBridge {
    static func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag == GHOSTTY_TARGET_SURFACE {
            let userdata = ghostty_surface_userdata(target.target.surface)
            guard let callbacks = TerminalCallbackCoordinator.from(userdata) else { return false }
            return callbacks.handleAction(action)
        }

        return handleAppAction(action)
    }

    private static func handleAppAction(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let title = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let body = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                guard let surfaceId = TerminalSurfaceRegistry.shared.focusedSessionId else { return }
                SurfaceNotificationStore.shared.addNotification(
                    surfaceId: surfaceId,
                    title: title,
                    body: body
                )
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async {
                NSSound.beep()
            }
            return true

        default:
            return false
        }
    }
}

enum TerminalKeyForwardingPolicy {
    static func shouldForwardKeyEvent(_ type: NSEvent.EventType, modifierFlags _: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
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
    private let callbacks = TerminalCallbackCoordinator()

    static let shared = GhosttyApp()

    private init() {
        callbacks.app = self

        if UITestSupport.isEnabled {
            ready = true
            return
        }
        if UITestSupport.isRunningUnitTests {
            return
        }

        // Initialize ghostty runtime
        AppLogger.terminal.info("Initializing ghostty runtime")
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            AppLogger.terminal.error("ghostty_init failed")
            return
        }

        // Create config
        guard let cfg = ghostty_config_new() else {
            AppLogger.terminal.error("ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        self.config = cfg

        // Create runtime callbacks
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(callbacks).toOpaque()
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = { userdata in
            guard let callbacks = TerminalCallbackCoordinator.from(userdata) else { return }
            callbacks.wakeupApp()
        }
        runtime.action_cb = { _, target, action in
            TerminalRuntimeActionBridge.handle(target: target, action: action)
        }
        runtime.read_clipboard_cb = { userdata, loc, state in
            guard let callbacks = TerminalCallbackCoordinator.from(userdata) else { return false }
            return callbacks.readClipboard(location: loc, state: state)
        }
        runtime.confirm_read_clipboard_cb = { userdata, str, state, request in
            guard let callbacks = TerminalCallbackCoordinator.from(userdata) else { return }
            callbacks.confirmReadClipboard(string: str, state: state, request: request)
        }
        runtime.write_clipboard_cb = { userdata, loc, content, len, confirm in
            guard let callbacks = TerminalCallbackCoordinator.from(userdata) else { return }
            callbacks.writeClipboard(location: loc, content: content, count: len, confirm: confirm)
        }
        runtime.close_surface_cb = { userdata, processAlive in
            guard let callbacks = TerminalCallbackCoordinator.from(userdata) else { return }
            callbacks.closeSurface(processAlive: processAlive)
        }

        // Create the app
        guard let app = ghostty_app_new(&runtime, cfg) else {
            AppLogger.terminal.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            self.config = nil
            return
        }
        self.app = app
        self.ready = true
        AppLogger.terminal.info("Ghostty runtime initialized successfully")

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

    func setClipboardSurface(_ surfaceView: TerminalSurfaceView?) {
        callbacks.surfaceView = surfaceView
    }

    func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil

        TerminalSurfaceRegistry.shared.removeAll()
        callbacks.invalidate()

        if let app {
            ghostty_app_free(app)
            self.app = nil
        }

        if let config {
            ghostty_config_free(config)
            self.config = nil
        }

        ready = false
    }

}

// MARK: - Terminal Surface NSView

class TerminalSurfaceView: NSView {
    var surface: ghostty_surface_t?
    private(set) var sessionId: String?
    private var trackingArea: NSTrackingArea?
    private var keyEventMonitor: Any?
    private var windowScreenObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?
    private var forwardedKeyDownKeyCodes = Set<UInt16>()
    private let callbacks = TerminalCallbackCoordinator()
    private var retainedCallbacks: Unmanaged<TerminalCallbackCoordinator>?
    private var cleanedUp = false
    var onClose: (() -> Void)?
    var onFocus: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onNotification: ((String, String) -> Void)?
    var onBell: (() -> Void)?
    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onOpenBrowser: (() -> Void)?
    var onJumpToUnread: (() -> Void)?

    // Keep C strings alive for the lifetime of the surface
    private var commandCString: UnsafeMutablePointer<CChar>?
    private var workingDirCString: UnsafeMutablePointer<CChar>?

    private enum ClipboardShortcut {
        case copy
        case paste
    }

    init(app: ghostty_app_t, sessionId: String? = nil, command: String? = nil, workingDirectory: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        self.sessionId = sessionId
        callbacks.surfaceView = self
        retainedCallbacks = Unmanaged.passRetained(callbacks)
        GhosttyApp.shared.setClipboardSurface(self)

        // Use the factory function for default config, then customize
        var surfaceCfg = ghostty_surface_config_new()
        surfaceCfg.userdata = retainedCallbacks?.toOpaque()
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
            AppLogger.terminal.error("ghostty_surface_new failed")
            return
        }
        self.surface = s
        syncSurfaceBackingMetrics(sendSize: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        shutdownSurface()
    }

    func shutdownSurface() {
        guard !cleanedUp else { return }
        cleanedUp = true

        removeKeyEventMonitor()
        removeWindowScreenObserver()
        callbacks.invalidate()
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        retainedCallbacks?.release()
        retainedCallbacks = nil
        free(commandCString)
        commandCString = nil
        free(workingDirCString)
        workingDirCString = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, true)
        }
        GhosttyApp.shared.setClipboardSurface(self)
        TerminalSurfaceRegistry.shared.recordFocus(sessionId: sessionId)
        onFocus?()
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

        if handleWorkspaceShortcut(event) {
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
        GhosttyApp.shared.setClipboardSurface(self)
        updateWindowScreenObserver()
        updateSurfaceDisplayID()
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
        if handleWorkspaceShortcut(event) {
            return
        }
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
        if !forwardMouseButton(
            with: event,
            action: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            focusOnPress: true
        ) {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !forwardMouseButton(
            with: event,
            action: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT
        ) {
            super.mouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !forwardMouseButton(
            with: event,
            action: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_RIGHT,
            focusOnPress: true
        ) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !forwardMouseButton(
            with: event,
            action: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_RIGHT
        ) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !forwardMouseButton(
            with: event,
            action: GHOSTTY_MOUSE_PRESS,
            button: mouseButton(from: event.buttonNumber),
            focusOnPress: true
        ) {
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !forwardMouseButton(
            with: event,
            action: GHOSTTY_MOUSE_RELEASE,
            button: mouseButton(from: event.buttonNumber)
        ) {
            super.otherMouseUp(with: event)
        }
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

    func synchronizeLayoutSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else {
            syncSurfaceBackingMetrics()
            return
        }

        let normalizedSize = CGSize(
            width: max(0, size.width),
            height: max(0, size.height)
        )
        if bounds.size != normalizedSize {
            setFrameSize(normalizedSize)
        } else {
            syncSurfaceBackingMetrics()
        }
    }

    private func syncSurfaceBackingMetrics(sendSize: Bool = true) {
        updateLayerContentsScale()
        guard let surface else { return }

        let pointBounds = bounds
        let scale = max(1, effectiveBackingScale.isFinite ? effectiveBackingScale : 1)
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

        let xScaleRaw = pointBounds.width > 0 ? backingBounds.width / pointBounds.width : scale
        let yScaleRaw = pointBounds.height > 0 ? backingBounds.height / pointBounds.height : scale
        let xScale = max(1, xScaleRaw.isFinite ? xScaleRaw : scale)
        let yScale = max(1, yScaleRaw.isFinite ? yScaleRaw : scale)
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

    private func updateWindowScreenObserver() {
        guard observedWindow !== window else { return }
        removeWindowScreenObserver()
        guard let window else { return }
        observedWindow = window
        windowScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowScreenChange()
        }
    }

    private func removeWindowScreenObserver() {
        if let windowScreenObserver {
            NotificationCenter.default.removeObserver(windowScreenObserver)
        }
        windowScreenObserver = nil
        observedWindow = nil
    }

    private func handleWindowScreenChange() {
        updateSurfaceDisplayID()
        syncSurfaceBackingMetrics()
    }

    private func updateSurfaceDisplayID() {
        guard let surface else { return }
        ghostty_surface_set_display_id(surface, currentDisplayID())
    }

    private func currentDisplayID() -> UInt32 {
        guard let screen = window?.screen,
              let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return value.uint32Value
    }

    private func handleMonitoredKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard canReceiveTerminalKeyEvents,
              isEventFromCurrentWindow(event) else {
            return event
        }

        switch event.type {
        case .keyDown:
            if handleWorkspaceShortcut(event) {
                return nil
            }
            return forwardKeyDown(with: terminalKeyEvent(for: event)) ? nil : event

        case .keyUp:
            return forwardKeyUp(with: event) ? nil : event

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
        if handleWorkspaceShortcut(event) { return true }

        let translationFlags = translatedModifierFlags(for: event, surface: surface)
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let handled = sendKey(
            action,
            event: event,
            translationFlags: translationFlags,
            text: ghosttyCharacters(for: event, translationFlags: translationFlags)
        )
        if handled {
            forwardedKeyDownKeyCodes.insert(event.keyCode)
        }
        return handled
    }

    @discardableResult
    private func forwardKeyUp(with event: NSEvent) -> Bool {
        guard surface != nil else { return false }
        guard forwardedKeyDownKeyCodes.remove(event.keyCode) != nil else { return false }
        return sendKey(GHOSTTY_ACTION_RELEASE, event: event)
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

        return sendKey(action, event: event)
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
    func readClipboard(location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard surface != nil else { return false }
        guard let str = TerminalClipboard.readString(for: location) else { return false }
        return completeClipboardRequest(data: str, state: state, confirmed: false)
    }

    func confirmReadClipboard(
        data: String,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard surface != nil, state != nil else { return }
        let approved = TerminalClipboardConfirmation.requestApproval(
            for: request,
            preview: data,
            window: window
        )
        _ = completeClipboardRequest(
            data: approved ? data : "",
            state: state,
            confirmed: approved
        )
    }

    fileprivate func writeClipboard(
        _ items: [TerminalClipboard.Item],
        location: ghostty_clipboard_e,
        confirm: Bool
    ) {
        guard surface != nil else { return }
        guard let pasteboard = TerminalClipboard.pasteboard(for: location) else { return }

        if confirm {
            guard TerminalClipboardConfirmation.requestApprovalForWrite(
                items: items,
                window: window
            ) else { return }
        }

        TerminalClipboard.write(items, to: pasteboard)
        if TerminalClipboard.isSelectionClipboard(location) {
            TerminalClipboard.write(items, to: .general)
        }
    }

    func handleGhosttyClose(processAlive: Bool) {
        AppLogger.terminal.info(
            "Ghostty surface requested close",
            metadata: ["processAlive": "\(processAlive)"]
        )

        if let sessionId {
            TerminalSurfaceRegistry.shared.deregister(sessionId: sessionId, view: self)
        } else {
            shutdownSurface()
            removeFromSuperview()
        }

        onClose?()
    }

    func handleTitleChange(_ title: String) {
        onTitleChange?(title)
    }

    func handleWorkingDirectoryChange(_ workingDirectory: String) {
        onWorkingDirectoryChange?(workingDirectory)
    }

    func handleDesktopNotification(title: String, body: String) {
        onNotification?(title, body)
    }

    func handleBell() {
        NSSound.beep()
        onBell?()
    }

    func handleSplitRightRequest() {
        onSplitRight?()
    }

    func handleSplitDownRequest() {
        onSplitDown?()
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

    private func handleWorkspaceShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else {
            return false
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        let shifted = flags.contains(.shift)

        switch key {
        case "d":
            if shifted {
                onSplitDown?()
            } else {
                onSplitRight?()
            }
            return true
        case "l" where shifted:
            onOpenBrowser?()
            return true
        case "u" where shifted:
            onJumpToUnread?()
            return true
        default:
            return false
        }
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

    @discardableResult
    private func forwardMouseButton(
        with event: NSEvent,
        action: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        focusOnPress: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        if focusOnPress {
            window?.makeFirstResponder(self)
        }
        sendMousePos(event)
        return ghostty_surface_mouse_button(surface, action, button, modsFromEvent(event))
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
        let hasShift = flags.contains(.shift)
        let hasControl = flags.contains(.control)
        let hasOption = flags.contains(.option)
        let hasCommand = flags.contains(.command)

        if hasShift { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if hasControl { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if hasOption { raw |= GHOSTTY_MODS_ALT.rawValue }
        if hasCommand { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }

        let rawFlags = flags.rawValue
        if hasShift && rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if hasControl && rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if hasOption && rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if hasCommand && rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

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

final class TerminalSurfaceRegistry {
    static let shared = TerminalSurfaceRegistry()

    private var views: [String: TerminalSurfaceView] = [:]
    private(set) var focusedSessionId: String?

    private init() {}

    func view(
        for sessionId: String,
        app: ghostty_app_t,
        command: String?,
        workingDirectory: String?
    ) -> TerminalSurfaceView {
        if let existing = views[sessionId] {
            return existing
        }

        let view = TerminalSurfaceView(
            app: app,
            sessionId: sessionId,
            command: command,
            workingDirectory: workingDirectory
        )
        views[sessionId] = view
        return view
    }

    func deregister(sessionId: String) {
        guard let view = views.removeValue(forKey: sessionId) else { return }
        if focusedSessionId == sessionId {
            focusedSessionId = nil
        }
        view.shutdownSurface()
    }

    func deregister(sessionId: String, view: TerminalSurfaceView) {
        guard views[sessionId] === view else { return }
        views.removeValue(forKey: sessionId)
        if focusedSessionId == sessionId {
            focusedSessionId = nil
        }
        view.shutdownSurface()
    }

    func recordFocus(sessionId: String?) {
        focusedSessionId = sessionId
    }

    func removeAll() {
        let retainedViews = Array(views.values)
        views.removeAll()
        focusedSessionId = nil
        for view in retainedViews {
            view.shutdownSurface()
        }
    }
}

struct TerminalSurfaceRepresentable: NSViewRepresentable {
    let app: ghostty_app_t
    var sessionId: String? = nil
    var command: String? = nil
    var workingDirectory: String? = nil
    var layoutSize: CGSize = .zero
    var onClose: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var onTitleChange: ((String) -> Void)? = nil
    var onWorkingDirectoryChange: ((String) -> Void)? = nil
    var onNotification: ((String, String) -> Void)? = nil
    var onBell: (() -> Void)? = nil
    var onSplitRight: (() -> Void)? = nil
    var onSplitDown: (() -> Void)? = nil
    var onOpenBrowser: (() -> Void)? = nil
    var onJumpToUnread: (() -> Void)? = nil

    func makeNSView(context: Context) -> TerminalSurfaceView {
        let view: TerminalSurfaceView
        if let sessionId {
            view = TerminalSurfaceRegistry.shared.view(
                for: sessionId,
                app: app,
                command: command,
                workingDirectory: workingDirectory
            )
        } else {
            view = TerminalSurfaceView(app: app, command: command, workingDirectory: workingDirectory)
        }

        applyCallbacks(to: view)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard view.window != nil else { return }
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalSurfaceView, context: Context) {
        nsView.synchronizeLayoutSize(layoutSize)
        applyCallbacks(to: nsView)
    }

    private func applyCallbacks(to view: TerminalSurfaceView) {
        view.onClose = onClose
        view.onFocus = onFocus
        view.onTitleChange = onTitleChange
        view.onWorkingDirectoryChange = onWorkingDirectoryChange
        view.onNotification = onNotification
        view.onBell = onBell
        view.onSplitRight = onSplitRight
        view.onSplitDown = onSplitDown
        view.onOpenBrowser = onOpenBrowser
        view.onJumpToUnread = onJumpToUnread
    }

    static func dismantleNSView(_ nsView: TerminalSurfaceView, coordinator: ()) {
        if nsView.sessionId != nil {
            // Keep the surface alive in the registry so it persists across tab switches.
            // It will be shut down explicitly when the terminal tab is closed.
        } else {
            nsView.shutdownSurface()
        }
    }
}

// MARK: - Terminal Tab View

struct TerminalView: View {
    @ObservedObject private var ghostty = GhosttyApp.shared
    var sessionId: String? = nil
    var command: String? = nil
    var workingDirectory: String? = nil
    var onClose: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var onTitleChange: ((String) -> Void)? = nil
    var onWorkingDirectoryChange: ((String) -> Void)? = nil
    var onNotification: ((String, String) -> Void)? = nil
    var onBell: (() -> Void)? = nil
    var onSplitRight: (() -> Void)? = nil
    var onSplitDown: (() -> Void)? = nil
    var onOpenBrowser: (() -> Void)? = nil
    var onJumpToUnread: (() -> Void)? = nil

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
                    if let command {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(3)
                            .accessibilityIdentifier("terminal.command")
                    }
                    if let workingDirectory {
                        Text(workingDirectory)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                            .accessibilityIdentifier("terminal.cwd")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.base)
                .accessibilityIdentifier("terminal.placeholder")
            } else if let app = ghostty.app {
                GeometryReader { geometry in
                    TerminalSurfaceRepresentable(
                        app: app,
                        sessionId: sessionId,
                        command: command,
                        workingDirectory: workingDirectory,
                        layoutSize: geometry.size,
                        onClose: onClose,
                        onFocus: onFocus,
                        onTitleChange: onTitleChange,
                        onWorkingDirectoryChange: onWorkingDirectoryChange,
                        onNotification: onNotification,
                        onBell: onBell,
                        onSplitRight: onSplitRight,
                        onSplitDown: onSplitDown,
                        onOpenBrowser: onOpenBrowser,
                        onJumpToUnread: onJumpToUnread
                    )
                }
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
