import SwiftUI

private struct HistoricalOverlayModifier: ViewModifier {
    let isHistorical: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .saturation(isHistorical ? 0.78 : 1.0)
            .colorMultiply(isHistorical ? Color(red: 1.00, green: 0.97, blue: 0.90) : .white)
            .overlay(
                Rectangle()
                    .fill(Color(red: 0.92, green: 0.79, blue: 0.56).opacity(isHistorical ? 0.08 : 0.0))
                    .allowsHitTesting(false)
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHistorical)
    }
}

extension View {
    func historicalOverlay(active: Bool) -> some View {
        modifier(HistoricalOverlayModifier(isHistorical: active))
    }
}
