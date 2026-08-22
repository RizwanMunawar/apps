import SwiftUI

// MARK: - Containers

/// A flat, hairline-bordered block used to group related controls inside a panel. Deliberately
/// shadowless: the layout separates regions with 1pt rules and surface tints, not floating cards,
/// and a drop shadow on light chrome reads as noise.
public struct PanelCard: ViewModifier {
    let palette: Palette
    var highlighted = false

    public func body(content: Content) -> some View {
        content
            .background(palette.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(highlighted ? palette.accent.opacity(0.55) : palette.border, lineWidth: 1)
            )
    }
}

public extension View {
    func panelCard(_ palette: Palette, highlighted: Bool = false) -> some View {
        modifier(PanelCard(palette: palette, highlighted: highlighted))
    }
}

/// Whether a step can be used yet. Declared outside `StepSection` so callers can name it without
/// spelling out the view's generic parameters.
public enum StepState {
    /// Not usable yet, because an earlier step has not been done.
    case locked
    /// Usable, and not yet done.
    case active
    /// Done, and still editable.
    case complete
}

/// One step in a sequence.
///
/// A numbered disc, a title, and the controls for that step. The disc turns green once the step
/// is satisfied, so the panel answers "where am I up to" at a glance without having to read it.
/// Steps that aren't reachable yet are dimmed and inert.
public struct StepSection<Content: View, Trailing: View>: View {
    let number: Int
    let title: String
    let palette: Palette
    var state: StepState
    /// Shown under the title while the step is unfinished.
    var hint: String?
    /// Marks a step you can skip, so it's clear the sequence still works without it.
    var isOptional: Bool
    private let content: () -> Content
    /// Actions that belong to this step and are short enough to sit on its title line.
    private let trailing: () -> Trailing

    public init(
        _ number: Int, _ title: String, palette: Palette, state: StepState = .active,
        hint: String? = nil, isOptional: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.number = number
        self.title = title
        self.palette = palette
        self.state = state
        self.hint = hint
        self.isOptional = isOptional
        self.trailing = trailing
        self.content = content
    }

    public var body: some View {
        // The gap under the heading is deliberately larger than the gaps inside the content, so
        // each step reads as a titled block rather than one continuous list of controls.
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    disc
                    Text(title)
                        .font(AppFont.text(13.5, weight: .semibold))
                        .foregroundStyle(state == .locked ? palette.textSecondary : palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isOptional {
                        Text("Optional")
                            .font(AppFont.text(9.5, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    trailing()
                }

                if let hint {
                    Text(hint)
                        .font(AppFont.text(11))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 35)
                }
            }

            content()
                .padding(.leading, 35)
        }
        .opacity(state == .locked ? 0.45 : 1)
        .disabled(state == .locked)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    /// Green once the step is done. Colour alone carries it: a glyph swap at this size is easy to
    /// miss, and the number is still worth keeping visible so the sequence stays readable.
    private var disc: some View {
        let done = state == .complete
        return Text("\(number)")
            .font(AppFont.text(13, weight: .bold))
            .foregroundStyle(done ? .white : palette.textSecondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(done ? palette.live : palette.surfaceRaised))
            .overlay(Circle().strokeBorder(done ? .clear : palette.border))
    }
}

// MARK: - Fields

/// The rounded, tinted search field that heads the sidebar and the class list.
public struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    let palette: Palette

    public init(_ placeholder: String, text: Binding<String>, palette: Palette) {
        self.placeholder = placeholder
        _text = text
        self.palette = palette
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(AppFont.text(12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(AppFont.text(13))
                .foregroundStyle(palette.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppFont.text(11))
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.border))
    }
}

/// A button that reads like a form field and opens a popover: the dropdown shape used for the
/// class picker, which would otherwise be a 80-row list wedged into the panel.
public struct DropdownButton<Content: View>: View {
    let label: String
    let systemImage: String
    let palette: Palette
    @Binding var isPresented: Bool
    private let content: () -> Content

