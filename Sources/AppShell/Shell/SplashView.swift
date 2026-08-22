import SwiftUI

struct SplashView: View {
    private let palette = Palette.dark
    @State private var visible = false

    var body: some View {
        VStack(spacing: 14) {
            ShellMark(size: 64)
            Text("apps-releases")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
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
