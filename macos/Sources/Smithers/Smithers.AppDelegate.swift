// Smithers.AppDelegate.swift
//
// macOS app entry point + AppDelegate + SmithersRootView, extracted from
// ContentView.swift in ticket 0122. Lives in the macOS support layer so
// the shared shell code does not own `@main`, does not import AppKit,
// and does not reference `NSApplication`, `NSScreen`, or `NSApp`.
//
// The iOS target has its own `@main` in `ios/Sources/SmithersiOS/SmithersApp.swift`.

#if os(macOS)
import SwiftUI
import AppKit

@main
struct SmithersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var workspaceManager = WorkspaceManager.shared
    // 0126: remote-mode controller lives for the app process lifetime.
    @StateObject private var remoteMode = RemoteModeController.shared

    var body: some Scene {
        WindowGroup {
            SmithersRootView(manager: workspaceManager, remoteMode: remoteMode)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    SmithersApp.handleOpenedURL(url, manager: workspaceManager)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }

    static func handleOpenedURL(_ url: URL, manager: WorkspaceManager) {
        if url.isFileURL {
            manager.openWorkspace(at: url)
            return
        }
        guard url.scheme == "smithers-gui" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
            manager.openWorkspace(at: URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}

struct SmithersRootView: View {
    @ObservedObject var manager: WorkspaceManager
    // 0126: The root view consults the remote-mode controller so it can
    // decide whether to show a remote-only slow-boot overlay over the shell.
    // Local mode is always reachable — remote UX never blocks the user from
    // opening a local folder.
    @ObservedObject var remoteMode: RemoteModeController

    var body: some View {
        Group {
            if let path = manager.activeWorkspacePath {
                ContentView(workspacePath: path)
                    .id(path)
            } else if remoteMode.shouldPresentRemoteShell,
                      remoteMode.isSignedIn {
                // 0126 desktop-remote path: a signed-in user can enter the
                // shell without selecting a local folder first. The remote
                // entry starts on `.workspaces` (sandbox browser). If the
                // first snapshot is still booting, WorkspacesView shows the
                // blocked/slow-boot state instead of blanking the shell.
                ContentView(
                    workspacePath: nil,
                    initialDestination: .workspaces,
                    remoteMode: remoteMode
                )
                .id("remote-shell")
            } else {
                WelcomeView(manager: manager)
            }
        }
        .environmentObject(manager)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        AppLogger.lifecycle.info("Application did finish launching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppDelegate.relocateOffScreenWindows()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppDelegate.relocateOffScreenWindows()
        }
    }

    private static func relocateOffScreenWindows() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        // Fallback target when a window is off every connected screen. Prefer
        // the screen anchored at origin (0, 0) — NSScreen.main can point at a
        // phantom display remembered from a prior multi-monitor setup.
        let anchored = screens.first(where: { $0.frame.origin == .zero })
        guard let fallbackScreen = anchored ?? NSScreen.main else { return }
        let visibleFrame = fallbackScreen.visibleFrame
        for window in NSApp.windows {
            let frame = window.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            let onAnyScreen = screens.contains { $0.visibleFrame.intersects(frame) }
            if onAnyScreen { continue }
            let size = NSSize(
                width: min(frame.width, visibleFrame.width * 0.9),
                height: min(frame.height, visibleFrame.height * 0.9)
            )
            let origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
            AppLogger.ui.info("relocating off-screen window", metadata: [
                "from": "\(frame)",
                "to": "\(NSRect(origin: origin, size: size))"
            ])
            window.setFrame(NSRect(origin: origin, size: size), display: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                SmithersApp.handleOpenedURL(url, manager: WorkspaceManager.shared)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            AppNotifications.shared.stopRunEventMonitoring()
            GhosttyApp.shared.shutdown()
        }
        AppLogger.lifecycle.info("Application will terminate")
    }
}

#endif
