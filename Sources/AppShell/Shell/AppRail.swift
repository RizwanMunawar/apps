import SwiftUI

/// The shell's persistent left navigation — a slim, always-visible rail of app icons (styled
/// after a familiar list-+-detail layout: a narrow nav column, a divider, then the selected
/// app's own full interface filling the rest of the window). Distinct from any one app's own
/// internal sidebar (e.g. Redact's control panel), which lives entirely inside `content`.
struct AppRail: View {
    @Binding var selected: AppID?
    private let palette = Palette.dark

    var body: some View {
        VStack(spacing: 14) {
            ShellMark(size: 30)
                .padding(.top, 16)

            Divider().frame(width: 24).overlay(palette.border)

            ForEach(AppID.allCases) { id in
                RailTile(id: id, isSelected: selected == id, palette: palette) {
                    selected = id
                }
            }

            Spacer()
        }
        .frame(width: 68)
        .frame(maxHeight: .infinity)
        .background(palette.surface)
    }
}

private struct RailTile: View {
    let id: AppID
    let isSelected: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                mark
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule().fill(palette.accent).frame(width: 16, height: 2).offset(y: 8)
                        }
                    }
            }
            .frame(width: 44, height: 44)
            .background(isSelected ? palette.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(id.name)
    }

    @ViewBuilder private var mark: some View {
        switch id {
        case .redact:
            RedactMark(palette: palette, size: 30)
        }
    }
}
