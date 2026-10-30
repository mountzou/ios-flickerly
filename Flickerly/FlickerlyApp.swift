import SwiftUI
import UIKit
import CoreText

/// The bundled variable font has an ExtraBold default instance; set its axes
/// explicitly so regular/medium/semibold text use their intended weights.
@MainActor
enum AppTypography {
    static let postScriptName = "BricolageGrotesque-96ptExtraBold"

    static func uiFont(size: CGFloat, weight: CGFloat = 400) -> UIFont {
        let descriptor = UIFontDescriptor(name: postScriptName, size: size)
            .addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [
                0x77676874: weight, // wght
                0x77647468: 100, // wdth
                0x6F70737A: min(96, max(12, size)) // opsz
            ]])
        return UIFont(descriptor: descriptor, size: size)
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let value: CGFloat = switch weight {
        case .ultraLight, .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy, .black: 800
        default: 400
        }
        return Font(UIFontMetrics.default.scaledFont(for: uiFont(size: size, weight: value)))
    }
}

@main
struct FlickerlyApp: App {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .dark
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var previews = CatalogPreviewStore()
    @StateObject private var drafts = DraftStore()

    var body: some Scene {
        WindowGroup {
            FilterLibraryView()
                .environmentObject(favorites)
                .environmentObject(previews)
                .environmentObject(drafts)
                .font(AppTypography.font(size: 14))
                .environment(\.locale, Locale(identifier: "en"))
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
