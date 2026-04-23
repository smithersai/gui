// Smithers.PlatformAdapters.swift
//
// macOS-only AppKit adapters extracted from `ContentView.swift` in ticket
// 0122. The shared shell layer must not `import AppKit`, so any call that
// historically reached into `NSOpenPanel`, `NSWorkspace`, `NSPasteboard`,
// or `NSApplication` now goes through one of the helpers here.

#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

enum PlatformAdapters {
    // MARK: File pickers

    /// Prompt the user for a markdown file. Calls back with the chosen URL
    /// on the main queue. Returns immediately if the user cancels.
    static func presentMarkdownOpenPanel(
        startingAt directoryPath: String,
        completion: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Open Markdown File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let markdownTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }
        panel.allowedContentTypes = markdownTypes.isEmpty ? [.plainText] : markdownTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }
        completion(url)
    }

    // MARK: URL + clipboard

    /// Open a URL (file or remote) via the macOS launch services.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Copy a string to the general pasteboard.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Application lifecycle

    /// Quit the application (AppKit-only). Safe no-op on non-macOS builds.
    static func terminateApp() {
        NSApplication.shared.terminate(nil)
    }

    /// Toggle full-screen on the current key window, if any.
    static func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

#endif
