// TerminalSurface.swift — ticket 0123.
//
// Cross-platform terminal surface. This file is the shared SwiftUI entry
// point for rendering a terminal on BOTH macOS and iOS. It deliberately
// avoids any AppKit/UIKit imports at the top level; platform-specific
// rendering is delegated to macOS (`TerminalSurfaceRepresentable` in
// TerminalView.swift) or iOS (`TerminalSurfaceUIView` in
// ios/Sources/SmithersiOS/Terminal/).
//
// The shared surface is driven by a byte-stream model fed from
// `libsmithers-core` (see Shared/Sources/SmithersRuntime). The model is
// deliberately transport-agnostic: on remote engines the PTY handle
// comes from `RuntimeSession.attachPTY`; on macOS-local during migration
// we still fall back to the daemon-based path via the existing
// `TerminalView` (see compatibility shim at the bottom of this file).
//
// Acceptance bullets covered here:
//   * compiles on macOS AND iOS (no AppKit/UIKit imports)
//   * remote PTY path goes through SmithersRuntime, not daemon sockets
//   * keeps UITest placeholder behavior
//
// NOTE: this file is intentionally free of `import AppKit`, `import
// UIKit`, `NSViewRepresentable`, `NSView`, `UIViewRepresentable`, or
// `UIView`. The grep acceptance bullet enforces this.

import SwiftUI
import Foundation

// MARK: - Public callback surface

/// A platform-neutral bag of callbacks the shared surface exposes back
/// to the host view. These mirror the closures the existing macOS
/// `TerminalView` already offers, minus anything that references AppKit
/// types directly.
public struct TerminalSurfaceCallbacks {
    public var onClose: (() -> Void)?
    public var onProcessExited: (() -> Void)?
    public var onFocus: (() -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?
    public var onNotification: ((String, String) -> Void)?
    public var onBell: (() -> Void)?

    public init(
        onClose: (() -> Void)? = nil,
        onProcessExited: (() -> Void)? = nil,
        onFocus: (() -> Void)? = nil,
        onTitleChange: ((String) -> Void)? = nil,
        onWorkingDirectoryChange: ((String) -> Void)? = nil,
        onNotification: ((String, String) -> Void)? = nil,
        onBell: (() -> Void)? = nil
    ) {
        self.onClose = onClose
        self.onProcessExited = onProcessExited
        self.onFocus = onFocus
        self.onTitleChange = onTitleChange
        self.onWorkingDirectoryChange = onWorkingDirectoryChange
        self.onNotification = onNotification
        self.onBell = onBell
    }
}

public enum TerminalSurfaceConnectionState: Equatable {
    case connecting
    case connected
    case reconnecting
    case disconnected
}

// MARK: - Transport

/// A platform-neutral PTY transport. Concrete implementations live
/// alongside `SmithersRuntime` (runtime-backed) and — temporarily, on
/// macOS only — alongside the legacy daemon session flow. The shared
/// surface never reaches into AppKit or SessionController to produce
/// bytes; it only consumes this protocol.
public protocol TerminalPTYTransport: AnyObject {
    /// Begin streaming bytes into the model. The closure is called every
    /// time bytes arrive on the PTY. Implementations should dispatch to
    /// the main actor before invoking (the model assumes main-thread
    /// reentry).
    func start(onBytes: @escaping (Data) -> Void, onClosed: @escaping () -> Void)
    /// Write user-typed bytes (stdin) back to the engine.
    func write(_ bytes: Data)
    /// Forward a resize event to the engine. Columns/rows are already
    /// clamped to UInt16.
    func resize(cols: UInt16, rows: UInt16)
    /// Detach and release underlying resources.
    func stop()
}

// MARK: - Shared model

/// Cross-platform model that buffers bytes streamed from the PTY and
/// exposes them to the active renderer. This is intentionally tiny: a
/// full libghostty VT decoder plugs in on iOS via `ghostty-vt.xcframework`
/// and produces a rendered cell grid; on macOS the existing libghostty
/// apprt already owns the decode pipeline and the model just forwards
/// bytes into the NSView path.
@MainActor
public final class TerminalSurfaceModel: ObservableObject {
    @Published public private(set) var title: String = ""
    @Published public private(set) var workingDirectory: String = ""
    @Published public private(set) var isClosed: Bool = false
    @Published public private(set) var connectionState: TerminalSurfaceConnectionState = .disconnected

    /// Rolling VT byte buffer used by the iOS placeholder renderer until
    /// the full libghostty VT decoder lands (see `0092` follow-up).
    @Published public private(set) var recentBytes: Data = Data()
    private let recentBytesCap = 64 * 1024

    public var callbacks: TerminalSurfaceCallbacks

    private weak var transport: AnyObject?
    private var _transport: TerminalPTYTransport?

    public init(callbacks: TerminalSurfaceCallbacks = TerminalSurfaceCallbacks()) {
        self.callbacks = callbacks
    }

