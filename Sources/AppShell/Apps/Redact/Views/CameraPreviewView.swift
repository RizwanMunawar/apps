import SwiftUI

struct CameraPreviewView: View {
    let image: CGImage?
    let isRunning: Bool
    let palette: Palette

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(palette.surfaceRaised).frame(width: 64, height: 64)
                        Image(systemName: "video.slash")
                            .font(AppFont.archivo(24, weight: .medium))
                            .foregroundStyle(palette.accent)
                    }
                    Text("Start the camera to see a live preview")
                        .font(AppFont.archivo(13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isRunning ? palette.accent.opacity(0.5) : palette.border, lineWidth: isRunning ? 2 : 1)
        )
        .shadow(color: isRunning ? palette.accent.opacity(0.18) : .clear, radius: 24)
        .animation(.easeInOut(duration: 0.3), value: isRunning)
    }
}
