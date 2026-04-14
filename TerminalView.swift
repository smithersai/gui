import SwiftUI
import AppKit
import GhosttyKit

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
            // Return false = we don't handle clipboard reads via this callback
            return false
        }
        runtime.confirm_read_clipboard_cb = { userdata, str, state, request in
            // No-op for confirm read
        }
        runtime.write_clipboard_cb = { userdata, loc, content, len, confirm in
            guard let content else { return }
            let mimePtr = content.pointee.mime
            let dataPtr = content.pointee.data
            guard let dataPtr else { return }
            let str = String(cString: dataPtr)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(str, forType: .string)
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
        let appRef = app
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { _ in
            ghostty_app_tick(appRef)
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

    init(app: ghostty_app_t) {
        super.init(frame: .zero)
        wantsLayer = true

        // Use the factory function for default config, then customize
        var surfaceCfg = ghostty_surface_config_new()
        surfaceCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceCfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        surfaceCfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        surfaceCfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        guard let s = ghostty_surface_new(app, &surfaceCfg) else {
            NSLog("ghostty_surface_new failed")
            return
        }
        self.surface = s
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }
        let scale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        ghostty_surface_set_size(
            surface,
            UInt32(Double(newSize.width) * scale),
            UInt32(Double(newSize.height) * scale)
        )
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let surface else { super.keyDown(with: event); return }

        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = modsFromEvent(event)
        key.keycode = UInt32(event.keyCode)
        key.composing = false

        if let chars = event.characters, !chars.isEmpty {
            chars.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_RELEASE
        key.mods = modsFromEvent(event)
        key.keycode = UInt32(event.keyCode)
        _ = ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = modsFromEvent(event)
        key.keycode = UInt32(event.keyCode)
        _ = ghostty_surface_key(surface, key)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        sendMousePos(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
        sendMousePos(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            0 // scroll mods
        )
    }

    // MARK: - Helpers

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        ghostty_surface_mouse_pos(
            surface,
            Double(pt.x) * scale,
            Double(bounds.height - pt.y) * scale,
            modsFromEvent(event)
        )
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if event.modifierFlags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
}

// MARK: - SwiftUI Wrapper

struct TerminalSurfaceRepresentable: NSViewRepresentable {
    let app: ghostty_app_t

    func makeNSView(context: Context) -> TerminalSurfaceView {
        let view = TerminalSurfaceView(app: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalSurfaceView, context: Context) {}
}

// MARK: - Terminal Tab View

struct TerminalView: View {
    @ObservedObject private var ghostty = GhosttyApp.shared

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
                TerminalSurfaceRepresentable(app: app)
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
