import Foundation
import SwiftUI
import CSmithersKit

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

        var cValue: smithers_color_scheme_e {
            switch self {
            case .light: return SMITHERS_COLOR_SCHEME_LIGHT
            case .dark: return SMITHERS_COLOR_SCHEME_DARK
            }
        }

        init(_ scheme: SwiftUI.ColorScheme) {
            self = scheme == .dark ? .dark : .light
        }
    }
}
