import SwiftUI
import CoreText

/// Registers the bundled Archivo variable font once at launch, then hands out `Font` values by
/// weight through `AppFont.archivo(_:weight:design:)` everywhere in the app instead of the
/// system font, per the brand's chosen typeface.
enum AppFont {
    private static let registerOnce: Void = {
        guard let url = Bundle.module.url(forResource: "Archivo-Variable", withExtension: "ttf") else { return }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }()

    // No `design` parameter: Archivo has no rounded/monospaced axis, and SwiftUI's `.design`
    // only affects system fonts anyway — irrelevant once we're on a custom typeface.
    static func archivo(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = registerOnce
        return .custom("Archivo", size: size).weight(weight)
    }
}
