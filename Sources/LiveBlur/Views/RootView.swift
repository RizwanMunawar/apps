import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = BlurSessionViewModel()
    @StateObject private var themeManager = ThemeManager()

    private var palette: Palette { themeManager.palette }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)
                .background(palette.surface)
            Rectangle().fill(palette.border).frame(width: 1)
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.backgroundGradient)
        .frame(minWidth: 1080, minHeight: 680)
        .preferredColorScheme(palette.colorScheme)
        .animation(.easeInOut(duration: 0.2), value: themeManager.theme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                UltraWordmark(palette: palette)
                Spacer()
                ThemeToggle(themeManager: themeManager)
                StatusPill(palette: palette, isRunning: viewModel.isRunning)
            }
            .padding(.top, 4)

            controls
            Rectangle().fill(palette.border).frame(height: 1)
            ClassPickerView(viewModel: viewModel, palette: palette)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.4)))
            }
        }
        .padding(20)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                if viewModel.isRunning { viewModel.stop() } else { viewModel.start() }
            } label: {
                Text(viewModel.isRunning ? "Stop camera" : viewModel.isStarting ? "Starting…" : "Start camera")
            }
            .disabled(viewModel.isStarting)
            .buttonStyle(UltraPrimaryButtonStyle(palette: palette, isDestructive: viewModel.isRunning))

            VStack(alignment: .leading, spacing: 8) {
                Text("BLUR STYLE").sectionLabel(palette)
                HStack(spacing: 6) {
                    ForEach(BlurStyle.allCases) { style in
                        Button(style.rawValue) { viewModel.blurStyle = style }
                            .buttonStyle(UltraChipStyle(palette: palette, selected: viewModel.blurStyle == style))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("BLUR METHOD").sectionLabel(palette)
                HStack(spacing: 6) {
                    ForEach(BlurMethod.allCases) { method in
                        Button(method.label) { viewModel.blurMethod = method }
                            .buttonStyle(UltraChipStyle(palette: palette, selected: viewModel.blurMethod == method))
                    }
                }
                Text(viewModel.blurMethod.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("STRENGTH").sectionLabel(palette)
                    Spacer()
                    Text("\(Int(viewModel.blurStrength))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.accent)
                }
                Slider(value: $viewModel.blurStrength, in: 4...60)
                    .tint(palette.accent)
            }

            if viewModel.isRunning {
                HStack(spacing: 16) {
                    statTile(value: "\(Int(viewModel.fps))", label: "FPS")
                    statTile(value: "\(viewModel.activeBlurCount)", label: "BLURRED")
                }
            }
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(palette.textPrimary)
            Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.6).foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ultraCard(palette)
    }

    private var mainContent: some View {
        CameraPreviewView(image: viewModel.previewImage, isRunning: viewModel.isRunning, palette: palette)
            .padding(24)
    }
}
