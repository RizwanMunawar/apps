import AppCore
import SwiftUI

/// The launch screen: the mark on the app's own background, tinted from the palette so it reads
/// white on the dark theme and near-black on the light one.
struct SplashView: View {
    let palette: Palette
    @State private var visible = false

    var body: some View {
        VStack(spacing: 18) {
            ShellMark(size: 72)
            Text(ShellInfo.displayName)
                .font(AppFont.text(20, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.96)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { visible = true }
        }
    }
}
