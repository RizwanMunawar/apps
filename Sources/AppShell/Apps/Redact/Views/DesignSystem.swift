import SwiftUI

struct RedactCard: ViewModifier {
    let palette: Palette
    var glow = false
    func body(content: Content) -> some View {
        content
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(glow ? palette.accent.opacity(0.5) : palette.border, lineWidth: glow ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(palette.colorScheme == .dark ? 0.22 : 0.06), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func redactCard(_ palette: Palette, glow: Bool = false) -> some View { modifier(RedactCard(palette: palette, glow: glow)) }
}

struct RedactPrimaryButtonStyle: ButtonStyle {
    let palette: Palette
    var isDestructive = false
    @Environment(\.sidebarZoom) private var zoom
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.archivo(13 * zoom, weight: .semibold))
            .foregroundStyle(palette.onAccent)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background {
                if isDestructive {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.textSecondary.opacity(0.85))
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.accent)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(palette.colorScheme == .dark ? 0.08 : 0))
            )
            .shadow(color: palette.accent.opacity(isDestructive ? 0 : 0.3), radius: configuration.isPressed ? 4 : 10, x: 0, y: configuration.isPressed ? 2 : 5)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RedactChipStyle: ButtonStyle {
    let palette: Palette
    var selected: Bool
    @Environment(\.sidebarZoom) private var zoom
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.archivo(12 * zoom, weight: .medium))
            .padding(.horizontal, 12 * zoom)
            .padding(.vertical, 6.5 * zoom)
            .foregroundStyle(selected ? palette.onAccent : palette.textPrimary.opacity(0.72))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.accent)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.surfaceRaised)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? .clear : palette.border))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The same three-line "redacted text" mark used for the app icon, drawn natively so it stays
/// crisp at any size and always matches the icon exactly (no bitmap asset to keep in sync).
struct RedactMark: View {
    let palette: Palette
    var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(.black)
            .frame(width: size, height: size)
            .overlay {
                VStack(spacing: size * 0.11) {
                    Capsule().fill(.white).frame(width: size * 0.5, height: size * 0.13)
                    Capsule().fill(palette.accent).frame(width: size * 0.5, height: size * 0.13)
                    Capsule().fill(.white).frame(width: size * 0.31, height: size * 0.13)
                }
            }
    }
}

struct RedactWordmark: View {
    let palette: Palette
    var body: some View {
        HStack(spacing: 9) {
            RedactMark(palette: palette)
            Text("Redact")
                .font(AppFont.archivo(17, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct StatusPill: View {
    let palette: Palette
    let isRunning: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? palette.accent : palette.textSecondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(isRunning ? "Live" : "Idle")
                .font(AppFont.archivo(11, weight: .medium))
                .foregroundStyle(isRunning ? palette.accent : palette.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.border))
    }
}

struct ThemeToggle: View {
    @ObservedObject var themeManager: ThemeManager
    var body: some View {
        Button {
            themeManager.toggle()
        } label: {
            Image(systemName: themeManager.theme == .dark ? "moon.fill" : "sun.max.fill")
                .font(AppFont.archivo(12, weight: .medium))
                .foregroundStyle(themeManager.palette.textPrimary.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(themeManager.palette.surfaceRaised, in: Circle())
                .overlay(Circle().strokeBorder(themeManager.palette.border))
        }
        .buttonStyle(.plain)
    }
}

extension Text {
    func sectionLabel(_ palette: Palette, zoom: CGFloat = 1.0) -> some View {
        font(AppFont.archivo(10.5 * zoom, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(palette.textSecondary)
            .textCase(.uppercase)
    }
}
