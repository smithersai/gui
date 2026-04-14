import SwiftUI

struct Theme {
    static let base = Color(hex: "#0F111A")
    static let surface1 = Color(hex: "#141826")
    static let surface2 = Color(hex: "#1A2030")
    static let border = Color.white.opacity(0.08)
    static let sidebarBg = Color(hex: "#0C0E16")
    static let sidebarHover = Color.white.opacity(0.04)
    static let sidebarSelected = Color(hex: "#4C8DFF").opacity(0.12)
    static let pillBg = Color.white.opacity(0.06)
    static let pillBorder = Color.white.opacity(0.10)
    static let pillActive = Color(hex: "#4C8DFF").opacity(0.15)
    static let titlebarBg = Color(hex: "#141826")
    static let titlebarFg = Color.white.opacity(0.70)
    static let bubbleAssistant = Color.white.opacity(0.05)
    static let bubbleUser = Color(hex: "#4C8DFF").opacity(0.12)
    static let bubbleCommand = Color.white.opacity(0.04)
    static let bubbleStatus = Color.white.opacity(0.04)
    static let bubbleDiff = Color.white.opacity(0.05)
    static let inputBg = Color.white.opacity(0.06)
    static let accent = Color(hex: "#4C8DFF")
    static let success = Color(hex: "#34D399")
    static let warning = Color(hex: "#FBBF24")
    static let danger = Color(hex: "#F87171")
    static let info = Color(hex: "#60A5FA")
    static let textPrimary = Color.white.opacity(0.88)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary = Color.white.opacity(0.45)
    
    // Syntax
    static let synKeyword = Color(hex: "#FF5370")
    static let synString = Color(hex: "#C3E88D")
    static let synFunction = Color(hex: "#82AAFF")
    static let synComment = Color(hex: "#676E95")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else {
            self.init(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
            return
        }
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
