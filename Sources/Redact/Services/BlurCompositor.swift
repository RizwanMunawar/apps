import CoreImage

/// Applies a blur/pixelate/solid-fill patch over each detection and composites it back onto the
/// original frame. In `.box` method the patch fills the whole bounding box; in `.segmentation`
/// method it's additionally clipped to the detection's per-pixel mask via `CIBlendWithMask`, so
/// only the object's silhouette (not its background within the box) gets blurred.
enum BlurCompositor {
    static func apply(_ detections: [Detection], style: BlurStyle, method: BlurMethod, strength: Double, to frame: CIImage) -> CIImage {
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

            if method == .segmentation, let mask = detection.maskImage {
                let blended = patch.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result.cropped(to: rect),
                    kCIInputMaskImageKey: mask
                ]).cropped(to: rect)
                result = blended.composited(over: result)
            } else {
                result = patch.composited(over: result)
            }
        }
        return result.cropped(to: extent)
    }
}
