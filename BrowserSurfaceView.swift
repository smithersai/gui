import SwiftUI
import WebKit

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo = "duckduckgo"
    case google = "google"
    case bing = "bing"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .duckDuckGo:
            return "DuckDuckGo"
        case .google:
            return "Google"
        case .bing:
            return "Bing"
        }
    }

    fileprivate var baseURLString: String {
        switch self {
        case .duckDuckGo:
            return "https://duckduckgo.com/"
        case .google:
            return "https://www.google.com/search"
        case .bing:
            return "https://www.bing.com/search"
        }
    }
}

enum BrowserURLResolver {
    static func url(from rawValue: String, userDefaults: UserDefaults = .standard) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let url = URL(string: value), url.scheme != nil {
            return url
        }

        let lowercased = value.lowercased()
        if lowercased.hasPrefix("localhost")
            || lowercased.hasPrefix("127.0.0.1")
            || value.contains(":") {
            return URL(string: "http://\(value)")
        }

        if value.contains(".") {
            return URL(string: "https://\(value)")
        }

        return searchURL(query: value, userDefaults: userDefaults)
    }

    private static func searchURL(query: String, userDefaults: UserDefaults) -> URL? {
        let configured = userDefaults.string(forKey: AppPreferenceKeys.browserSearchEngine) ?? ""
        let engine = BrowserSearchEngine(rawValue: configured) ?? .duckDuckGo
        var components = URLComponents(string: engine.baseURLString)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

@MainActor
final class BrowserSurfaceRegistry {
    static let shared = BrowserSurfaceRegistry()

    private var webViews: [String: WKWebView] = [:]

    private init() {}

    func webView(for surfaceId: String) -> WKWebView {
        if let existing = webViews[surfaceId] {
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        webViews[surfaceId] = webView
        return webView
    }

    func remove(surfaceId: String) {
        guard let webView = webViews.removeValue(forKey: surfaceId) else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    func contains(surfaceId: String) -> Bool {
        webViews[surfaceId] != nil
    }
}

struct BrowserWebViewRepresentable: NSViewRepresentable {
    let surfaceId: String
    let urlString: String?
    let onTitleChange: (String) -> Void
    let onURLChange: (String) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTitleChange: onTitleChange, onURLChange: onURLChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = BrowserSurfaceRegistry.shared.webView(for: surfaceId)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        loadRequestedURL(in: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.navigationDelegate = context.coordinator
        context.coordinator.onTitleChange = onTitleChange
        context.coordinator.onURLChange = onURLChange
        context.coordinator.attach(to: nsView)
        loadRequestedURL(in: nsView)
    }

    private func loadRequestedURL(in webView: WKWebView) {
        guard let urlString, let url = BrowserURLResolver.url(from: urlString) else { return }
        guard webView.url?.absoluteString != url.absoluteString else { return }
        
        if url.host == "smithers.sh" || url.host == "www.smithers.sh" {
            webView.loadHTMLString(SmithersHomepageWeb.html, baseURL: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onTitleChange: (String) -> Void
        var onURLChange: (String) -> Void
        private weak var observedWebView: WKWebView?
        private var titleObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?

        init(onTitleChange: @escaping (String) -> Void, onURLChange: @escaping (String) -> Void) {
            self.onTitleChange = onTitleChange
            self.onURLChange = onURLChange
        }

        func attach(to webView: WKWebView) {
            guard observedWebView !== webView else { return }
            observedWebView = webView
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                guard let title = webView.title, !title.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.onTitleChange(title)
                }
            }
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                guard let url = webView.url else { return }
                DispatchQueue.main.async {
                    self?.onURLChange(url.absoluteString)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let title = webView.title, !title.isEmpty {
                onTitleChange(title)
            }
            if let url = webView.url {
                onURLChange(url.absoluteString)
            }
        }
    }
}

struct BrowserSurfaceView: View {
    let surface: WorkspaceSurface
    @ObservedObject var workspace: TerminalWorkspace
    var onFocus: () -> Void

    @State private var addressText: String = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            BrowserWebViewRepresentable(
                surfaceId: surface.id,
                urlString: surface.browserURLString,
                onTitleChange: { title in
                    workspace.updateBrowser(surfaceId: surface.id, urlString: nil, title: title)
                },
                onURLChange: { urlString in
                    addressText = urlString
                    workspace.updateBrowser(surfaceId: surface.id, urlString: urlString, title: nil)
                },
                onFocus: onFocus
            )
            .onTapGesture {
                onFocus()
            }
        }
        .onAppear {
            addressText = surface.browserURLString ?? ""
        }
        .onChange(of: surface.browserURLString) { _, newValue in
            if let newValue, newValue != addressText {
                addressText = newValue
            }
        }
        .background(Theme.base)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            BrowserToolbarButton(systemName: "chevron.left", label: "Back") {
                BrowserSurfaceRegistry.shared.webView(for: surface.id).goBack()
            }

            BrowserToolbarButton(systemName: "chevron.right", label: "Forward") {
                BrowserSurfaceRegistry.shared.webView(for: surface.id).goForward()
            }

            BrowserToolbarButton(systemName: "arrow.clockwise", label: "Reload") {
                BrowserSurfaceRegistry.shared.webView(for: surface.id).reload()
            }

            TextField("Search or enter URL", text: $addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .focused($addressFocused)
                .onSubmit {
                    navigate()
                }
                .accessibilityIdentifier("browser.address.\(surface.id)")

            BrowserToolbarButton(systemName: "arrow.right", label: "Go") {
                navigate()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Theme.surface1)
        .border(Theme.border, edges: [.bottom])
    }

    private func navigate() {
        guard let url = BrowserURLResolver.url(from: addressText) else { return }
        let urlString = url.absoluteString
        addressText = urlString
        workspace.updateBrowser(surfaceId: surface.id, urlString: urlString, title: nil)
        
        if url.host == "smithers.sh" || url.host == "www.smithers.sh" {
            BrowserSurfaceRegistry.shared.webView(for: surface.id).loadHTMLString(SmithersHomepageWeb.html, baseURL: url)
        } else {
            BrowserSurfaceRegistry.shared.webView(for: surface.id).load(URLRequest(url: url))
        }
        
        onFocus()
    }
}

private struct BrowserToolbarButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityIdentifier("browser.\(label)")
    }
}
