import SwiftUI

struct SplashView: View {
    private let palette = Palette.dark
    @State private var visible = false

    var body: some View {
        VStack(spacing: 14) {
            ShellMark(size: 64)
            Text(ShellInfo.displayName)
                .font(AppFont.archivo(18, weight: .semibold))
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
