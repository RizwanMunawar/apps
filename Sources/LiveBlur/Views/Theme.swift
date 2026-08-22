import SwiftUI

enum AppTheme: String, CaseIterable {
    case dark, light
}

struct Palette {
    let background: Color
    let backgroundGradient: LinearGradient
    let surface: Color
    let surfaceRaised: Color
    let border: Color
    let textPrimary: Color
    let textSecondary: Color
    let colorScheme: ColorScheme

    // Shared brand identity across both themes.
    let accentStart = Color(red: 0.388, green: 0.400, blue: 0.965) // indigo
    let accentEnd = Color(red: 0.659, green: 0.333, blue: 0.969)   // violet
    var accent: Color { accentStart }
    var accentGradient: LinearGradient {
        LinearGradient(colors: [accentStart, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    let onAccent = Color.white

    static let dark = Palette(
        background: Color(red: 0.043, green: 0.043, blue: 0.051),
        backgroundGradient: LinearGradient(
            colors: [Color(red: 0.043, green: 0.043, blue: 0.051), Color(red: 0.078, green: 0.055, blue: 0.114)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ),
        surface: Color(red: 0.098, green: 0.098, blue: 0.110),
        surfaceRaised: Color(red: 0.145, green: 0.145, blue: 0.163),
        border: Color.white.opacity(0.08),
        textPrimary: .white,
        textSecondary: .white.opacity(0.55),
        colorScheme: .dark
    )

    static let light = Palette(
        background: Color.white,
        backgroundGradient: LinearGradient(
            colors: [Color.white, Color(red: 0.953, green: 0.949, blue: 0.996)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ),
        surface: Color.white,
        surfaceRaised: Color(red: 0.955, green: 0.953, blue: 0.973),
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
