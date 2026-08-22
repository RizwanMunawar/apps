import SwiftUI

/// A status line with an animated "..." and a percentage, for work whose progress is known only
/// roughly. The moving dots carry "still going" while the number carries "how far".
public struct ProgressEllipsis: View {
    let text: String
    let fraction: Double
    let palette: Palette

    @State private var dots = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    public init(text: String, fraction: Double, palette: Palette) {
        self.text = text
        self.fraction = fraction
        self.palette = palette
    }

    public var body: some View {
        // No bar: the number is the progress, and a bar next to a figure that only moves in
        // stages just draws attention to how coarse those stages are.
        HStack(spacing: 2) {
            Text(text)
                .font(AppFont.text(11.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            // Fixed-width so the line doesn't shuffle sideways as the dots come and go.
            Text(String(repeating: ".", count: dots))
                .font(AppFont.text(11.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 18, alignment: .leading)
            Spacer(minLength: 6)
            Text("\(Int(fraction * 100))%")
                .font(AppFont.mono(11.5, weight: .bold))
                .foregroundStyle(palette.live)
        }
        .onReceive(timer) { _ in dots = (dots % 4) + 1 }
    }
}

