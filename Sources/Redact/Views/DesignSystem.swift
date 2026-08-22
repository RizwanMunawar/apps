import SwiftUI

struct UltraCard: ViewModifier {
    let palette: Palette
    var glow = false
    func body(content: Content) -> some View {
        content
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(glow ? palette.accent.opacity(0.55) : palette.border, lineWidth: glow ? 1.5 : 1)
            )
    }
}

extension View {
    func ultraCard(_ palette: Palette, glow: Bool = false) -> some View { modifier(UltraCard(palette: palette, glow: glow)) }
}

struct UltraPrimaryButtonStyle: ButtonStyle {
    let palette: Palette
    var isDestructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(palette.onAccent)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background {
                if isDestructive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.textSecondary)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.accentGradient)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct UltraChipStyle: ButtonStyle {
    let palette: Palette
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? palette.onAccent : palette.textPrimary.opacity(0.75))
            .background {
                if selected {
                    Capsule().fill(palette.accentGradient)
                } else {
                    Capsule().fill(palette.surfaceRaised)
                }
            }
            .overlay(Capsule().strokeBorder(selected ? .clear : palette.border))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct UltraWordmark: View {
    let palette: Palette
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.accentGradient)
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "aperture").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
            Text("REDACT")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(palette.textPrimary)
        }
    }
}

struct StatusPill: View {
    let palette: Palette
    let isRunning: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? AnyShapeStyle(palette.accentGradient) : AnyShapeStyle(palette.textSecondary.opacity(0.4)))
                .frame(width: 7, height: 7)
            Text(isRunning ? "LIVE" : "IDLE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(isRunning ? palette.accent : palette.textSecondary)
        }
        .padding(.horizontal, 10)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(themeManager.palette.textPrimary)
                .frame(width: 28, height: 28)
                .background(themeManager.palette.surfaceRaised, in: Circle())
                .overlay(Circle().strokeBorder(themeManager.palette.border))
        }
        .buttonStyle(.plain)
    }
}

extension Text {
    func sectionLabel(_ palette: Palette) -> some View {
        font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(palette.textSecondary)
    }
}
