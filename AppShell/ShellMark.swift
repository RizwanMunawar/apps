import AppCore
import SwiftUI

/// The shell's logo is just the product mark, which lives in AppCore so apps can draw it too.
typealias ShellMark = BrandMark

/// The mark on a raised rounded tile, for the sidebar and the App Hub grid where every app needs
/// the same footprint.
struct ShellMarkTile: View {
    var size: CGFloat = 40
    @Environment(\.palette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .fill(palette.surfaceRaised)
            .frame(width: size, height: size)
            .overlay(BrandMark(size: size * 0.56))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .strokeBorder(palette.border)
            )
    }
}