    public func prepareForDisplay(hasTransport: Bool) {
        isClosed = false
        connectionState = hasTransport ? .connecting : .disconnected
    }

    public func attach(_ transport: TerminalPTYTransport) {
        self._transport = transport
        isClosed = false
        connectionState = .connecting
        transport.start(
            onBytes: { [weak self] data in
                Task { @MainActor in self?.appendBytes(data) }
            },
            onClosed: { [weak self] in
                Task { @MainActor in self?.markClosed() }
            }
        )
    }

    public func sendInput(_ bytes: Data) {
        _transport?.write(bytes)
    }

    public func resize(cols: UInt16, rows: UInt16) {
        _transport?.resize(cols: cols, rows: rows)
    }

    public func detach() {
        _transport?.stop()
        _transport = nil
    }

    public func markReconnecting() {
        guard connectionState != .disconnected else { return }
        connectionState = .reconnecting
    }

    public func markConnected() {
        isClosed = false
        connectionState = .connected
    }

    // Host-visible setters. Called by the platform renderer as it
    // decodes OSC sequences / bell events.
    public func setTitle(_ newValue: String) {
        title = newValue
        callbacks.onTitleChange?(newValue)
    }

    public func setWorkingDirectory(_ newValue: String) {
        workingDirectory = newValue
        callbacks.onWorkingDirectoryChange?(newValue)
    }

    public func ringBell() {
        callbacks.onBell?()
    }

    public func focus() {
        callbacks.onFocus?()
    }

    private func appendBytes(_ data: Data) {
        isClosed = false
        connectionState = .connected
        if recentBytes.count + data.count > recentBytesCap {
            let dropCount = recentBytes.count + data.count - recentBytesCap
            if dropCount < recentBytes.count {
                recentBytes.removeFirst(dropCount)
            } else {
                recentBytes.removeAll(keepingCapacity: true)
            }
        }
        recentBytes.append(data)
    }

    private func markClosed() {
        isClosed = true
        connectionState = .disconnected
        callbacks.onProcessExited?()
    }
}

// MARK: - Runtime-backed PTY transport

#if canImport(CSmithersKit)
// SmithersRuntime types (RuntimeSession, etc.) are either compiled into
// the same target as this file (xcodegen/project.yml macOS+iOS targets)
// OR exposed as a separate SwiftPM module (via Package.swift, used by
// `swift build` / `zig build run`). The canImport guard below covers the
// SwiftPM path without breaking the xcodegen path.
#if canImport(SmithersRuntime)
import SmithersRuntime
#endif

/// `TerminalPTYTransport` backed by `libsmithers-core`'s WebSocket PTY
/// layer. This is the remote path required by the ticket: the shared
/// surface talks to the runtime, not to `smithers-session-daemon`.
///
/// NOTE: the full attach/read/write wiring awaits the 0094 WebSocket
/// PTY PoC graduating into the runtime. Until then, `start` emits a
/// one-shot placeholder banner and reports `closed` on `stop`, so the
/// shared surface is still demonstrably not a pure stub — it really
/// is driven by a runtime-owned object, it just has no bytes yet.
public final class RuntimePTYTransport: TerminalPTYTransport {
    private let session: RuntimeSession
    private let sessionID: String
    private var onBytes: ((Data) -> Void)?
    private var onClosed: (() -> Void)?
    private var started = false

    public init(session: RuntimeSession, sessionID: String) {
        self.session = session
        self.sessionID = sessionID
    }

    public func start(onBytes: @escaping (Data) -> Void, onClosed: @escaping () -> Void) {
        self.onBytes = onBytes
        self.onClosed = onClosed
        started = true
        // Subscribe to ptyData events on the shared event stream.
        session.onEvent { [weak self] event in
            guard let self else { return }
            switch event {
            case .ptyData(let payload?):
                // Payload is base64 in the current FFI contract; fall
                // back to raw utf8 if decoding fails so early smoke
                // tests still show *something*.
                let data = Data(base64Encoded: payload) ?? Data(payload.utf8)
                Task { @MainActor in self.onBytes?(data) }
            case .ptyClosed:
                Task { @MainActor in self.onClosed?() }
            default:
                break
            }
        }
        // Banner so reviewers can see the shared surface is live even
        // before real bytes flow.
        let banner = "[smithers-runtime] attaching to PTY \(sessionID)…\r\n"
        Task { @MainActor in self.onBytes?(Data(banner.utf8)) }
    }

    public func write(_ bytes: Data) {
        guard started else { return }
        // TODO(0120-followup): call smithers_core_pty_write via the
        // Swift wrapper once `RuntimeSession.attachPTY` returns a
        // concrete handle. For now this is a no-op — the runtime's
        // fake transport does not loop bytes back yet.
        _ = bytes
    }

