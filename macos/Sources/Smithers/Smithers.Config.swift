import Foundation
import SwiftUI

enum Smithers {}

extension Smithers {
    enum Readiness: String {
        case loading
        case error
        case ready
    }

    enum ColorScheme {
        case light
        case dark

        init(_ scheme: SwiftUI.ColorScheme) {
            self = scheme == .dark ? .dark : .light
        }
    }
}
