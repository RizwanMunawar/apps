import AppCore
import SwiftUI

/// The "something is happening" card, shown in the middle of the preview pane.
///
/// Used for both long jobs, so applying a blur and exporting the result look like the same kind
/// of thing rather than two unrelated states. It sits over whatever the pane is already showing
/// instead of covering the window, so the footage stays visible behind it.
struct ProcessingAnimation: View {
    let palette: Palette
    let title: String
    let subtitle: String
    /// Nil while there is nothing meaningful to measure, as during a file write.
    var progress: Double?

    @State private var spin = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(palette.border, lineWidth: 3)
                    .frame(width: 54, height: 54)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 54, height: 54)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                BrandMark(size: 20)
                    .opacity(pulse ? 1 : 0.45)
            }

            VStack(spacing: 5) {
                Text(title)
                    .font(AppFont.text(15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(subtitle)
                    .font(AppFont.text(12.5))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let progress {
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(palette.accent)
                        .frame(width: 190)
                    Text("\(Int(progress * 100))%")
                        .font(AppFont.mono(11, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                }
            } else {
                AnimatedDots(palette: palette)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        // Translucent so the frame underneath stays readable, but backed by a material rather
        // than a flat 50% fill: over dark footage a half-transparent light surface turns mid-grey,
        // and the light theme's near-black text disappears into it. A material re-tints itself to
        // the current appearance, so the label keeps its contrast either way.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(palette.surface.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.border)
        )
        .shadow(color: .black.opacity(0.25), radius: 26, y: 8)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Three dots taking it in turns, so a card with no measurable progress is still visibly alive.
private struct AnimatedDots: View {
    let palette: Palette
    @State private var active = 0

    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == active ? palette.accent : palette.textSecondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .scaleEffect(index == active ? 1.25 : 1)
                    .animation(.easeInOut(duration: 0.2), value: active)
            }
        }
        .onReceive(timer) { _ in active = (active + 1) % 3 }
    }
}
