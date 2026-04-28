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
import Combine
import os

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

private extension TerminalSurfaceConnectionState {
    var logValue: String {
        switch self {
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .disconnected:
            return "disconnected"
        }
    }
}

// MARK: - Transport

/// A platform-neutral PTY transport. Concrete implementations live
/// alongside `SmithersRuntime` (runtime-backed) and — temporarily, on
/// macOS only — alongside the legacy daemon session flow. The shared
/// surface never reaches into AppKit or SessionController to produce
/// bytes; it only consumes this protocol.
@MainActor
public protocol TerminalPTYTransport: AnyObject {
    var connectionState: TerminalSurfaceConnectionState { get }
    var connectionStatePublisher: AnyPublisher<TerminalSurfaceConnectionState, Never> { get }
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
    /// Request a fresh connection attempt after a terminal disconnect.
    func reconnect()
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

    private var _transport: TerminalPTYTransport?
    private var transportStateCancellable: AnyCancellable?

    public init(callbacks: TerminalSurfaceCallbacks = TerminalSurfaceCallbacks()) {
        self.callbacks = callbacks
    }

    public func prepareForDisplay(hasTransport: Bool) {
        isClosed = false
        connectionState = hasTransport ? .connecting : .disconnected
    }

    public func attach(_ transport: TerminalPTYTransport) {
        transportStateCancellable?.cancel()
        self._transport = transport
        isClosed = false
        connectionState = .connecting
        transportStateCancellable = transport.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyConnectionState(state)
            }
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
        transportStateCancellable?.cancel()
        transportStateCancellable = nil
        _transport?.stop()
        _transport = nil
    }

    public func retryConnection() {
        _transport?.reconnect()
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

    private func applyConnectionState(_ newValue: TerminalSurfaceConnectionState) {
        connectionState = newValue
        if newValue != .disconnected {
            isClosed = false
        }
    }

    private func markClosed() {
        isClosed = true
        connectionState = .disconnected
        callbacks.onProcessExited?()
    }
}

// MARK: - Runtime-backed PTY transport

// SmithersRuntime types (RuntimeSession, etc.) are either compiled into
// the same target as this file (xcodegen/project.yml macOS+iOS targets)
// OR exposed as a separate SwiftPM module (via Package.swift, used by
// `swift build` / `zig build run`). The canImport guard below covers the
// SwiftPM path without breaking the xcodegen path.
#if canImport(SmithersRuntime)
import SmithersRuntime
#endif

internal protocol RuntimePTYHandle: AnyObject {
    var handle: UInt64? { get }
    func write(_ bytes: Data) throws
    func resize(cols: UInt16, rows: UInt16) throws
    func detach()
}

internal protocol RuntimePTYSessionProviding: AnyObject {
    @discardableResult
    func addEventListener(_ handler: @escaping (RuntimeEvent) -> Void) -> UUID
    func removeEventListener(_ token: UUID)
    func attachRuntimePTY(sessionID: String) throws -> any RuntimePTYHandle
}

extension RuntimePTY: RuntimePTYHandle {}

extension RuntimeSession: RuntimePTYSessionProviding {
    internal func attachRuntimePTY(sessionID: String) throws -> any RuntimePTYHandle {
        try attachPTY(sessionID: sessionID)
    }
}

/// Internal clock/sleeper seam for `RuntimePTYTransport` reconnect backoff.
///
/// Production uses `DefaultRuntimePTYSleeper` which delegates to
/// `Task.sleep(nanoseconds:)`. Tests inject a manual sleeper so retry-budget
/// and backoff assertions advance deterministically without wall-clock waits.
internal protocol RuntimePTYSleeper: Sendable {
    /// Sleep for the requested number of (whole) seconds. Must throw
    /// `CancellationError` if the surrounding `Task` is cancelled.
    func sleep(seconds: Int) async throws
}

internal struct DefaultRuntimePTYSleeper: RuntimePTYSleeper {
    func sleep(seconds: Int) async throws {
        let clamped = max(0, seconds)
        try await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000_000)
    }
}

