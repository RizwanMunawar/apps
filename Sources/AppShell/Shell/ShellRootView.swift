import SwiftUI

private enum ShellPhase: Equatable {
    case splash
    case ready
}

struct ShellRootView: View {
    @State private var phase: ShellPhase = .splash
    // Defaults to the first registered app so opening the shell drops you straight into
    // something useful; the rail lets you switch once more apps exist.
    @State private var selected: AppID? = AppID.allCases.first

    var body: some View {
        Group {
            switch phase {
            case .splash:
                SplashView()
            case .ready:
                HStack(spacing: 0) {
                    AppRail(selected: $selected)
                    Divider().overlay(Palette.dark.border)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            guard phase == .splash else { return }
            withAnimation(.easeInOut(duration: 0.3)) { phase = .ready }
        }
    }

    @ViewBuilder private var content: some View {
        if let selected {
            AppContainer(id: selected)
        } else {
            EmptySelectionView()
        }
    }
}

/// Routes an `AppID` to its actual screen. The only place that needs to change when a new app
/// is added, besides the `AppID` case itself in AppCatalog.swift.
private struct AppContainer: View {
    let id: AppID

    var body: some View {
        switch id {
        case .redact:
            RedactRootView()
        }
    }
}

private struct EmptySelectionView: View {
    private let palette = Palette.dark
    var body: some View {
        VStack(spacing: 10) {
            ShellMark(size: 36)
            Text("Pick an app from the left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }
}
