import AppCore
import SwiftUI

struct CameraPreviewView: View {
    let image: CGImage?
    let isRunning: Bool
    let palette: Palette

    /// Drives a slow breathing glow while running, so the frame itself signals that something is
    /// being analysed rather than just sitting there.
    @State private var pulse = false

    var body: some View {
        ZStack {
            // The stage only goes black once there are actual frames to show. An empty black
            // rectangle would be a hole punched in otherwise light chrome.
            (image == nil ? palette.surface : Color.black)

            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                CameraIntroView(palette: palette)
            }
        }
        // Square corners on purpose: this is the canvas the footage lives on, and a rounded
        // rectangle reads as a widget sitting on the page rather than the page itself.
        .clipShape(Rectangle())
        .overlay(
            Rectangle()
                .strokeBorder(
                    isRunning ? palette.accent.opacity(pulse ? 0.7 : 0.35) : palette.border,
                    lineWidth: isRunning ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .shadow(color: isRunning ? palette.accent.opacity(pulse ? 0.24 : 0.08) : .clear, radius: pulse ? 26 : 14)
        .animation(.easeInOut(duration: 0.3), value: isRunning)
        .onAppear { if isRunning { startPulsing() } }
        .onChange(of: isRunning) { _, running in running ? startPulsing() : (pulse = false) }
    }

    private func startPulsing() {
        pulse = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// The empty state before the camera starts: a small loop of what this app does, and nothing
/// else. A scan line sweeps a figure and the part it has passed comes back blurred, with the same
/// blue box the real output draws.
///
/// No logo or product name here. The stage is where the user's own footage goes, and branding
/// sitting in it is the app talking about itself in the one place that should be about them.
struct CameraIntroView: View {
    let palette: Palette

    @State private var sweep: CGFloat = 0
    @State private var hidden = false

    var body: some View {
        VStack(spacing: 30) {
            stage
                .frame(width: 250, height: 168)

            HStack(spacing: 14) {
                introStep(1, "Pick what to hide")
                introStep(2, "Start the camera")
                introStep(3, "It blurs as you move")
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { sweep = 1 }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { hidden = true }
        }
    }

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(palette.surfaceRaised)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(palette.border)

            figure

            // The scan line, sweeping top to bottom on a loop.
            GeometryReader { geometry in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [palette.accent.opacity(0), palette.accent.opacity(0.85), palette.accent.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
                    .offset(y: geometry.size.height * sweep)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var figure: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(palette.textSecondary.opacity(0.35))
                    .frame(width: 44, height: 44)
                if hidden {
                    // A blurred face, drawn as the coarse pixel grid the pixelate style produces.
                    PixelGrid(columns: 4, rows: 4, palette: palette)
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                        .transition(.opacity)
                }
            }
            .overlay(
                Rectangle()
                    .strokeBorder(palette.accent, lineWidth: 2)
                    .frame(width: 60, height: 60)
            )

            Capsule()
                .fill(palette.textSecondary.opacity(0.35))
                .frame(width: 78, height: 52)
        }
        .offset(y: 6)
    }

    private func introStep(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(AppFont.mono(10, weight: .bold))
                .foregroundStyle(palette.onAccent)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(palette.accent))
            Text(text)
                .font(AppFont.text(11.5, weight: .medium))
                .foregroundStyle(palette.textSecondary)
        }
    }
}

private struct PixelGrid: View {
    let columns: Int
    let rows: Int
    let palette: Palette

    var body: some View {
        GeometryReader { geometry in
            let cellWidth = geometry.size.width / CGFloat(columns)
            let cellHeight = geometry.size.height / CGFloat(rows)
            ForEach(0..<rows, id: \.self) { row in
                ForEach(0..<columns, id: \.self) { column in
                    Rectangle()
                        .fill(palette.textSecondary.opacity(shade(row: row, column: column)))
                        .frame(width: cellWidth, height: cellHeight)
                        .offset(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight)
                }
            }
        }
    }

    /// A fixed pseudo-random pattern: it only has to look like blocky noise, and a deterministic
    /// one keeps the animation from flickering between redraws.
    private func shade(row: Int, column: Int) -> Double {
        let value = (row * 7 + column * 13) % 5
        return 0.3 + Double(value) * 0.09
    }
}
