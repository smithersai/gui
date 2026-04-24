#if os(iOS)
import Combine
import Foundation

final class DeepLinkRouter: ObservableObject {
    enum Route: Equatable {
        case oauth2Callback(code: String, state: String)
        case approval(id: String)
        case workspace(uuid: String)
        case unknown
    }

    static let shared = DeepLinkRouter()

    @Published private(set) var route: Route?
    @Published private(set) var lastURL: URL?

    private static let universalLinkHosts: Set<String> = [
        "app.smithers.sh",
        "smithers.ai",
        "www.smithers.ai",
    ]

    private init() {}

    @discardableResult
    func handle(_ url: URL) -> Route {
        let parsedRoute = Self.parse(url)
        lastURL = url
        route = parsedRoute
        return parsedRoute
    }

    func clearRoute(if handledRoute: Route) {
        guard route == handledRoute else { return }
        route = nil
    }

    static func parse(_ url: URL) -> Route {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased()
        else {
            return .unknown
        }

        switch scheme {
        case "smithers":
            return parseSmithersScheme(components)
        case "https":
            return parseUniversalLink(components)
        default:
            return .unknown
        }
    }

    private static func parseSmithersScheme(_ components: URLComponents) -> Route {
        let segments = customSchemeSegments(components)
        return route(from: segments, components: components)
    }

    private static func parseUniversalLink(_ components: URLComponents) -> Route {
        guard let host = components.host?.lowercased(),
              universalLinkHosts.contains(host)
        else {
            return .unknown
        }

        var segments = pathSegments(components)
        if segments.first?.lowercased() == "open" {
            segments.removeFirst()
        }

        return route(from: segments, components: components)
    }

    private static func route(from segments: [String], components: URLComponents) -> Route {
        guard let head = segments.first?.lowercased() else { return .unknown }

        switch head {
        case "oauth2", "auth":
            guard segments.dropFirst().first?.lowercased() == "callback" else {
                return .unknown
            }
            return oauth2Callback(from: components)
        case "approval", "approvals":
            guard let id = segments.dropFirst().first?.trimmedNonEmpty else {
                return .unknown
            }
            return .approval(id: id)
        case "workspace", "workspaces":
            guard let uuid = segments.dropFirst().first?.trimmedNonEmpty else {
                return .unknown
            }
            return .workspace(uuid: uuid)
        default:
            return .unknown
        }
    }

    private static func oauth2Callback(from components: URLComponents) -> Route {
        guard
            let code = queryValue("code", in: components)?.trimmedNonEmpty,
            let state = queryValue("state", in: components)?.trimmedNonEmpty
        else {
            return .unknown
        }
        return .oauth2Callback(code: code, state: state)
    }

    private static func customSchemeSegments(_ components: URLComponents) -> [String] {
        var segments: [String] = []
        if let host = components.host?.trimmedNonEmpty {
            segments.append(host)
        }
        segments.append(contentsOf: pathSegments(components))
        return segments
    }

    private static func pathSegments(_ components: URLComponents) -> [String] {
        components.path
            .split(separator: "/")
            .compactMap { String($0).removingPercentEncoding?.trimmedNonEmpty }
    }

    private static func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
