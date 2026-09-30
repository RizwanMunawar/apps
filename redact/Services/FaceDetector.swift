import CoreImage
import Foundation
import Vision

/// Finds faces with Apple's built-in Vision face detector, so "Face" can be offered beside
/// whatever the YOLO model detects without shipping or converting a second model. COCO has no
/// face class, and blurring a whole person to hide one face covers far more than it needs to.
///
/// Like `YOLODetector`, it is only ever driven from one serial queue, so the request object is
/// reused across frames rather than rebuilt per call.
final class FaceDetector {
    /// Class index reported for faces. Negative so it can never collide with a model's own
    /// classes, which are numbered from 0.
    static let classIndex = -1
    static let className = "face"

    /// Lower than YOLO's threshold on purpose: for redaction a missed face is far worse than a
    /// patch over something that wasn't one.
    private static let confidenceThreshold: Float = 0.3

    private let request = VNDetectFaceRectanglesRequest()

    /// - Parameter upright: the transform that turns `frame` the right way up. Video files store
    ///   frames in the sensor's orientation (a portrait phone clip is sideways in the buffer), and
    ///   Vision only finds faces reliably when they are upright, so it looks at the rotated frame
    ///   and the boxes are mapped back into the buffer's own space afterwards.
    /// - Parameter includeMasks: when true, each face also gets an oval mask, so Mask mode covers
    ///   the face's own shape instead of the corners of its box.
    func detect(in frame: CIImage, upright: CGAffineTransform, includeMasks: Bool) -> [Detection] {
        let rotated = frame.transformed(by: upright)
        let handler = VNImageRequestHandler(ciImage: rotated, options: [:])
        guard (try? handler.perform([request])) != nil, let faces = request.results else { return [] }

        let frameExtent = frame.extent
        let rotatedExtent = rotated.extent
        let backToFrame = upright.inverted()

        return faces.compactMap { face in
            guard face.confidence >= Self.confidenceThreshold else { return nil }
            // Vision's box is normalized with a bottom-left origin, the same way up as CoreImage.
            let box = face.boundingBox
            let uprightRect = Self.padded(CGRect(
                x: rotatedExtent.minX + box.minX * rotatedExtent.width,
                y: rotatedExtent.minY + box.minY * rotatedExtent.height,
                width: box.width * rotatedExtent.width,
                height: box.height * rotatedExtent.height
            ))
            let inFrame = uprightRect.applying(backToFrame)
            let clipped = inFrame.intersection(frameExtent)
            guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }

            // `Detection.boundingBox` is normalized with a top-left origin.
            let normalized = CGRect(
                x: (clipped.minX - frameExtent.minX) / frameExtent.width,
                y: 1 - (clipped.maxY - frameExtent.minY) / frameExtent.height,
                width: clipped.width / frameExtent.width,
                height: clipped.height / frameExtent.height
            )
            // The oval uses the unclipped rect so a face at the frame's edge keeps its shape
            // rather than being squashed to fit.
            let mask = includeMasks ? Self.ovalMask(in: inFrame, frameExtent: frameExtent) : nil
            return Detection(
                classIndex: Self.classIndex, confidence: face.confidence,
                boundingBox: normalized, maskImage: mask
            )
        }
    }

    /// Vision's box runs roughly from eyebrows to chin. Grow it so hair, forehead, ears and jaw
    /// are covered too, with most of the extra height going upward (CoreImage's y points up).
    private static func padded(_ rect: CGRect) -> CGRect {
        let extraWidth = rect.width * 0.3
        return CGRect(
            x: rect.minX - extraWidth / 2,
            y: rect.minY - rect.height * 0.1,
            width: rect.width + extraWidth,
            height: rect.height * 1.45
        )
    }

    /// A white oval filling `rect` on black, in the frame's CoreImage space: the same shape of
    /// input `BlurCompositor` expects from a segmentation mask.
    private static func ovalMask(in rect: CGRect, frameExtent: CGRect) -> CIImage? {
        // A radial gradient with a 2-point falloff is a hard-edged disc; scaling it by different
        // amounts on each axis turns it into the oval.
        let radius: CGFloat = 100
        guard let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": radius - 2,
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black,
        ])?.outputImage else { return nil }
        return disc
            .transformed(by: CGAffineTransform(scaleX: rect.width / (2 * radius), y: rect.height / (2 * radius)))
            .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))
            .cropped(to: frameExtent)
    }
}
