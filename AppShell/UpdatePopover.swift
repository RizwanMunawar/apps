import AppCore
import SwiftUI

/// The contents of the update button in the title bar: what version is installed, what is
/// available, and the button that fetches it.
struct UpdatePopover: View {
    @ObservedObject var checker: UpdateChecker
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(AppFont.text(13, weight: .medium))
                    .foregroundStyle(palette.accent)
                Text("Updates")
                    .font(AppFont.text(14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
            }

            VStack(spacing: 9) {
                DetailRow("Installed", checker.currentVersion, palette: palette, monospacedValue: true)
                if let release = checker.updateAvailable {
                    DetailRow("Latest", release.version, palette: palette, monospacedValue: true)
                }
            }
            .padding(12)
            .panelCard(palette)

            switch checker.state {
            case .checking:
                busy("Checking GitHub")

            case .upToDate:
                Text("You are on the latest version.")
                    .font(AppFont.text(12.5))
                    .foregroundStyle(palette.textSecondary)

            case .available(let release):
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes)
                            .font(AppFont.text(12))
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }
                Button("Download \(release.version)") { checker.download(release) }
                    .buttonStyle(PrimaryButtonStyle(palette: palette))
                Text("The installer lands in Downloads and opens automatically. Drag the app into Applications to finish.")
                    .font(AppFont.text(11))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .downloading(let fraction):
                busy("Downloading")
                ProgressView(value: fraction).progressViewStyle(.linear).tint(palette.accent)

            case .downloaded(let url):
                Text("Downloaded. The installer should have opened.")
                    .font(AppFont.text(12.5))
                    .foregroundStyle(palette.textPrimary)
                Button("Show in Finder") { checker.reveal(url) }
                    .buttonStyle(SecondaryButtonStyle(palette: palette))

            case .failed(let message):
                Text(message)
                    .font(AppFont.text(12))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .idle:
                EmptyView()
            }

            Button("Check now") { Task { await checker.check(force: true) } }
                .buttonStyle(SecondaryButtonStyle(palette: palette))
                .disabled(checker.isBusy)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(AppFont.text(12.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
        }
    }
}
