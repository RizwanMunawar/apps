import AppCore
import SwiftUI

public enum RedactMode: String, CaseIterable, Identifiable {
    case live = "Live camera"
    case file = "Video or image file"
    public var id: String { rawValue }

    /// The word under the chip. Neither mode records anything — recording the app itself is a
    /// separate control in the title bar — so these say plainly what goes *in*.
    var shortLabel: String {
        switch self {
        case .live: return "Camera"
        case .file: return "File"
        }
    }

    /// Emoji rather than an SF Symbol: at chip size it carries further, and the two modes read
    /// apart at a glance without leaning on the label.
    var emoji: String {
        switch self {
        case .live: return "📷"
        case .file: return "🎬"
        }
    }
}

/// Redact's whole screen: the canvas on the left, its controls down the right. The shell supplies
/// the palette and whether the panel is collapsed; everything inside is Redact's own.
public struct RedactRootView: View {
    let palette: Palette
    let inspectorCollapsed: Bool

    // Observed, not owned: the state lives in RedactAppState so navigating away from Redact
    // doesn't tear the running session down with the view.
    @ObservedObject private var state = RedactAppState.shared
    @ObservedObject private var viewModel: BlurSessionViewModel
    @ObservedObject private var fileViewModel: FileProcessingViewModel

    public init(palette: Palette, inspectorCollapsed: Bool) {
        self.palette = palette
        self.inspectorCollapsed = inspectorCollapsed
        viewModel = RedactAppState.shared.session
        fileViewModel = RedactAppState.shared.file
    }

    private var mode: RedactMode { state.mode }

    public var body: some View {
        HStack(spacing: 0) {
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.background)

            if !inspectorCollapsed {
                RedactControlPanel(
                    mode: $state.mode,
                    viewModel: viewModel,
                    fileViewModel: fileViewModel,
                    palette: palette
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Confirming the export belongs at the screen's root, so it shows whichever pane is up.
        .alert(item: $fileViewModel.exportOutcome) { outcome in
            if outcome.succeeded {
                return Alert(
                    title: Text("Export complete"),
                    message: Text("\(outcome.message)\n\n\(outcome.url.lastPathComponent)"),
                    primaryButton: .default(Text("Show in Finder")) { fileViewModel.revealExport() },
                    secondaryButton: .cancel(Text("Done"))
                )
            }
            return Alert(
                title: Text("Export failed"),
                message: Text(outcome.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear { viewModel.setPreviewVisible(true) }
        .onDisappear { viewModel.setPreviewVisible(false) }
        .onChange(of: mode) { _, newMode in
            // Switching to file mode inside Redact does stop the camera: the preview is gone
            // from this screen entirely, unlike navigating to another app where the session is
            // deliberately kept alive.
            if newMode == .file && viewModel.isRunning { viewModel.stop() }
        }
    }

    /// The 16:9 stage, sized from the space it is given rather than from its own contents.
    ///
    /// Laid out inside a `GeometryReader` on purpose. Left to intrinsic sizing, a 16:9 view asks
    /// for the height that matches its full width and drags the whole window up with it, which
    /// pushed the minimum past what a 13-inch display can show. A `GeometryReader` reports no
    /// intrinsic size, so the shell decides how big the window is and the stage fits itself into
    /// whatever is left.
    private var mainPane: some View {
        GeometryReader { geometry in
            let available = CGSize(
                width: max(geometry.size.width - 40, 1),
                height: max(geometry.size.height - 40, 1)
            )
            let width = min(available.width, available.height * 16 / 9)
            let height = width * 9 / 16

            stage
                .frame(width: width, height: height)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder private var stage: some View {
        switch mode {
        case .live:
            CameraPreviewView(image: viewModel.previewImage, isRunning: viewModel.isRunning, palette: palette)
        case .file:
            FileProcessingView(viewModel: fileViewModel, palette: palette)
        }
    }
}
