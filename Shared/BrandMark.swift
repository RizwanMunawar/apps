import SwiftUI

/// The product's logo: a 2x2 grid glyph, drawn transparently with no tile behind it and tinted
/// from the palette, so it comes out light on a dark background and dark on a light one.
///
/// Lives in AppCore rather than the shell because apps put it in their own screens too, and an
/// app is not allowed to import the launcher.
public struct BrandMark: View {
    var size: CGFloat
    /// Overrides the palette tint for the few places sitting on a fixed background regardless of
    /// theme.
    var tint: Color?

    @Environment(\.palette) private var palette

    public init(size: CGFloat = 28, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        let cell = size * 0.42
        let gap = size * 0.14
        VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: cell * 0.22, style: .continuous)
                            .fill(tint ?? palette.textPrimary)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// The product name, as the splash screen sets it. Kept here so apps can show the same lockup
/// without reaching into the shell.
public enum Brand {
    public static let name = "RizwanAI Apps"
}
