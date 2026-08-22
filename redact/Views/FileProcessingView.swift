import AppCore
import SwiftUI

/// The main pane for "Process file". It follows the same four steps as the control panel: drop a
/// file, look at it untouched, watch the blur being applied, then check the result before
/// exporting it.
struct FileProcessingView: View {
    @ObservedObject var viewModel: FileProcessingViewModel
    let palette: Palette
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            palette.surface

            switch viewModel.stage {
            case .empty:
                emptyState
            case .loaded:
                loadedState
            case .processing:
                processingState
            case .done:
                resultState
            case .failed(let message):
                failedState(message: message)
            }

            // Exporting sits on top of whichever state is showing, since the result stays on
            // screen underneath while it is written out.
            if viewModel.isExporting {
                ProcessingAnimation(
                    palette: palette,
                    title: "Please wait",
                    subtitle: viewModel.kind == .video
                        ? "Video export is in progress"
                        : "Image export is in progress",
                    progress: nil
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isExporting)
        // Square corners on purpose: this is the canvas the footage lives on, and a rounded
        // rectangle reads as a widget sitting on the page rather than the page itself.
        .clipShape(Rectangle())
        .overlay(
            Rectangle()
                .strokeBorder(
                    isTargeted ? palette.accent : palette.border,
                    style: StrokeStyle(
                        lineWidth: isTargeted ? 2 : 1,
                        dash: viewModel.stage == .empty ? [7, 5] : []
                    )
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        // Dropping anywhere on the pane works, not just on the empty state's own bounds. A narrow
        // target is the usual reason a drag appears to do nothing.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard !viewModel.isProcessing, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in viewModel.load(url: url) }
            }
            return true
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(palette.surfaceRaised).frame(width: 64, height: 64)
                Image(systemName: "square.and.arrow.down")
                    .font(AppFont.text(23, weight: .medium))
                    .foregroundStyle(palette.accent)
            }
            VStack(spacing: 5) {
                Text(isTargeted ? "Drop to load" : "Drop an image or video here")
                    .font(AppFont.text(16, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text("PNG, JPEG, HEIC, MP4 and MOV. Everything is processed on this device.")
                    .font(AppFont.text(12.5))
                    .foregroundStyle(palette.textSecondary)
            }
            Button("Choose file") { viewModel.pickFile() }
                .buttonStyle(PrimaryButtonStyle(palette: palette))
                .frame(width: 190)
        }
    }

    /// The file exactly as it was picked. Nothing has been blurred yet: the settings are meant to
    /// be dialled in against the real footage first.
    private var loadedState: some View {
        media(url: viewModel.inputURL, image: viewModel.sourceImage)
    }

    private var processingState: some View {
        ZStack {
            // The live frames coming back from the encoder, so the blur is visible behind the
            // card while it runs. Falls back to the source until the first processed frame lands.
            if let frame = viewModel.livePreview {
                imageStage(frame)
            } else if let source = viewModel.sourceImage {
                imageStage(source)
            } else {
                Color.black
            }

            ProcessingAnimation(
                palette: palette,
                title: "Applying redaction",
                subtitle: viewModel.kind == .video ? "Working through the video" : "Working through the image",
                progress: viewModel.progress
            )
        }
    }

    private var resultState: some View {
        media(url: viewModel.resultVideoURL, image: viewModel.resultImage)
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppFont.text(27, weight: .medium))
                .foregroundStyle(Color(red: 0.85, green: 0.28, blue: 0.24))
            Text(message)
                .font(AppFont.text(13.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Start over") { viewModel.reset() }
                .buttonStyle(SecondaryButtonStyle(palette: palette))
                .frame(width: 170)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func media(url: URL?, image: CGImage?) -> some View {
        if viewModel.kind == .video, let url {
            VideoPlayerView(url: url, palette: palette)
        } else if let image {
            imageStage(image)
        } else {
            Color.black
        }
    }

    private func imageStage(_ image: CGImage) -> some View {
        ZStack {
            Color.black
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
