import AppCore
import Redact
import SwiftUI

/// The home screen: every app in the shell as a grid of tiles. Reached by clicking the mark in
/// the title bar or the "All apps" row in the sidebar.
struct AppHubView: View {
    @Binding var selected: AppID?
    let palette: Palette

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("App Hub")
                        .font(AppFont.text(30, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text("Focused tools for real work. Everything runs on this device, and nothing you open is sent anywhere.")
                        .font(AppFont.text(13.5))
                        .foregroundStyle(palette.textSecondary)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AppID.allCases) { id in
                        AppTile(id: id, palette: palette) { selected = id }
                    }
                    ComingSoonTile(palette: palette)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }
}

private struct AppTile: View {
    let id: AppID
    let palette: Palette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                mark
                Text(id.name)
                    .font(AppFont.text(14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? palette.surfaceRaised : palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hovering ? palette.accent.opacity(0.6) : palette.border)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(id.tagline)
    }

    @ViewBuilder private var mark: some View {
        switch id {
        case .redact:
            RedactMarkTile(size: 44)
        }
    }
}

private struct ComingSoonTile: View {
    let palette: Palette

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(AppFont.text(20, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.surfaceRaised.opacity(0.5))
                )
            Text("More soon")
                .font(AppFont.text(14, weight: .medium))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}