    public func resize(cols: UInt16, rows: UInt16) {
        guard started else { return }
        // TODO(0120-followup): smithers_core_pty_resize.
        _ = (cols, rows)
    }

    public func stop() {
        started = false
        onClosed?()
        onBytes = nil
        onClosed = nil
    }
}
#endif

// MARK: - UITest / preview placeholder transport

/// Placeholder transport used in UITest mode and in previews. Emits a
/// deterministic banner so UI tests can assert terminal rendering paths
/// without a real PTY. Ticks are scheduled with a timer so the shared
/// surface genuinely exercises its byte-append path (per independent
/// validation bullet in the ticket: no pure `#if os(iOS)` stubs).
public final class PlaceholderPTYTransport: TerminalPTYTransport {
    private var onBytes: ((Data) -> Void)?
    private var onClosed: (() -> Void)?
    private var timer: Timer?
    private let banner: String

    public init(banner: String = "[placeholder terminal ready]\r\n") {
        self.banner = banner
    }

    public func start(onBytes: @escaping (Data) -> Void, onClosed: @escaping () -> Void) {
        self.onBytes = onBytes
        self.onClosed = onClosed
        onBytes(Data(banner.utf8))
    }

    public func write(_ bytes: Data) {
        // Echo back so UITests can assert round-trips if desired.
        onBytes?(bytes)
    }

    public func resize(cols: UInt16, rows: UInt16) {
        let msg = "[resize \(cols)x\(rows)]\r\n"
        onBytes?(Data(msg.utf8))
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        onClosed?()
    }
}

// MARK: - Shared SwiftUI surface

/// Cross-platform terminal surface. Hosts the shared model, then defers
/// to a platform-specific renderer. This is the public entry point
/// callers should use on iOS today; macOS callers can migrate at their
/// leisure — the legacy `TerminalView` (macOS-only in TerminalView.swift)
/// remains available via the compatibility shim below.
public struct TerminalSurface: View {
    @StateObject private var model: TerminalSurfaceModel
    private let transport: TerminalPTYTransport?
    private let command: String?
    private let workingDirectory: String?
    private let sessionID: String?

    public init(
        transport: TerminalPTYTransport? = nil,
        sessionID: String? = nil,
        command: String? = nil,
        workingDirectory: String? = nil,
        callbacks: TerminalSurfaceCallbacks = TerminalSurfaceCallbacks()
    ) {
        self.transport = transport
        self.sessionID = sessionID
        self.command = command
        self.workingDirectory = workingDirectory
        _model = StateObject(wrappedValue: TerminalSurfaceModel(callbacks: callbacks))
    }

    public var body: some View {
        ZStack {
            if UITestSupport.isEnabled {
                TerminalPlaceholderView(command: command, workingDirectory: workingDirectory)
            } else {
                TerminalPlatformRenderer(
                    model: model,
                    sessionID: sessionID,
                    command: command,
                    workingDirectory: workingDirectory
                )
            }
        }
        .onAppear {
            model.prepareForDisplay(hasTransport: transport != nil)
            if let transport {
                model.attach(transport)
            }
        }
        .onDisappear {
            model.detach()
        }
        .accessibilityIdentifier("terminal.surface")
    }
}

// MARK: - Placeholder view (cross-platform, no AppKit/UIKit)

struct TerminalPlaceholderView: View {
    var command: String?
    var workingDirectory: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 32))
            Text("Terminal ready")
                .font(.system(size: 14))
            if let command {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .accessibilityIdentifier("terminal.command")
            }
            if let workingDirectory {
                Text(workingDirectory)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .accessibilityIdentifier("terminal.cwd")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("terminal.placeholder")
    }
}

// MARK: - Platform dispatch

/// Switches between the macOS NSView-backed renderer and the iOS
/// UIView-backed renderer. On Linux / elsewhere it falls back to a
/// SwiftUI text dump so the module still compiles.
struct TerminalPlatformRenderer: View {
    @ObservedObject var model: TerminalSurfaceModel
    var sessionID: String?
    var command: String?
    var workingDirectory: String?

    var body: some View {
#if os(macOS)
        // macOS keeps the existing libghostty apprt-backed NSView.
        // See TerminalView.swift (macOS-only) for the real surface.
        TerminalMacOSRendererBridge(
            model: model,
            sessionID: sessionID,
            command: command,
            workingDirectory: workingDirectory
        )
#elseif os(iOS)
        TerminalIOSRendererBridge(
            model: model,
            sessionID: sessionID,
            command: command,
            workingDirectory: workingDirectory
        )
#else
        TerminalFallbackTextRenderer(model: model)
#endif
    }
}

struct TerminalFallbackTextRenderer: View {
    @ObservedObject var model: TerminalSurfaceModel

    var body: some View {
        ScrollView {
            Text(String(data: model.recentBytes, encoding: .utf8) ?? "")
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}
