import SwiftUI

/// Typography for the whole shell.
///
/// Uses the system typeface (SF Pro) rather than a bundled one: it is what every other Mac app
/// renders in, it ships with optical sizing and proper hinting at small sizes, and it drops a
/// font file from the bundle. `AppFont` stays as the single funnel so switching again later is
/// one file, not every call site.
public enum AppFont {
    /// Body and UI text.
    public static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Headings, where the tighter tracking of the display face reads better at large sizes.
    public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// For file names, versions, percentages and other values that line up better fixed-width.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