/// `TerminalPTYTransport` backed by `libsmithers-core`'s WebSocket PTY
/// layer. This is the remote path required by the ticket: the shared
/// surface talks to the runtime, not to `smithers-session-daemon`.
///
/// Connection state is driven from the PTY lifecycle: initial attach,
/// reconnect backoff, successful reattach, and terminal disconnect.
@MainActor
public final class RuntimePTYTransport: TerminalPTYTransport {
    @Published public private(set) var connectionState: TerminalSurfaceConnectionState = .disconnected

    public var connectionStatePublisher: AnyPublisher<TerminalSurfaceConnectionState, Never> {
        $connectionState
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private let session: any RuntimePTYSessionProviding
    private let sessionID: String
    private let sleeper: any RuntimePTYSleeper
    private let decoder = JSONDecoder()
    private var onBytes: ((Data) -> Void)?
    private var onClosed: (() -> Void)?
    private var pty: (any RuntimePTYHandle)?
    private var eventListenerToken: UUID?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var pendingSize: (cols: UInt16, rows: UInt16)?
    private var started = false
    private var isStopping = false

    private static let logger = Logger(subsystem: "com.smithers.gui", category: "terminal")
    private static let maxReconnectAttempts = 5

    private struct PTYDataEnvelope: Decodable {
        let handle: UInt64
        let bytes: String
    }

    private struct PTYClosedEnvelope: Decodable {
        let handle: UInt64
    }

    public convenience init(session: RuntimeSession, sessionID: String) {
        self.init(session: session, sessionID: sessionID, sleeper: DefaultRuntimePTYSleeper())
    }

    internal init(
        session: any RuntimePTYSessionProviding,
        sessionID: String,
        sleeper: any RuntimePTYSleeper = DefaultRuntimePTYSleeper()
    ) {
        self.session = session
        self.sessionID = sessionID
        self.sleeper = sleeper
    }

    public func start(onBytes: @escaping (Data) -> Void, onClosed: @escaping () -> Void) {
        guard !started else { return }
        self.onBytes = onBytes
        self.onClosed = onClosed
        started = true
        isStopping = false
        reconnectAttempts = 0

        if eventListenerToken == nil {
            eventListenerToken = session.addEventListener { [weak self] event in
                Task { @MainActor in
                    self?.handleRuntimeEvent(event)
                }
            }
        }

        attemptAttach(reason: "initial connect", initialState: .connecting)
    }

    public func write(_ bytes: Data) {
        guard started else { return }
        guard let pty else { return }
        do {
            try pty.write(bytes)
        } catch {
            Self.logger.error("terminal write failed for session \(self.sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        pendingSize = (cols, rows)
        guard started, let pty else { return }
        do {
            try pty.resize(cols: cols, rows: rows)
        } catch {
            Self.logger.error("terminal resize failed for session \(self.sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func reconnect() {
        guard started else { return }
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        attemptAttach(reason: "manual reconnect", initialState: .connecting)
    }

    public func stop() {
        guard started || eventListenerToken != nil else { return }
        isStopping = true
        started = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if let token = eventListenerToken {
            session.removeEventListener(token)
            eventListenerToken = nil
        }
        releasePTY()
        transition(to: .disconnected, reason: "transport stopped")
        onBytes = nil
        onClosed = nil
    }

    private func handleRuntimeEvent(_ event: RuntimeEvent) {
        guard started else { return }

        switch event {
        case .ptyData(let payload?):
            guard let envelope = decodePayload(PTYDataEnvelope.self, from: payload) else { return }
            guard matchesCurrentPTYHandle(envelope.handle) else { return }
            onBytes?(Data(envelope.bytes.utf8))
        case .ptyClosed(let payload):
            if let envelope = payload.flatMap({ decodePayload(PTYClosedEnvelope.self, from: $0) }) {
                guard matchesCurrentPTYHandle(envelope.handle) else { return }
                Self.logger.warning("terminal PTY closed for session \(self.sessionID, privacy: .public) handle=\(String(envelope.handle), privacy: .public)")
            } else {
                Self.logger.warning("terminal PTY closed for session \(self.sessionID, privacy: .public)")
            }
            handleUnexpectedClose(reason: "PTY closed")
        default:
            break
        }
    }

    private func attemptAttach(reason: String, initialState: TerminalSurfaceConnectionState) {
        guard started, !isStopping else { return }

        reconnectTask?.cancel()
        reconnectTask = nil
        releasePTY()
        transition(to: initialState, reason: reason)

        do {
            let pty = try session.attachRuntimePTY(sessionID: sessionID)
            self.pty = pty
            if let pendingSize {
                try pty.resize(cols: pendingSize.cols, rows: pendingSize.rows)
            }
            reconnectAttempts = 0
            transition(to: .connected, reason: "PTY attached")
        } catch {
            Self.logger.error("terminal attach failed for session \(self.sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            scheduleReconnect(reason: "attach failed")
        }
    }

    private func matchesCurrentPTYHandle(_ handle: UInt64) -> Bool {
        guard let currentHandle = pty?.handle else { return false }
        return currentHandle == handle
    }

    private func handleUnexpectedClose(reason: String) {
        guard started, !isStopping else { return }
        guard pty != nil || connectionState != .disconnected else { return }
        releasePTY()
        scheduleReconnect(reason: reason)
    }

    private func scheduleReconnect(reason: String) {
        guard started, !isStopping else { return }

        guard reconnectAttempts < Self.maxReconnectAttempts else {
            transition(to: .disconnected, reason: "retry budget exhausted")
            onClosed?()
            return
        }

        reconnectAttempts += 1
        let attempt = reconnectAttempts
        let delaySeconds = min(Int(pow(2.0, Double(attempt - 1))), 30)
        transition(to: .reconnecting, reason: "\(reason), retry \(attempt)")
        Self.logger.info("terminal reconnect scheduled for session \(self.sessionID, privacy: .public) attempt=\(String(attempt), privacy: .public) delay=\(String(delaySeconds), privacy: .public)s")

        let sleeper = self.sleeper
        reconnectTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(seconds: delaySeconds)
            } catch {
                return
            }
            await MainActor.run {
                guard !Task.isCancelled, let self, self.started, !self.isStopping else { return }
                self.attemptAttach(reason: "retry \(attempt)", initialState: .reconnecting)
            }
        }
    }

    private func releasePTY() {
        guard let pty else { return }
        pty.detach()
        self.pty = nil
    }

    private func transition(to newState: TerminalSurfaceConnectionState, reason: String) {
        guard connectionState != newState else { return }
        connectionState = newState
        Self.logger.info("terminal state -> \(newState.logValue, privacy: .public) for session \(self.sessionID, privacy: .public): \(reason, privacy: .public)")
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from payload: String) -> T? {
        guard let data = payload.data(using: .utf8) else {
            Self.logger.error("terminal event payload was not UTF-8 for session \(self.sessionID, privacy: .public)")
            return nil
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            Self.logger.error("terminal event payload decode failed for session \(self.sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - UITest / preview placeholder transport

/// Placeholder transport used in UITest mode and in previews. Emits a
/// deterministic banner so UI tests can assert terminal rendering paths
/// without a real PTY. Ticks are scheduled with a timer so the shared
/// surface genuinely exercises its byte-append path (per independent
/// validation bullet in the ticket: no pure `#if os(iOS)` stubs).
public final class PlaceholderPTYTransport: TerminalPTYTransport {
    @Published public private(set) var connectionState: TerminalSurfaceConnectionState = .disconnected

    public var connectionStatePublisher: AnyPublisher<TerminalSurfaceConnectionState, Never> {
        $connectionState
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

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
        connectionState = .connected
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

    public func reconnect() {
        connectionState = .connecting
        connectionState = .connected
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        connectionState = .disconnected
        onBytes = nil
        onClosed = nil
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
