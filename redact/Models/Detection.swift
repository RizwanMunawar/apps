import CoreGraphics
import CoreImage
import Foundation

public struct Detection: Identifiable {
    public let id = UUID()
    public let classIndex: Int
    public let confidence: Float
    /// Bounding box in normalized [0,1] coordinates, origin top-left, relative to the source frame.
    public let boundingBox: CGRect
    /// Per-pixel silhouette mask, already mapped into the source frame's CoreImage coordinate
    /// space (bottom-left origin, same extent as the frame). Nil unless mask decoding was requested.
    public let maskImage: CIImage?

    public init(classIndex: Int, confidence: Float, boundingBox: CGRect, maskImage: CIImage?) {
        self.classIndex = classIndex
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.maskImage = maskImage
    }

}

public enum BlurStyle: String, CaseIterable, Identifiable, Sendable {
    case pixelate = "Pixelate"
    case gaussian = "Gaussian blur"
    public var id: String { rawValue }
}

public enum BlurMethod: String, CaseIterable, Identifiable, Sendable {
    case box = "Box"
    case mask = "Mask"
    public var id: String { rawValue }
    var label: String { rawValue }
    var detail: String {
        switch self {
        case .box: return "Covers the whole rectangle around each object."
        case .mask: return "Covers only the object's own outline."
        }
    }
}
