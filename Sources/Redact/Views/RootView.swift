import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = BlurSessionViewModel()
    @StateObject private var themeManager = ThemeManager()

    private var palette: Palette { themeManager.palette }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 336)
                .background(palette.surface)
            Rectangle().fill(palette.border).frame(width: 1)
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.background)
        .frame(minWidth: 1100, minHeight: 700)
        .preferredColorScheme(palette.colorScheme)
        .animation(.easeInOut(duration: 0.2), value: themeManager.theme)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    RedactWordmark(palette: palette)
                    Spacer()
                    ThemeToggle(themeManager: themeManager)
                    StatusPill(palette: palette, isRunning: viewModel.isRunning)
                }
                .padding(.top, 2)

                controlsCard
                classPickerCard
                if viewModel.sessionBlurTotal > 0 {
                    sessionInsightsCard
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.4)))
                }

                aboutFooter
            }
            .padding(22)
        }
    }

    /// Surfaces what actually happened this session — not just a live count, but which classes
    /// got blurred most and how fast inference ran at its best — instead of a bare control panel.
    private var sessionInsightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This session").sectionLabel(palette)

            HStack(spacing: 12) {
                statTile(value: "\(viewModel.sessionBlurTotal)", label: "Total blurred")
                statTile(value: "\(Int(viewModel.peakFPS))", label: "Peak FPS")
            }

            if !viewModel.topBlurredClasses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.topBlurredClasses, id: \.0.id) { item, count in
                        HStack(spacing: 8) {
                            Image(systemName: item.glyph)
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.accent)
                                .frame(width: 14)
                            Text(item.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.textPrimary.opacity(0.8))
                            Spacer()
                            Text("\(count)")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .redactCard(palette)
    }

    private var aboutFooter: some View {
        HStack(spacing: 6) {
            Text("Redact \(AppInfo.versionString)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            Spacer()
            Link("Source & releases", destination: AppInfo.releaseURL)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(palette.accent)
        }
        .padding(.top, 2)
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                if viewModel.isRunning { viewModel.stop() } else { viewModel.start() }
            } label: {
                Text(viewModel.isRunning ? "Stop camera" : viewModel.isStarting ? "Starting…" : "Start camera")
            }
            .disabled(viewModel.isStarting)
            .buttonStyle(RedactPrimaryButtonStyle(palette: palette, isDestructive: viewModel.isRunning))

            if viewModel.isRunning {
                HStack(spacing: 12) {
                    statTile(value: "\(Int(viewModel.fps))", label: "FPS")
                    statTile(value: "\(viewModel.activeBlurCount)", label: "Blurred")
                }
            }

            Divider().overlay(palette.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("Blur style").sectionLabel(palette)
                HStack(spacing: 6) {
                    ForEach(BlurStyle.allCases) { style in
                        Button(style.rawValue) { viewModel.blurStyle = style }
                            .buttonStyle(RedactChipStyle(palette: palette, selected: viewModel.blurStyle == style))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Blur method").sectionLabel(palette)
                HStack(spacing: 6) {
                    ForEach(BlurMethod.allCases) { method in
                        Button(method.label) { viewModel.blurMethod = method }
                            .buttonStyle(RedactChipStyle(palette: palette, selected: viewModel.blurMethod == method))
                    }
                }
                Text(viewModel.blurMethod.detail)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Strength").sectionLabel(palette)
                    Spacer()
                    Text("\(Int(viewModel.blurStrength))")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.accent)
                }
                Slider(value: $viewModel.blurStrength, in: 4...60)
                    .tint(palette.accent)
            }
        }
        .padding(16)
        .redactCard(palette)
    }

    private var classPickerCard: some View {
        ClassPickerView(viewModel: viewModel, palette: palette)
            .padding(16)
            .redactCard(palette)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(palette.textPrimary)
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.border))
    }

    private var mainContent: some View {
        CameraPreviewView(image: viewModel.previewImage, isRunning: viewModel.isRunning, palette: palette)
            .padding(24)
    }
}
