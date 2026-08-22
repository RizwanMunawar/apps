import SwiftUI

/// Persisted sidebar text/element scale — a manual zoom independent of the system's Dynamic Type
/// setting, since the user wants a per-app +/- control rather than an OS-wide accessibility change.
@MainActor
final class ZoomManager: ObservableObject {
    static let steps: [CGFloat] = [0.85, 1.0, 1.15, 1.3, 1.45]

    @Published private(set) var scale: CGFloat = 1.0

    init() {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "sidebarZoom"))
        scale = Self.steps.first(where: { abs($0 - saved) < 0.001 }) ?? 1.0
    }

    var canZoomIn: Bool { scale < Self.steps.last! }
    var canZoomOut: Bool { scale > Self.steps.first! }

    func zoomIn() { step(by: 1) }
    func zoomOut() { step(by: -1) }

    private func step(by delta: Int) {
        guard let index = Self.steps.firstIndex(of: scale) else { scale = 1.0; return }
        let newIndex = index + delta
        guard Self.steps.indices.contains(newIndex) else { return }
        scale = Self.steps[newIndex]
        UserDefaults.standard.set(Double(scale), forKey: "sidebarZoom")
    }
}

private struct SidebarZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var sidebarZoom: CGFloat {
        get { self[SidebarZoomKey.self] }
        set { self[SidebarZoomKey.self] = newValue }
    }
}

/// `size` scaled by the ambient sidebar zoom level — shorthand for the font-size multiplication
/// every sidebar text/icon call site needs.
extension View {
    func zoomedFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, zoom: CGFloat) -> some View {
        font(.system(size: size * zoom, weight: weight, design: design))
    }
}

struct ZoomControl: View {
    @ObservedObject var zoomManager: ZoomManager
    let palette: Palette

    var body: some View {
        HStack(spacing: 2) {
            Button {
                zoomManager.zoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .disabled(!zoomManager.canZoomOut)

            Text("\(Int(zoomManager.scale * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(minWidth: 30)
                .foregroundStyle(palette.textSecondary)

            Button {
                zoomManager.zoomIn()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .disabled(!zoomManager.canZoomIn)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textPrimary.opacity(0.85))
        .padding(.horizontal, 3)
        .background(palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.border))
    }
}
