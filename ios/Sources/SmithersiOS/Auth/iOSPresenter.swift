// iOSPresenter.swift — `ASWebAuthenticationSession` presenter anchored to
// the active UIWindow.
//
// Ticket 0109. Thin shim — all cross-platform logic lives in
// Shared/Sources/SmithersAuth. The custom URL scheme `smithers://oauth2/callback`
// is declared in `ios/Sources/SmithersiOS/Info.plist`.

#if os(iOS)
import UIKit
import AuthenticationServices

public final class iOSWebAuthPresenter: AuthorizeSessionPresenter {
    public init() {}

    public func presentationAnchor() -> ASPresentationAnchor? {
        // Prefer the foreground, key window of the active scene.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let window = scenes
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? scenes.flatMap { $0.windows }.first
        return window ?? ASPresentationAnchor()
    }
}
#endif
