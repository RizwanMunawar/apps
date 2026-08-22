import AppCore
import Redact
import SwiftUI

private enum ShellPhase: Equatable {
    case splash
    case ready
}

/// Window layout: a full-width title bar over whatever is selected, and nothing else.
///
/// There is deliberately no permanent app list down the side. It was a column of chrome
/// duplicating what the App Hub already shows, and every point it took was a point the app inside
/// it did not get. The mark in the title bar goes back to the hub, which is one click from
/// anywhere.
struct ShellRootView: View {
    /// Floor and opening size in one. Resizing up is fine; down is not.
    static let minimumSize = CGSize(width: 1180, height: 752)

    @StateObject private var themeManager = ThemeManager()
    @StateObject private var updateChecker = UpdateChecker()
    @State private var phase: ShellPhase = .splash
    // Defaults to the first registered app so opening the shell drops you straight into something
    // useful; the sidebar and the title-bar mark both go back to the hub.
    @State private var selected: AppID? = AppID.allCases.first
    @State private var inspectorCollapsed = false

    private var palette: Palette { themeManager.palette }

    var body: some View {
        Group {
            switch phase {
            case .splash:
                SplashView(palette: palette)
            case .ready:
                ready
            }
        }
        // The size the app opens at is also the smallest it can be made. Everything is laid out
        // to fit exactly this and then grow: the control bar's columns sit at their declared
        // minimums here, and the canvas still has room for a full 16:9 frame. Any less would
        // start clipping controls, which is the one thing this layout is built not to do.
        .frame(
            minWidth: Self.minimumSize.width, idealWidth: Self.minimumSize.width,
            minHeight: Self.minimumSize.height, idealHeight: Self.minimumSize.height
        )
        .background(WindowSizing(size: Self.minimumSize))
        .background(palette.background)
        .environment(\.palette, palette)
        .preferredColorScheme(palette.colorScheme)
        .animation(.easeInOut(duration: 0.2), value: themeManager.theme)
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            guard phase == .splash else { return }
            withAnimation(.easeInOut(duration: 0.3)) { phase = .ready }
            // Throttled to once a day inside the checker, so this is cheap on every launch.
            await updateChecker.check()
        }
    }

    private var ready: some View {
        VStack(spacing: 0) {
            ShellTitleBar(
                selected: selected,
                palette: palette,
                themeManager: themeManager,
                inspectorCollapsed: $inspectorCollapsed,
                goHome: { withAnimation(.easeInOut(duration: 0.18)) { selected = nil } }
            )
            hairline

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Pinned to the window's own corner rather than living inside any one pane, so it stays
        // put whether the sidebar is showing or not.
        .overlay(alignment: .bottomLeading) {
            VersionBadge(checker: updateChecker, palette: palette)
                .padding(10)
        }
    }

    @ViewBuilder private var content: some View {
        if let selected {
            AppContainer(id: selected, palette: palette, inspectorCollapsed: inspectorCollapsed)
        } else {
            AppHubView(selected: $selected, palette: palette)
        }
    }

    private var hairline: some View {
        Rectangle().fill(palette.border).frame(height: 1)
    }

}

/// Routes an `AppID` to its actual screen. The only place that needs to change when a new app is
/// added, besides the `AppID` case itself in AppCatalog.swift.
private struct AppContainer: View {
    let id: AppID
    let palette: Palette
    let inspectorCollapsed: Bool

    var body: some View {
        switch id {
        case .redact:
            RedactRootView(palette: palette, inspectorCollapsed: inspectorCollapsed)
        }
    }
}
