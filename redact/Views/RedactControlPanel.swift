import AppCore
import SwiftUI

/// Redact's control panel. It reads as a numbered sequence, because that is what using the app
/// actually is: choose a source, choose what to hide, choose how it looks, then run it. Wording is
/// kept to labels and buttons so the panel stays scannable.
/// Redact's controls, down the right-hand side of the window.
///
/// A vertical panel, not a bottom bar: the steps are a sequence, and a column reads as one far
/// more naturally than a row does. Each step is a titled block with room under its heading, and
/// there are no rules between them, because the numbered discs already say where one ends and the
/// next begins.
struct RedactControlPanel: View {
    @Binding var mode: RedactMode
    @ObservedObject var viewModel: BlurSessionViewModel
    @ObservedObject var fileViewModel: FileProcessingViewModel
    let palette: Palette

    static let width: CGFloat = 306

    /// Changing the look mid-run would be a lie: those settings were baked into the job already.
    /// Only applies to file work; the live camera is meant to be adjusted while it runs.
    private var settingsLocked: Bool { mode == .file && fileViewModel.settingsLocked }

    private var sourceState: StepState {
        mode == .live ? .complete : (fileViewModel.inputURL == nil ? .active : .complete)
    }

    private var runState: StepState {
        guard !viewModel.selectedClassIndices.isEmpty else { return .locked }
        guard mode == .live || fileViewModel.inputURL != nil else { return .locked }
        switch mode {
        case .live: return viewModel.isRunning ? .complete : .active
        case .file: return fileViewModel.stage == .done ? .complete : .active
        }
    }

    private var runHint: String? {
        if viewModel.selectedClassIndices.isEmpty { return "Choose what to hide first." }
        switch mode {
        case .live:
            return viewModel.isRunning ? nil : "Your camera stays on this device."
        case .file:
            if fileViewModel.inputURL == nil { return "Choose a file first." }
            return fileViewModel.stage == .done ? nil : "Apply, then export."
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(palette.border).frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    StepSection(
                        1, "What to redact",
                        palette: palette, state: sourceState,
                        hint: mode == .live
                            ? "Your camera, redacted live as you move."
                            : "Pick the video or image you want to redact."
                    ) {
                        SourceStep(mode: $mode, viewModel: viewModel, fileViewModel: fileViewModel, palette: palette)
                    }

                    StepSection(
                        2, "Detection model", palette: palette,
                        state: viewModel.modelInfo == nil ? .active : .complete,
                        hint: "The built-in model knows 80 everyday objects.",
                        isOptional: true
                    ) {
                        ModelStep(viewModel: viewModel, palette: palette)
                    }

                    StepSection(
                        3, "What to hide", palette: palette,
                        state: viewModel.selectedClassIndices.isEmpty ? .active : .complete,
                        hint: viewModel.selectedClassIndices.isEmpty ? "Nothing is selected, so nothing will be covered." : nil
                    ) {
                        HStack(spacing: 12) {
                            InlineButton("All", palette: palette, isProminent: true) { viewModel.selectAllClasses() }
                            InlineButton("Clear", palette: palette) { viewModel.clearAllClasses() }
                        }
                    } content: {
                        ClassTokenField(viewModel: viewModel, palette: palette)
                    }

                    StepSection(
                        4, "Redaction style", palette: palette,
                        state: settingsLocked ? .locked : .complete
                    ) {
                        BlurStep(viewModel: viewModel, palette: palette)
                    }

                    StepSection(
                        5, mode == .live ? "Start redacting" : "Create redacted file",
                        palette: palette, state: runState, hint: runHint
                    ) {
                        RunStep(mode: mode, viewModel: viewModel, fileViewModel: fileViewModel, palette: palette)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage, palette: palette)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(palette.surface)
    }
}

// MARK: - Step 1

private struct SourceStep: View {
    @Binding var mode: RedactMode
    @ObservedObject var viewModel: BlurSessionViewModel
    @ObservedObject var fileViewModel: FileProcessingViewModel
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(RedactMode.allCases) { candidate in
                    Button {
                        mode = candidate
                    } label: {
                        VStack(spacing: 1) {
                            Text(candidate.emoji)
                                .font(.system(size: 22))
                            Text(candidate.shortLabel)
                                .font(AppFont.text(9, weight: .semibold))
                                .foregroundStyle(mode == candidate ? palette.accent : palette.textSecondary)
                        }
                            .frame(width: 62, height: 48)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(mode == candidate ? palette.accent.opacity(0.18) : palette.surfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(mode == candidate ? palette.accent : palette.border)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(candidate.rawValue)
                }

                    Spacer(minLength: 0)
            }

            if mode == .file {
                Button(fileViewModel.inputURL == nil ? "Choose file" : "Change file") {
                    fileViewModel.pickFile()
                }
                .buttonStyle(ChipStyle(palette: palette, selected: false))
                .disabled(fileViewModel.isProcessing)
            }

            if mode == .file, let inputURL = fileViewModel.inputURL {
                HStack(spacing: 7) {
                    Text(fileViewModel.kind == .video ? "🎬" : "🖼️")
                        .font(.system(size: 13))
                    Text(inputURL.lastPathComponent)
                        .font(AppFont.text(11.5, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.live)
                }
                .help(inputURL.path)
            }
        }
    }
}

// MARK: - Step 2

/// Swapping the detection model is its own step because most people never touch it: the app works
/// out of the box, and this is the escape hatch for a custom Ultralytics model.
private struct ModelStep: View {
    @ObservedObject var viewModel: BlurSessionViewModel
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(AppFont.text(12))
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.modelInfo?.name ?? "Loading")
                        .font(AppFont.text(11.5, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(viewModel.modelInfo?.fileName ?? "")
                    if let info = viewModel.modelInfo {
                        // The source moves into the tooltip: the column is too narrow to carry
                        // both without one of them being cut.
                        Text("\(info.classCount) classes")
                            .font(AppFont.text(10))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                            .help(info.isBuiltIn ? "Built in" : "Your model: \(info.fileName)")
                    }
                }
                Spacer(minLength: 0)
                InfoButton(palette: palette, help: "Model details") {
                    ModelInfoPopover(viewModel: viewModel, palette: palette)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .panelCard(palette)

            if let status = viewModel.modelStatus {
                ProgressEllipsis(text: status, fraction: viewModel.modelProgress, palette: palette)
            }

            HStack(spacing: 10) {
                Button("Select") { pickModel() }
                    .buttonStyle(SecondaryButtonStyle(palette: palette))
                    .disabled(viewModel.isLoadingModel)
                if viewModel.modelInfo?.isBuiltIn == false {
                    Button("Reset") { Task { await viewModel.useBuiltInModel() } }
                        .buttonStyle(SecondaryButtonStyle(palette: palette))
                        .disabled(viewModel.isLoadingModel)
                }
            }
        }
    }

