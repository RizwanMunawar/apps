import SwiftUI

public enum AppTheme: String, CaseIterable, Sendable {
    case light, dark
}

/// Every colour the shell and its apps are allowed to use. Both themes are built from the same
/// six roles, so a view written against `Palette` renders correctly in either without branching.
public struct Palette: Sendable {
    /// The wide content pane behind an app's main view.
    public let background: Color
    /// Chrome that frames the content: title bar, left sidebar, right inspector.
    public let surface: Color
    /// A raised element sitting on `surface` — search fields, chips, the selected sidebar row.
    public let surfaceRaised: Color
    /// Hairline rules and 1pt element borders.
    public let border: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let colorScheme: ColorScheme

    // Shared brand identity across both themes: near-neutral chrome, one blue accent — legible
    // on both light and dark surfaces.
    public let accent = Color(red: 0.200, green: 0.475, blue: 0.965)
    public let onAccent = Color.white
    /// Reserved for "this is live / running right now" dots, distinct from `accent` so a
    /// selected-but-idle app never looks active.
    public let live = Color(red: 0.204, green: 0.706, blue: 0.400)
    /// Badge pair for a healthy status: a pale field with dark text on it, which stays legible in
    /// both themes without the solid-fill-plus-white-text look of a button.
    public let badgeBackground = Color(red: 0.816, green: 0.949, blue: 0.859)
    public let badgeText = Color(red: 0.043, green: 0.353, blue: 0.204)
    /// The same badge pair for something that wants attention, e.g. an update waiting to install.
    public let warningBackground = Color(red: 0.996, green: 0.851, blue: 0.839)
    public let warningText = Color(red: 0.561, green: 0.106, blue: 0.086)
    public let warning = Color(red: 0.804, green: 0.204, blue: 0.169)

    /// Warm off-white chrome against pure-white content — the contrast that separates the
    /// sidebar and inspector from the main pane without needing heavy borders.
    public static let light = Palette(
        background: .white,
        surface: Color(red: 0.980, green: 0.980, blue: 0.976),
        surfaceRaised: Color(red: 0.937, green: 0.937, blue: 0.929),
        border: Color.black.opacity(0.085),
        textPrimary: Color(red: 0.106, green: 0.106, blue: 0.098),
        textSecondary: Color(red: 0.478, green: 0.478, blue: 0.459),
        colorScheme: .light
    )

    public static let dark = Palette(
        background: Color(red: 0.039, green: 0.039, blue: 0.043),
        surface: Color(red: 0.071, green: 0.071, blue: 0.078),
        surfaceRaised: Color(red: 0.145, green: 0.145, blue: 0.157),
        border: Color.white.opacity(0.09),
        textPrimary: .white,
        textSecondary: .white.opacity(0.55),
        colorScheme: .dark
    )
}

@MainActor
public final class ThemeManager: ObservableObject {
    // Light is the default: the shell's layout is designed around light chrome, and dark is the
    // opt-in variant rather than the other way round.
    @Published public var theme: AppTheme = .light {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") }
    }

    public var palette: Palette { theme == .dark ? .dark : .light }

    public init() {
        if let saved = UserDefaults.standard.string(forKey: "appTheme"), let restored = AppTheme(rawValue: saved) {
            theme = restored
        }
    }

    public func toggle() {
        theme = theme == .dark ? .light : .dark
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .light
}

public extension EnvironmentValues {
    /// Ambient palette, so deeply nested controls don't each need it threaded through as a
    /// parameter. The shell sets it once at the root.
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
