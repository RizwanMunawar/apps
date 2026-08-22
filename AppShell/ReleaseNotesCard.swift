import AppCore
import AppKit
import SwiftUI

/// What hovering the version badge shows: the latest published release and its notes, pulled
/// straight from GitHub.
///
/// Read-only by design. The badge itself is the control; this is only there to answer "what
/// changed" without leaving the app.
struct ReleaseNotesCard: View {
    @ObservedObject var checker: UpdateChecker
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BrandMark(size: 16)
                Text(ShellInfo.displayName)
                    .font(AppFont.text(13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 8)
                Text(checker.currentVersion)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.badgeText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(palette.badgeBackground))
            }

            Rectangle().fill(palette.border).frame(height: 1)

            if let release = checker.latestRelease {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(isCurrent(release) ? "You are on the latest release" : "Latest release")
                            .font(AppFont.text(11.5, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                        Text(release.version)
                            .font(AppFont.mono(11, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    }

                    if release.notes.isEmpty {
                        Text("No release notes were published for this version.")
                            .font(AppFont.text(12))
                            .foregroundStyle(palette.textSecondary)
                    } else {
                        ScrollView {
                            Text(release.notes)
                                .font(AppFont.text(12))
                                .foregroundStyle(palette.textPrimary.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 190)
                    }

                    if !isCurrent(release) {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(downloadStatus)
                                .font(AppFont.text(11.5, weight: .medium))
                                .foregroundStyle(palette.accent)
                        }
                    }

                    Button("View this release on GitHub") {
                        NSWorkspace.shared.open(release.pageURL)
                    }
                    .buttonStyle(SecondaryButtonStyle(palette: palette))
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching release notes")
                        .font(AppFont.text(12))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            if case .failed(let message) = checker.state {
                Text(message)
                    .font(AppFont.text(11.5))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// What the update is doing, so the panel explains the download it kicked off.
    private var downloadStatus: String {
        switch checker.state {
        case .downloading: return "Downloading the update"
        case .downloaded: return "Downloaded. The installer should have opened."
        default: return "Fetching this update now"
        }
    }

    private func isCurrent(_ release: UpdateChecker.Release) -> Bool {
        !UpdateChecker.isNewer(release.version, than: checker.currentVersion)
    }
}
