// TerminalView+macOS.swift — ticket 0123.
//
// macOS-only bridge between the shared `TerminalSurface` SwiftUI view
// and the existing libghostty apprt-backed `TerminalSurfaceRepresentable`
// in TerminalView.swift. Keeping the bridge in its own file lets the
// shared `TerminalSurface.swift` stay free of AppKit imports while the
// macOS renderer keeps all of its AppKit affordances (context menus,
// split commands, shortcut interception, desktop clipboard).
//
// Temporary compatibility note: 0120's `SmithersRuntime` currently ships
// a fake transport and does not yet stream real PTY bytes. Until that
// lands, macOS continues to use the existing daemon-backed session
// stack inside `TerminalSurfaceRepresentable`. When the runtime starts
// serving real bytes, the shared `TerminalSurface` on macOS should
// instead drive the renderer via `TerminalSurfaceModel.recentBytes`.
// The fallback path is explicit and easy to delete — see README.

#if os(macOS)
import SwiftUI
import AppKit

/// macOS bridge view. Wraps the existing `TerminalSurfaceRepresentable`
/// so the shared surface can embed it. For now this ignores
/// `TerminalSurfaceModel` because the macOS apprt owns its own decode
/// pipeline; later this will instead forward bytes from the model
/// into `ghostty_surface_read_from_pipe` (see 0092 PoC).
struct TerminalMacOSRendererBridge: View {
    @ObservedObject var model: TerminalSurfaceModel
    var sessionID: String?
    var command: String?
    var workingDirectory: String?

    @ObservedObject private var ghostty = GhosttyApp.shared

    var body: some View {
        Group {
            if let app = ghostty.app {
                GeometryReader { geometry in
                    TerminalSurfaceRepresentable(
                        app: app,
                        sessionId: sessionID,
                        command: command,
                        workingDirectory: workingDirectory,
                        layoutSize: geometry.size,
                        onClose: model.callbacks.onClose,
                        onProcessExited: model.callbacks.onProcessExited,
                        onFocus: model.callbacks.onFocus,
                        onTitleChange: model.callbacks.onTitleChange,
                        onWorkingDirectoryChange: model.callbacks.onWorkingDirectoryChange,
                        onNotification: model.callbacks.onNotification,
                        onBell: model.callbacks.onBell
                    )
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                    Text("Terminal failed to initialize")
                        .font(.system(size: 14))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
#endif
