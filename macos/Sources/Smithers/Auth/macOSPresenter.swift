// macOSPresenter.swift — `ASWebAuthenticationSession` presenter anchored
// to the key NSWindow.
//
// Ticket 0109. Counterpart to iOSPresenter. macOS also has `ASWebAuthentication-
// Session` (AuthenticationServices framework, 10.15+).

#if os(macOS)
import AppKit
import AuthenticationServices
#if canImport(SmithersAuth)
import SmithersAuth
#endif

public final class MacOSWebAuthPresenter: AuthorizeSessionPresenter {
    public init() {}

    public func presentationAnchor() -> ASPresentationAnchor? {
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    }
}
#endif
