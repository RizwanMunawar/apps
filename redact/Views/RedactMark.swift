import AppCore
import SwiftUI

/// The three-line "redacted text" mark used for Redact's icon, drawn natively so it stays crisp
/// at any size and always matches the icon exactly.
///
/// Transparent like the shell's mark: the bars take their colour from the palette, with the
/// middle one in the accent, so the mark works on a light or a dark surface without a tile behind
/// it. Public because the shell's sidebar and App Hub draw it as Redact's icon.
public struct RedactMark: View {
    var size: CGFloat
    var tint: Color?

    @Environment(\.palette) private var environmentPalette
    private let explicitPalette: Palette?

    public init(palette: Palette? = nil, size: CGFloat = 28, tint: Color? = nil) {
        self.explicitPalette = palette
        self.size = size
        self.tint = tint
    }

    private var palette: Palette { explicitPalette ?? environmentPalette }

    public var body: some View {
        VStack(alignment: .leading, spacing: size * 0.14) {
            Capsule().fill(tint ?? palette.textPrimary).frame(width: size * 0.82, height: size * 0.17)
            Capsule().fill(palette.accent).frame(width: size * 0.82, height: size * 0.17)
            Capsule().fill(tint ?? palette.textPrimary).frame(width: size * 0.5, height: size * 0.17)
        }
        .frame(width: size, height: size)
    }
}

/// Redact's mark on a raised tile, matching the shell's app tiles.
public struct RedactMarkTile: View {
    var size: CGFloat

    @Environment(\.palette) private var palette

    public init(size: CGFloat = 40) { self.size = size }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .fill(palette.surfaceRaised)
            .frame(width: size, height: size)
            .overlay(RedactMark(size: size * 0.55))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .strokeBorder(palette.border)
            )
    }
}

struct RedactWordmark: View {
    let palette: Palette

    var body: some View {
        HStack(spacing: 9) {
            RedactMark(palette: palette, size: 20)
            Text("Redact")
                .font(AppFont.text(16, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize()
        }
    }
}
