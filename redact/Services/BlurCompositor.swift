import CoreImage

/// Applies a blur/pixelate patch over each detection and composites it back onto the original
/// frame, then marks what it covered.
///
/// In `.box` method the patch fills the whole bounding box; in `.mask` method it's
/// additionally clipped to the detection's per-pixel mask via `CIBlendWithMask`, so only the
/// object's silhouette (not its background within the box) gets blurred.
///
/// Every covered region is outlined in the app's accent colour so it's obvious at a glance what
/// was hidden. Box mode draws the full rectangle; mask mode traces the silhouette instead, with
/// no rectangle at all, because a box around a mask defeats the point of having the mask.
public enum BlurCompositor {
    /// Matches `Palette.accent`, as a CoreImage colour. Kept in step by hand because CoreImage
    /// runs far below SwiftUI and can't read the design tokens directly.
    public static let highlight = CIColor(red: 0.200, green: 0.475, blue: 0.965)

    public static func apply(
        _ detections: [Detection], style: BlurStyle, method: BlurMethod, strength: Double, to frame: CIImage
    ) -> CIImage {
        guard !detections.isEmpty else { return frame }
        let extent = frame.extent
        var result = frame

        for detection in detections {
            let rect = CGRect(
                x: extent.origin.x + detection.boundingBox.minX * extent.width,
                y: extent.origin.y + (1 - detection.boundingBox.maxY) * extent.height,
                width: detection.boundingBox.width * extent.width,
                height: detection.boundingBox.height * extent.height
            ).intersection(extent)
            guard !rect.isEmpty, rect.width > 1, rect.height > 1 else { continue }

            let patch: CIImage
            switch style {
            case .pixelate:
                patch = frame.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(4, strength)])
                    .cropped(to: rect)
            case .gaussian:
                patch = frame.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, strength)])
                    .cropped(to: rect)
            }

            if method == .mask, let mask = detection.maskImage {
                let blended = patch.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result.cropped(to: rect),
                    kCIInputMaskImageKey: mask,
                ])
                result = blended.cropped(to: rect).composited(over: result)
                // Segmentation traces the silhouette itself. No bounding box is drawn: the whole
                // point of this mode is that the outline follows the object, not a rectangle
                // around it.
                if let outline = silhouetteOutline(for: mask, in: rect, frameExtent: extent) {
                    result = outline.composited(over: result)
                }
            } else {
                result = patch.composited(over: result)
                result = boxOutline(around: rect).composited(over: result)
            }
        }
        return result.cropped(to: extent)
    }

    // MARK: - Highlights

    /// A complete rectangle around the box, all four sides, drawn as four thin filled bars.
    /// Stroking a path would mean a CoreGraphics round-trip per detection per frame; four crops
    /// of a solid colour stay entirely inside CoreImage.
    private static func boxOutline(around rect: CGRect) -> CIImage {
        // Scale with the box so a small face and a full-frame object both look right, but keep a
        // floor so tiny detections stay visible.
        let thickness = max(1, min(rect.width, rect.height) * 0.01)
        let colour = CIImage(color: highlight)

        let sides = [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness),                 // bottom
            CGRect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness),     // top
            CGRect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height),                // left
            CGRect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height),    // right
        ]

        var marks = CIImage.empty()
        for side in sides {
            marks = colour.cropped(to: side).composited(over: marks)
        }
        return marks
    }

    /// Traces the silhouette by eroding the mask and subtracting the result from the original,
    /// which leaves a thin band lying just *inside* the boundary. Far simpler than extracting
    /// contours, and it follows the shape exactly however complex it is.
    ///
    /// Inside rather than outside on purpose: a dilated band sits beyond the silhouette, which for
    /// a mask that fills its bounding box lands entirely outside the box and is cropped away, so
    /// nothing is drawn at all.
    private static func silhouetteOutline(for mask: CIImage, in rect: CGRect, frameExtent: CGRect) -> CIImage? {
        // Matched to the box outline's own thickness so the two modes mark their edges with the
        // same weight of line, in the same blue.
        let radius = max(1, min(rect.width, rect.height) * 0.01)
        let eroded = mask.applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": radius])
        // CISubtractBlendMode computes background minus input: mask minus its eroded copy.
        let band = eroded.applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: mask,
        ])
        return CIImage(color: highlight)
            .cropped(to: frameExtent)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: band])
            .cropped(to: rect)
    }
}
