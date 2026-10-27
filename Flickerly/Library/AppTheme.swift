import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    static let storageKey = "appearanceTheme"

    case light
    case dark

    var id: String { rawValue }
    var title: String { self == .light ? "Light" : "Dark" }
    var symbol: String { self == .light ? "sun.max" : "moon" }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

/// Adaptive chrome only; photo pixels and filter rendering are independent of appearance.
enum Palette {
    static let background = monochrome(light: 1, dark: 0)
    static let surface = monochrome(light: 0.95, dark: 0.09)
    static let ink = monochrome(light: 0, dark: 1)
    static let muted = monochrome(light: 0.40, dark: 0.60)
    static let accent = ink

    private static func monochrome(light: CGFloat, dark: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? dark : light, alpha: 1)
        })
    }
}
