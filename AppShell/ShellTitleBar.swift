import AppCore
import SwiftUI

/// The full-width chrome strip across the top of the window. With `.hiddenTitleBar` the traffic
/// lights float over our own content, so the leading inset is reserved for them by hand.
///
/// The mark on the left is a button: clicking it goes back to the App Hub, the way a logo in the
/// corner of a website goes home.
struct ShellTitleBar: View {
    let selected: AppID?
    let palette: Palette
    @ObservedObject var themeManager: ThemeManager
    @Binding var inspectorCollapsed: Bool
    let goHome: () -> Void
    /// Just clears the traffic lights. The version badge sits immediately after them, hard into
    /// the corner, because there is nothing else that belongs there.
    private let trafficLightInset: CGFloat = 72

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: trafficLightInset, height: 1)

            // The way back to the app list, now that there isn't one pinned to the side.
            if selected != nil {
                ToolbarIconButton(systemName: "square.grid.2x2", palette: palette, help: "All apps", action: goHome)
            }

            Spacer(minLength: 8)

            Button(action: goHome) {
                HStack(spacing: 10) {
                    ShellMark(size: 22)
                    Text(selected?.name ?? ShellInfo.displayName)
                        .font(AppFont.text(20, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show all apps")
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ThemeToggle(themeManager: themeManager)
                ToolbarIconButton(
                    systemName: inspectorCollapsed ? "sidebar.right" : "sidebar.squares.right",
                    palette: palette,
                    help: inspectorCollapsed ? "Show controls" : "Hide controls"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) { inspectorCollapsed.toggle() }
                }
            }
            .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(palette.surface)
    }
}
