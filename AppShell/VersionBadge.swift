import AppCore
import SwiftUI

/// The installed version, pinned to the bottom-left corner of the window.
///
/// Not the top-left, because the traffic lights own that corner and anything placed beside them
/// reads as floating in the middle of the toolbar rather than tucked away. The bottom-left is the
/// nearest corner that is genuinely free.
///
/// It doubles as the update control: hovering says what clicking does, clicking opens the release
/// notes and starts fetching anything newer, and the badge itself turns red and pulses when an
/// update is waiting.
struct VersionBadge: View {
    @ObservedObject var checker: UpdateChecker
    let palette: Palette

    @State private var showingNotes = false
    @State private var pulse = false

    private var hasUpdate: Bool { checker.updateAvailable != nil }

    var body: some View {
        Button {
            showingNotes = true
            Task { await checker.checkAndUpdate() }
        } label: {
            HStack(spacing: 5) {
                if checker.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 9, height: 9)
                } else if hasUpdate {
                    // An update sitting uninstalled is the one thing here worth interrupting for.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(hasUpdate ? palette.warningText : palette.badgeText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(hasUpdate ? palette.warningBackground : palette.badgeBackground))
            .overlay(Capsule().strokeBorder(hasUpdate ? palette.warning.opacity(0.5) : .clear))
            .contentShape(Capsule())
            .scaleEffect(hasUpdate && pulse ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .disabled(checker.isBusy)
        .help(hasUpdate ? "An update is ready. Click to install it." : "View this release on GitHub")
        .onHover { hovering in
            // Warm the notes on hover so the panel is already populated when it opens.
            if hovering { Task { await checker.loadReleaseNotesIfNeeded() } }
        }
        .onAppear {
            // A slow breath, so a waiting update catches the eye without nagging.
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .popover(isPresented: $showingNotes, arrowEdge: .top) {
            ReleaseNotesCard(checker: checker, palette: palette)
                .background(palette.surface)
        }
    }

    /// The badge doubles as the status line, since clicking it opens nothing else.
    private var label: String {
        switch checker.state {
        case .checking: return "Checking"
        case .downloading: return "Downloading"
        case .downloaded: return "Installer opened"
        case .available(let release): return "Update to \(release.version)"
        case .idle, .upToDate, .failed: return checker.currentVersion
        }
    }
}
