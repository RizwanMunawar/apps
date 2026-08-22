import AppCore
import SwiftUI

/// Choosing the redaction look by seeing it, rather than by reading two words.
///
/// The sample is drawn rather than photographed: a small face-ish shape put through the same two
/// treatments the pipeline applies. That keeps the app free of stock imagery and, more usefully,
/// means the preview changes with the strength slider so the card shows what you are actually
/// about to get.
struct BlurStyleCards: View {
    @ObservedObject var viewModel: BlurSessionViewModel
    let palette: Palette

    var body: some View {
        HStack(spacing: 7) {
            card(.pixelate, title: "Pixelate", subtitle: "")
            card(.gaussian, title: "Soft blur", subtitle: "")
        }
    }

    private func card(_ style: BlurStyle, title: String, subtitle: String) -> some View {
        let isSelected = viewModel.blurStyle == style
        return Button {
            viewModel.blurStyle = style
        } label: {
            VStack(spacing: 4) {
                SamplePortrait(style: style, strength: viewModel.blurStrength, palette: palette)
                    .frame(height: 46)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(title)
                    .font(AppFont.text(11, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? palette.accent.opacity(0.08) : palette.surfaceRaised.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? palette.accent : palette.border, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// A stand-in face, redacted the way the chosen style would redact it.
private struct SamplePortrait: View {
    let style: BlurStyle
    let strength: Double
    let palette: Palette

    var body: some View {
        ZStack {
            palette.textSecondary.opacity(0.16)

            switch style {
            case .pixelate:
                // Coarser blocks as strength rises, mirroring CIPixellate's input scale.
                let columns = max(3, Int(11 - strength / 8))
                PixelFace(columns: columns, palette: palette)
            case .gaussian:
                Face(palette: palette)
                    .blur(radius: max(1.5, strength / 7))
            }
        }
    }
}

private struct Face: View {
    let palette: Palette

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(Color(red: 0.85, green: 0.72, blue: 0.60))
                .frame(width: 20, height: 20)
            Capsule()
                .fill(palette.accent.opacity(0.75))
                .frame(width: 30, height: 14)
        }
    }
}

/// The same face rendered as flat blocks, which is what pixelation actually does to it.
private struct PixelFace: View {
    let columns: Int
    let palette: Palette

    var body: some View {
        GeometryReader { geometry in
            let cell = geometry.size.width / CGFloat(columns)
            let rows = max(1, Int(geometry.size.height / cell))
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { column in
                            Rectangle()
                                .fill(colour(row: row, column: column, rows: rows))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// A deterministic pattern that reads as a blocked-out head and shoulders: skin tones in the
    /// upper middle, accent below, background elsewhere.
    private func colour(row: Int, column: Int, rows: Int) -> Color {
        let midColumn = Double(columns - 1) / 2
        let horizontal = abs(Double(column) - midColumn) / max(midColumn, 1)
        let vertical = Double(row) / Double(max(rows - 1, 1))

        if vertical < 0.55, horizontal < 0.45 {
            let shade = 0.78 + Double((row * 3 + column * 5) % 4) * 0.04
            return Color(red: shade, green: shade * 0.85, blue: shade * 0.72)
        }
        if vertical >= 0.55, horizontal < 0.7 {
            return palette.accent.opacity(0.55 + Double((row + column) % 3) * 0.1)
        }
        return palette.textSecondary.opacity(0.12)
    }
}
