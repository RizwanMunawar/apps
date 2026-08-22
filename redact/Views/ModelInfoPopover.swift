import AppCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the "i" next to the Redact wordmark opens: the facts about the loaded model, and the
/// controls for swapping in your own. Everything model-related lives here rather than in the
/// title bar, which now shows only the app's name.
struct ModelInfoPopover: View {
    @ObservedObject var viewModel: BlurSessionViewModel
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(AppFont.text(13, weight: .medium))
                    .foregroundStyle(palette.accent)
                Text("Detection model")
                    .font(AppFont.text(14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
            }

            if let info = viewModel.modelInfo {
                VStack(spacing: 9) {
                    DetailRow("Name", info.name, palette: palette)
                    DetailRow("File", info.fileName, palette: palette, monospacedValue: true)
                    DetailRow("Source", info.isBuiltIn ? "Built in" : "Your model", palette: palette)
                    DetailRow("Task", info.task, palette: palette)
                    DetailRow("Classes", "\(info.classCount)", palette: palette)
                    DetailRow("Input size", "\(info.inputSide) x \(info.inputSide)", palette: palette)
                    DetailRow("Size on disk", info.sizeOnDisk, palette: palette)
                    DetailRow("Runs on", "Neural Engine and CPU", palette: palette)
                }
                .padding(12)
                .panelCard(palette)
            } else {
                Text(viewModel.modelStatus ?? "Loading the model")
                    .font(AppFont.text(12.5))
                    .foregroundStyle(palette.textSecondary)
            }

            Divider().overlay(palette.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("Use your own model").sectionLabel(palette)
                Text("Pick an Ultralytics model file. CoreML models load straight away.")
                    .font(AppFont.text(11.5))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The one thing here that depends on the user's machine, so say where it stands
                // before they pick a file rather than after.
                switch viewModel.canConvertModels {
                case .some(true):
                    Label("Ultralytics found, so .pt and .onnx can be converted too.", systemImage: "checkmark.circle.fill")
                        .font(AppFont.text(11))
                        .foregroundStyle(palette.live)
                        .fixedSize(horizontal: false, vertical: true)
                case .some(false):
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Ultralytics isn't installed, so .pt and .onnx can't be converted.", systemImage: "exclamationmark.triangle.fill")
                            .font(AppFont.text(11))
                            .foregroundStyle(palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(ModelImporter.installHint)
                                .font(AppFont.mono(10.5))
                                .foregroundStyle(palette.textPrimary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ModelImporter.installHint, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(palette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                case .none:
                    EmptyView()
                }

                if let status = viewModel.modelStatus {
                    ProgressEllipsis(text: status, fraction: viewModel.modelProgress, palette: palette)
                }

                HStack(spacing: 8) {
                    Button("Choose model file") { pickModel() }
                        .buttonStyle(PrimaryButtonStyle(palette: palette))
                        .disabled(viewModel.isLoadingModel)
                    if viewModel.modelInfo?.isBuiltIn == false {
                        Button("Reset") { Task { await viewModel.useBuiltInModel() } }
                            .buttonStyle(SecondaryButtonStyle(palette: palette))
                            .disabled(viewModel.isLoadingModel)
                    }
                }

                Text("Accepts .pt, .onnx, .mlpackage and .mlmodel")
                    .font(AppFont.text(11))
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func pickModel() {
        guard let url = Self.runModelPicker() else { return }
        Task { await viewModel.loadModel(at: url) }
    }

    /// Shared by the popover and the Model step, so both offer exactly the same file types.
    static func runModelPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // .mlpackage is a directory on disk, so it has to be selectable as a file even though
        // directories are otherwise off.
        panel.treatsFilePackagesAsDirectories = false
        // .pt and .onnx have no system-declared type, so these resolve to dynamic UTIs. Those
        // still filter by extension, which is all the panel needs.
        panel.allowedContentTypes = ModelImporter.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Pick a .pt, .onnx, .mlpackage or .mlmodel file"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
