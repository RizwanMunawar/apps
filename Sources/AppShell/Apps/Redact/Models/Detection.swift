import CoreGraphics
import CoreImage
import Foundation

struct Detection: Identifiable {
    let id = UUID()
    let classIndex: Int
    let confidence: Float
    /// Bounding box in normalized [0,1] coordinates, origin top-left, relative to the source frame.
    let boundingBox: CGRect
    /// Per-pixel silhouette mask, already mapped into the source frame's CoreImage coordinate
    /// space (bottom-left origin, same extent as the frame). Nil unless mask decoding was requested.
    let maskImage: CIImage?

    var className: String {
        guard COCOClasses.names.indices.contains(classIndex) else { return "unknown" }
        return COCOClasses.names[classIndex]
    }
}

enum BlurStyle: String, CaseIterable, Identifiable {
    case pixelate = "Pixelate"
    case gaussian = "Gaussian blur"
    var id: String { rawValue }
}

enum BlurMethod: String, CaseIterable, Identifiable {
    case box = "Box"
    case segmentation = "Segmentation"
    var id: String { rawValue }
    var label: String { rawValue }
    var detail: String {
        switch self {
        case .box: return "Fast — blurs the full rectangle around each object."
        case .segmentation: return "Precise — blurs only the object's exact outline."
        }
    }
}