    public init(
        label: String, systemImage: String, palette: Palette, isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.systemImage = systemImage
        self.palette = palette
        _isPresented = isPresented
        self.content = content
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(AppFont.text(12))
                    .foregroundStyle(palette.accent)
                Text(label)
                    .font(AppFont.text(13, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(AppFont.text(10, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.border))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content().background(palette.surface)
        }
    }
}

// MARK: - Buttons

public struct PrimaryButtonStyle: ButtonStyle {
    let palette: Palette
    var isDestructive = false

    public init(palette: Palette, isDestructive: Bool = false) {
        self.palette = palette
        self.isDestructive = isDestructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.text(13.5, weight: .semibold))
            .foregroundStyle(palette.onAccent)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isDestructive ? Color(red: 0.85, green: 0.28, blue: 0.24) : palette.accent)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The quiet counterpart to `PrimaryButtonStyle`: same metrics, surface fill instead of accent.
public struct SecondaryButtonStyle: ButtonStyle {
    let palette: Palette

    public init(palette: Palette) { self.palette = palette }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.text(13.5, weight: .semibold))
            .foregroundStyle(palette.textPrimary)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.border))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Lets a single button swap between styles as its state changes, which `ButtonStyle` otherwise
/// makes awkward because the two styles are different types.
public struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    public init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    public func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// Segmented-looking pill used for mutually exclusive options such as blur style or method.
public struct ChipStyle: ButtonStyle {
    let palette: Palette
    var selected: Bool

    public init(palette: Palette, selected: Bool) {
        self.palette = palette
        self.selected = selected
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.text(12.5, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(selected ? palette.onAccent : palette.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? palette.accent : palette.surfaceRaised)
            )
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(selected ? .clear : palette.border))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A borderless square glyph button, used for the small controls in the toolbars.
public struct ToolbarIconButton: View {
    let systemName: String
    let palette: Palette
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    public init(systemName: String, palette: Palette, help: String = "", action: @escaping () -> Void) {
        self.systemName = systemName
        self.palette = palette
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppFont.text(13.5, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? palette.surfaceRaised : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A borderless text action, sized to its label. Used on a step's title line where a full
/// button would out-weigh the heading it sits beside.
public struct InlineButton: View {
    let title: String
    let palette: Palette
    var isProminent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, palette: Palette, isProminent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.palette = palette
        self.isProminent = isProminent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.text(11.5, weight: .semibold))
                .foregroundStyle(isProminent ? palette.accent : palette.textSecondary)
                .opacity(isEnabled ? 1 : 0.4)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// An "i" button that opens a popover. Used for the model details, so facts about the model live
/// one click away instead of taking up permanent space in the chrome.
public struct InfoButton<Content: View>: View {
    let palette: Palette
    var help: String = "Details"
    @State private var isPresented = false
    private let content: () -> Content

    public init(palette: Palette, help: String = "Details", @ViewBuilder content: @escaping () -> Content) {
        self.palette = palette
        self.help = help
        self.content = content
    }

    public var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(AppFont.text(13, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content().background(palette.surface)
        }
    }
}

// MARK: - Status

public struct ThemeToggle: View {
    @ObservedObject var themeManager: ThemeManager

    public init(themeManager: ThemeManager) { self.themeManager = themeManager }

    public var body: some View {
        ToolbarIconButton(
            systemName: themeManager.theme == .dark ? "moon.fill" : "sun.max.fill",
            palette: themeManager.palette,
            help: themeManager.theme == .dark ? "Switch to light" : "Switch to dark"
        ) {
            themeManager.toggle()
        }
    }
}

// MARK: - Text

public extension Text {
    /// Uppercase tracked label heading a group of controls.
    func sectionLabel(_ palette: Palette) -> some View {
        font(AppFont.text(10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(palette.textSecondary)
            .textCase(.uppercase)
    }
}

/// One "Label    Value" row, for the model details popover.
public struct DetailRow: View {
    let label: String
    let value: String
    let palette: Palette
    var monospacedValue = false

    public init(_ label: String, _ value: String, palette: Palette, monospacedValue: Bool = false) {
        self.label = label
        self.value = value
        self.palette = palette
        self.monospacedValue = monospacedValue
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(AppFont.text(12))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospacedValue ? AppFont.mono(11.5) : AppFont.text(12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
