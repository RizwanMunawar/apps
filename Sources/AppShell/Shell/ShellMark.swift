import SwiftUI

/// The shell's own logo — a generic 2x2 app-grid glyph, deliberately distinct from any single
/// app's icon (e.g. Redact's black+red text bars). Matches AppIcon/Shell/AppIcon.icns, drawn
/// natively here so it stays crisp at any size without bundling a second bitmap asset.
struct ShellMark: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(.black)
            .frame(width: size, height: size)
            .overlay {
                let cell = size * 0.34
                let gap = size * 0.12
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous).fill(.white.opacity(0.92)).frame(width: cell, height: cell)
                        RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous).fill(.white.opacity(0.92)).frame(width: cell, height: cell)
                    }
                    HStack(spacing: gap) {
                        RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous).fill(.white.opacity(0.92)).frame(width: cell, height: cell)
                        RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous).fill(.white.opacity(0.92)).frame(width: cell, height: cell)
                    }
                }
            }
    }
}
