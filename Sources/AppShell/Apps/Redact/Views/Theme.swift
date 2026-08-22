import SwiftUI

enum AppTheme: String, CaseIterable {
    case dark, light
}

struct Palette {
    let background: Color
    let surface: Color
    let surfaceRaised: Color
    let border: Color
    let textPrimary: Color
    let textSecondary: Color
    let colorScheme: ColorScheme

    // Shared brand identity across both themes: flat graphite UI, one blue accent — legible on
    // both light and dark surfaces.
    let accent = Color(red: 0.200, green: 0.475, blue: 0.965)
    let onAccent = Color.white

    static let dark = Palette(
        background: Color(red: 0.039, green: 0.039, blue: 0.043),
        surface: Color(red: 0.071, green: 0.071, blue: 0.078),
        surfaceRaised: Color(red: 0.110, green: 0.110, blue: 0.120),
        border: Color.white.opacity(0.08),
        textPrimary: .white,
        textSecondary: .white.opacity(0.55),
        colorScheme: .dark
    )

    static let light = Palette(
        background: Color.white,
        surface: Color.white,
        surfaceRaised: Color(red: 0.960, green: 0.960, blue: 0.963),
        border: Color.black.opacity(0.08),
        textPrimary: .black,
        textSecondary: .black.opacity(0.55),
        colorScheme: .light
    )
}

@MainActor
final class ThemeManager: ObservableObject {
    @Published var theme: AppTheme = .dark {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") }
    }

    var palette: Palette { theme == .dark ? .dark : .light }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "appTheme"), let restored = AppTheme(rawValue: saved) {
            theme = restored
        }
    }

    func toggle() {
        theme = theme == .dark ? .light : .dark
    }
}
