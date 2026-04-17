import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

enum MarkdownShellResource {
    static func indexURL() -> URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "MarkdownShell"
        ) {
            return url
        }
        #endif

        if let url = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "MarkdownShell"
        ) {
            return url
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("MarkdownShell", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }

        return nil
    }

    static let fallbackHTML = """
    <!doctype html>
    <html>
    <body>
    <main id="content"></main>
    <script>
    window.smithersMarkdown = {
      setContent: function (content) {
        document.getElementById("content").textContent = content || "";
      }
    };
    </script>
    </body>
    </html>
    """
}

@MainActor
final class MarkdownWebViewRegistry {
    static let shared = MarkdownWebViewRegistry()

    private var webViews: [String: WKWebView] = [:]

    private init() {}

    func webView(for surfaceId: String) -> WKWebView {
        if let existing = webViews[surfaceId] {
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webViews[surfaceId] = webView
        return webView
    }

    func remove(surfaceId: String) {
        guard let webView = webViews.removeValue(forKey: surfaceId) else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    func contains(surfaceId: String) -> Bool {
        webViews[surfaceId] != nil
    }
}

enum MarkdownExternalLinkPolicy {
    static func shouldOpenExternally(
        url: URL?,
        navigationType: WKNavigationType,
        targetFrameIsMainFrame _: Bool
    ) -> Bool {
        guard navigationType == .linkActivated,
              let url,
              let scheme = url.scheme?.lowercased()
        else {
            return false
        }

        if scheme == "about" {
            return false
        }

        if scheme == "file", url.fragment != nil {
            return false
        }

        return true
    }
}

struct MarkdownWebViewRepresentable: NSViewRepresentable {
    let surfaceId: String
    let content: String
    let onOpenExternalURL: (URL) -> Void

    init(
        surfaceId: String,
        content: String,
        onOpenExternalURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.surfaceId = surfaceId
        self.content = content
        self.onOpenExternalURL = onOpenExternalURL
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenExternalURL: onOpenExternalURL)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = MarkdownWebViewRegistry.shared.webView(for: surfaceId)
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadShell(in: webView)
        context.coordinator.render(content: content, in: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.navigationDelegate = context.coordinator
        context.coordinator.onOpenExternalURL = onOpenExternalURL
        context.coordinator.loadShell(in: nsView)
        context.coordinator.render(content: content, in: nsView)
    }

    static func setContentScript(for content: String) -> String {
        let encoded = (try? JSONEncoder().encode(content))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "window.smithersMarkdown.setContent(\(encoded));"
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onOpenExternalURL: (URL) -> Void
        private var isShellReady = false
        private var pendingContent: String?
        private var lastRenderedContent: String?
        private var loadedShellURL: URL?

        init(onOpenExternalURL: @escaping (URL) -> Void) {
            self.onOpenExternalURL = onOpenExternalURL
        }

        func loadShell(in webView: WKWebView) {
            if let indexURL = MarkdownShellResource.indexURL() {
                if loadedShellURL != indexURL {
                    isShellReady = false
                    loadedShellURL = indexURL
                    webView.loadFileURL(
                        indexURL,
                        allowingReadAccessTo: indexURL.deletingLastPathComponent()
                    )
                }
            } else if loadedShellURL == nil {
                isShellReady = false
                loadedShellURL = URL(string: "about:blank")
                webView.loadHTMLString(MarkdownShellResource.fallbackHTML, baseURL: nil)
            }
        }

        func render(content: String, in webView: WKWebView) {
            guard content != lastRenderedContent else { return }
            pendingContent = content
            flushPendingContent(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isShellReady = true
            flushPendingContent(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let targetFrameIsMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            if MarkdownExternalLinkPolicy.shouldOpenExternally(
                url: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                targetFrameIsMainFrame: targetFrameIsMainFrame
            ), let url = navigationAction.request.url {
                onOpenExternalURL(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func flushPendingContent(in webView: WKWebView) {
            guard isShellReady,
                  let pendingContent
            else {
                return
            }

            let script = MarkdownWebViewRepresentable.setContentScript(for: pendingContent)
            lastRenderedContent = pendingContent
            self.pendingContent = nil
            webView.evaluateJavaScript(script)
        }
    }
}

struct MarkdownSurfaceView: View {
    let surface: WorkspaceSurface
    @ObservedObject var workspace: TerminalWorkspace
    var onFocus: () -> Void

    @StateObject private var model: MarkdownSurfaceModel

    init(
        surface: WorkspaceSurface,
        workspace: TerminalWorkspace,
        onFocus: @escaping () -> Void
    ) {
        self.surface = surface
        self.workspace = workspace
        self.onFocus = onFocus
        let filePath = surface.markdownFilePath ?? ""
        _model = StateObject(
            wrappedValue: MarkdownSurfaceRegistry.shared.model(
                for: surface.id.rawValue,
                filePath: filePath
            )
        )
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content

            if model.availability == .retrying {
                Text("Reconnecting file watcher...")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Theme.surface2.opacity(0.94))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .padding(10)
                    .accessibilityIdentifier("markdownSurface.retrying.\(surface.id)")
            }
        }
        .background(Theme.base)
        .onTapGesture(perform: onFocus)
        .onAppear {
            model.reload()
        }
        .accessibilityIdentifier("markdownSurface.\(surface.id)")
    }

    @ViewBuilder
    private var content: some View {
        switch model.availability {
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.75)
                Text("Loading markdown...")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("markdownSurface.loading.\(surface.id)")
        case .unavailable:
            unavailablePlaceholder
        case .available, .retrying:
            MarkdownWebViewRepresentable(
                surfaceId: surface.id.rawValue,
                content: model.content
            )
            .accessibilityIdentifier("markdownSurface.webview.\(surface.id)")
        }
    }

    private var unavailablePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundColor(Theme.warning)
            Text("File unavailable")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text(model.displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("Waiting for the file to reappear.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("markdownSurface.unavailable.\(surface.id)")
    }
}
