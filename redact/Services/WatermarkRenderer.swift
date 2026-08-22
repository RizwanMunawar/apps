import AppCore
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// The shell's branding baked into exported media: a small mark in the corner of every frame, and
/// an animated outro card on the end of a video.
///
/// Bitmaps are rendered exactly once via CGContext and cached as CIImages. Per-frame work is then
/// only transforms, alpha and compositing, which matters because video needs this on every single
/// frame and a CGContext round-trip per frame would dominate the export.
public enum WatermarkRenderer {
    private static let renderSize: CGFloat = 256

    // MARK: - Per-frame corner mark

    /// The corner mark: the bare 2x2 grid glyph in black, no tile behind it, with a soft light
    /// halo so it stays readable when the footage underneath is dark.
    static let cornerMark: CIImage = glyph(
        fill: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        shadow: CGColor(red: 1, green: 1, blue: 1, alpha: 0.65)
    )

    /// The same glyph in white, for the outro where it sits on flat black.
    static let lightMark: CIImage = glyph(fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1), shadow: nil)

    private static func glyph(fill: CGColor, shadow: CGColor?) -> CIImage {
        guard let context = CGContext(
            data: nil, width: Int(renderSize), height: Int(renderSize), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }

        let rect = CGRect(x: 0, y: 0, width: renderSize, height: renderSize)
        // Proportions mirror the in-app SwiftUI mark: a 2x2 grid of squares each 34% of the side,
        // 12% gaps, square corner radius 28% of a cell.
        let cell = rect.width * 0.34
        let gap = rect.width * 0.12
        let total = cell * 2 + gap
        let originX = rect.minX + (rect.width - total) / 2
        let originY = rect.minY + (rect.height - total) / 2

        if let shadow {
            context.setShadow(offset: .zero, blur: rect.width * 0.055, color: shadow)
        }
        context.setFillColor(fill)
        for row in 0..<2 {
            for col in 0..<2 {
                let x = originX + CGFloat(col) * (cell + gap)
                let y = originY + CGFloat(row) * (cell + gap)
                let squareRect = CGRect(x: x, y: y, width: cell, height: cell)
                let radius = cell * 0.28
                context.addPath(CGPath(roundedRect: squareRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }
        guard let cgImage = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cgImage)
    }

    /// Composites the mark into the bottom-right corner of `frame`, sized relative to the frame's
    /// shorter side so it reads consistently across very different resolutions.
    public static func watermarked(_ frame: CIImage) -> CIImage {
        let extent = frame.extent
        guard extent.width > 1, extent.height > 1 else { return frame }
        let markSize = min(extent.width, extent.height) * 0.09
        let margin = markSize * 0.45
        let scale = markSize / renderSize

        let positioned = cornerMark
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: extent.maxX - markSize - margin,
                y: extent.minY + margin
            ))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.85)])

        return positioned.composited(over: frame)
    }

    // MARK: - Outro

    private static let wordmark: (image: CIImage, size: CGSize) = renderText(Brand.name, fontSize: 128)

    /// One frame of the outro card, at normalised time `progress` through the outro.
    ///
    /// The card mirrors the app's splash screen: mark above, product name below, on flat black.
    /// The mark fades and scales up first, the name follows a beat later, both drift gently
    /// outward through the hold, then the whole thing fades out.
    public static func outroFrame(size: CGSize, progress: Double = 1) -> CIImage {
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: size))

        let markAlpha = easeOut(ramp(progress, from: 0.00, to: 0.20))
        let textAlpha = easeOut(ramp(progress, from: 0.16, to: 0.38))
        let exit = 1 - easeIn(ramp(progress, from: 0.86, to: 1.00))
        // A slow continuous drift over the whole card, so the hold never looks like a freeze.
        let drift = easeOut(min(progress / 0.55, 1))

        let shorter = min(size.width, size.height)
        let markSize = shorter * (0.20 + 0.02 * drift)
        let gap = shorter * 0.075
        let textHeight = shorter * 0.062
        let textWidth = textHeight * (wordmark.size.width / max(wordmark.size.height, 1))
        let blockHeight = markSize + gap + textHeight
        let blockBottom = (size.height - blockHeight) / 2

        var card = background

        // Mark: scales up from slightly small as it fades in.
        let markScale = (0.86 + 0.14 * markAlpha) * markSize / renderSize
        let markDrawn = markSize * (0.86 + 0.14 * markAlpha)
        let mark = lightMark
            .transformed(by: CGAffineTransform(scaleX: markScale, y: markScale))
            .transformed(by: CGAffineTransform(
                translationX: (size.width - markDrawn) / 2,
                y: blockBottom + gap + textHeight + (markSize - markDrawn) / 2
            ))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: markAlpha * exit),
            ])
        card = mark.composited(over: card)

        // Name: rises the last few points into place as it fades in.
        if textAlpha > 0.001, wordmark.size.width > 0 {
            let textScale = textHeight / wordmark.size.height
            let rise = shorter * 0.018 * (1 - textAlpha)
            let text = wordmark.image
                .transformed(by: CGAffineTransform(scaleX: textScale, y: textScale))
                .transformed(by: CGAffineTransform(
                    translationX: (size.width - textWidth) / 2,
                    y: blockBottom - rise
                ))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: textAlpha * exit),
                ])
            card = text.composited(over: card)
        }

        return card.cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: - Text

    /// Draws `string` white on transparent, tightly cropped, so the caller can scale it to
    /// whatever height the frame needs without guessing at metrics.
    private static func renderText(_ string: String, fontSize: CGFloat) -> (image: CIImage, size: CGSize) {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            .kern: fontSize * 0.01,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = fontSize * 0.2
        let width = Int(ceil(bounds.width + padding * 2))
        let height = Int(ceil(bounds.height + padding * 2))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (CIImage.empty(), .zero) }

        context.textPosition = CGPoint(x: padding - bounds.minX, y: padding - bounds.minY)
        CTLineDraw(line, context)
        guard let cgImage = context.makeImage() else { return (CIImage.empty(), .zero) }
        return (CIImage(cgImage: cgImage), CGSize(width: width, height: height))
    }

    // MARK: - Easing

    /// `progress` remapped so `from` is 0 and `to` is 1, clamped outside that window.
    private static func ramp(_ progress: Double, from: Double, to: Double) -> Double {
        guard to > from else { return progress >= to ? 1 : 0 }
        return min(max((progress - from) / (to - from), 0), 1)
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func easeIn(_ t: Double) -> Double { t * t }
}
