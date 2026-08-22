import SwiftUI

struct RedactRootView: View {
    @StateObject private var viewModel = BlurSessionViewModel()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var zoomManager = ZoomManager()

    private var palette: Palette { themeManager.palette }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 336)
                .background(palette.surface)
                .environment(\.sidebarZoom, zoomManager.scale)
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
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        RedactWordmark(palette: palette)
                        Spacer(minLength: 8)
                        ThemeToggle(themeManager: themeManager)
                    }
                    HStack {
                        ZoomControl(zoomManager: zoomManager, palette: palette)
                        Spacer()
                        StatusPill(palette: palette, isRunning: viewModel.isRunning)
                    }
                }
                .padding(.top, 2)

                controlsCard
                classPickerCard

                if let errorMessage = viewModel.errorMessage {
                    SidebarErrorBanner(message: errorMessage, palette: palette)
                }

                aboutFooter
            }
            .padding(22)
        }
    }

    private var aboutFooter: some View {
        AboutFooter(palette: palette)
    }

    private var controlsCard: some View {
        ControlsCard(viewModel: viewModel, palette: palette)
    }

    private var classPickerCard: some View {
        ClassPickerView(viewModel: viewModel, palette: palette)
            .padding(16)
            .redactCard(palette)
    }

    private var mainContent: some View {
        CameraPreviewView(image: viewModel.previewImage, isRunning: viewModel.isRunning, palette: palette)
            .padding(24)
    }
}

private struct SidebarErrorBanner: View {
    let message: String
    let palette: Palette
    @Environment(\.sidebarZoom) private var zoom

    var body: some View {
        Text(message)
            .zoomedFont(11.5, weight: .medium, zoom: zoom)
            .foregroundStyle(.white)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.4)))
    }
}

private struct AboutFooter: View {
    let palette: Palette
    @Environment(\.sidebarZoom) private var zoom

    var body: some View {
        HStack(spacing: 6) {
            Text("Redact \(AppInfo.versionString)")
                .zoomedFont(10.5, weight: .medium, zoom: zoom)
                .foregroundStyle(palette.textSecondary)
            Spacer()
            Link("Source & releases", destination: AppInfo.releaseURL)
                .zoomedFont(10.5, weight: .semibold, zoom: zoom)
                .foregroundStyle(palette.accent)
        }
        .padding(.top, 2)
    }
}

private struct ControlsCard: View {
    @ObservedObject var viewModel: BlurSessionViewModel
    let palette: Palette
    @Environment(\.sidebarZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * zoom) {
            Button {
                if viewModel.isRunning { viewModel.stop() } else { viewModel.start() }
            } label: {
                Text(viewModel.isRunning ? "Stop camera" : viewModel.isStarting ? "Starting…" : "Start camera")
            }
            .disabled(viewModel.isStarting)
            .buttonStyle(RedactPrimaryButtonStyle(palette: palette, isDestructive: viewModel.isRunning))

            if viewModel.isRunning {
                HStack(spacing: 12) {
                    StatTile(value: "\(Int(viewModel.fps))", label: "FPS", palette: palette)
                    StatTile(value: "\(viewModel.activeBlurCount)", label: "Blurred", palette: palette)
                }
            }

            Divider().overlay(palette.border)

            VStack(alignment: .leading, spacing: 8 * zoom) {
                Text("Blur style").sectionLabel(palette, zoom: zoom)
                HStack(spacing: 6) {
                    ForEach(BlurStyle.allCases) { style in
                        Button(style.rawValue) { viewModel.blurStyle = style }
                            .buttonStyle(RedactChipStyle(palette: palette, selected: viewModel.blurStyle == style))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8 * zoom) {
                Text("Blur method").sectionLabel(palette, zoom: zoom)
                HStack(spacing: 6) {
                    ForEach(BlurMethod.allCases) { method in
                        Button(method.label) { viewModel.blurMethod = method }
                            .buttonStyle(RedactChipStyle(palette: palette, selected: viewModel.blurMethod == method))
                    }
                }
                Text(viewModel.blurMethod.detail)
                    .zoomedFont(10.5, zoom: zoom)
                    .foregroundStyle(palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6 * zoom) {
                HStack {
                    Text("Strength").sectionLabel(palette, zoom: zoom)
                    Spacer()
                    Text("\(Int(viewModel.blurStrength))")
                        .zoomedFont(11.5, weight: .semibold, design: .rounded, zoom: zoom)
                        .foregroundStyle(palette.accent)
                }
                Slider(value: $viewModel.blurStrength, in: 4...60)
                    .tint(palette.accent)
            }
        }
        .padding(16)
        .redactCard(palette)
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let palette: Palette
    @Environment(\.sidebarZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).zoomedFont(17, weight: .bold, design: .rounded, zoom: zoom).foregroundStyle(palette.textPrimary)
            Text(label).zoomedFont(9.5, weight: .medium, zoom: zoom).foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.border))
    }
}