    private func pickModel() {
        guard let url = ModelInfoPopover.runModelPicker() else { return }
        Task { await viewModel.loadModel(at: url) }
    }
}

// MARK: - Step 4

private struct BlurStep: View {
    @ObservedObject var viewModel: BlurSessionViewModel
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BlurStyleCards(viewModel: viewModel, palette: palette)

            if viewModel.availableMethods.count > 1 {
                HStack(spacing: 6) {
                    ForEach(viewModel.availableMethods) { method in
                        Button(method.label) { viewModel.blurMethod = method }
                            .buttonStyle(ChipStyle(palette: palette, selected: viewModel.blurMethod == method))
                    }
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Intensity").sectionLabel(palette)
                Slider(value: $viewModel.blurStrength, in: 4...60)
                    .tint(palette.accent)
                    .controlSize(.small)
                HStack {
                    Text("Low")
                    Spacer()
                    Text("High")
                }
                .font(AppFont.text(9.5))
                .foregroundStyle(palette.textSecondary)
            }

            Toggle(isOn: $viewModel.trackingEnabled) {
                Text("Follow objects between frames")
                    .font(AppFont.text(11.5))
                    .foregroundStyle(palette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(palette.accent)
            .controlSize(.mini)
        }
    }
}

// MARK: - Step 4

private struct RunStep: View {
    let mode: RedactMode
    @ObservedObject var viewModel: BlurSessionViewModel
    @ObservedObject var fileViewModel: FileProcessingViewModel
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch mode {
            case .live:
                Button {
                    if viewModel.isRunning { viewModel.stop() } else { viewModel.start() }
                } label: {
                    Text(viewModel.isRunning ? "Stop camera" : viewModel.isStarting ? "Starting" : "Start camera")
                }
                .disabled(viewModel.isStarting || viewModel.isLoadingModel)
                .buttonStyle(PrimaryButtonStyle(palette: palette, isDestructive: viewModel.isRunning))

                if viewModel.isRunning {
                    HStack(spacing: 8) {
                        StatTile(value: "\(Int(viewModel.fps))", label: "FPS", palette: palette)
                        StatTile(value: "\(viewModel.activeBlurCount)", label: "Hidden", palette: palette)
                    }
                }

            case .file:
                HStack(spacing: 10) {
                    Button(fileViewModel.stage == .done ? "Apply again" : "Apply") {
                        fileViewModel.apply()
                    }
                    .buttonStyle(PrimaryButtonStyle(palette: palette))
                    .disabled(!fileViewModel.canApply || viewModel.isLoadingModel)

                    // Export turns itself on the moment a result exists, and Apply turns itself
                    // off while that result is being written.
                    Button("Export") { fileViewModel.export() }
                        .buttonStyle(
                            fileViewModel.canExport
                                ? AnyButtonStyle(PrimaryButtonStyle(palette: palette))
                                : AnyButtonStyle(SecondaryButtonStyle(palette: palette))
                        )
                        .disabled(!fileViewModel.canExport)
                }

            }
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(AppFont.text(18, weight: .bold)).foregroundStyle(palette.accent)
            Text(label).font(AppFont.text(10.5, weight: .medium)).foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(palette)
    }
}

private struct ErrorBanner: View {
    let message: String
    let palette: Palette

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppFont.text(12))
                .foregroundStyle(Color(red: 0.85, green: 0.28, blue: 0.24))
            Text(message)
                .font(AppFont.text(11.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.85, green: 0.28, blue: 0.24).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(red: 0.85, green: 0.28, blue: 0.24).opacity(0.35)))
    }
}
