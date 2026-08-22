import Foundation

/// Everything the "model info" popover shows about whichever detection model is loaded, plus the
/// class list the picker is built from. Filled in from the CoreML model's own description and
/// metadata, so a custom model reports its own classes rather than COCO's 80.
public struct ModelInfo: Sendable {
    /// Shown as the model's name, e.g. "yolo26n-seg".
    public let name: String
    /// File the model was loaded from, for the "Source" row.
    public let fileName: String
    /// True when this is the model shipped inside the app.
    public let isBuiltIn: Bool
    /// Square side the model takes as input, e.g. 640.
    public let inputSide: Int
    public let classNames: [String]
    /// Size on disk of the compiled model, already formatted.
    public let sizeOnDisk: String
    /// "Segmentation" when the model has a mask branch, otherwise "Detection".
    public let task: String

    public var classCount: Int { classNames.count }

    public var supportsSegmentation: Bool { task == "Segmentation" }
}

/// Where a model came from. The bundled one is always available; a custom one is remembered by
/// path so it survives relaunches.
enum ModelSource: Equatable {
    case builtIn
    case custom(URL)

    var isBuiltIn: Bool { self == .builtIn }
}

/// The classes a model can detect, in the exact index order it outputs.
public struct DetectableClass: Identifiable, Hashable, Sendable {
    public let index: Int
    public let name: String
    public var id: Int { index }
    public var displayName: String { name.capitalized }

    var glyph: String {
        switch name.lowercased() {
        case "person", "face": return "person.fill"
        case "cat", "dog", "bird", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe": return "pawprint.fill"
        case "car", "bus", "train", "truck", "motorcycle", "bicycle", "boat", "airplane": return "car.fill"
        case "cell phone": return "iphone"
        case "laptop", "tv", "mouse", "keyboard", "remote": return "display"
        case "book": return "book.fill"
        case "bottle", "wine glass", "cup": return "cup.and.saucer.fill"
        case "handbag", "backpack", "suitcase": return "bag.fill"
        case "license plate", "number plate": return "rectangle.and.text.magnifyingglass"
        default: return "square.dashed"
        }
    }

    static func list(from names: [String]) -> [DetectableClass] {
        names.enumerated().map { DetectableClass(index: $0.offset, name: $0.element) }
    }
}

/// Fallback names for a model that doesn't declare its own: the 80 COCO classes YOLO is
/// pretrained on, in the index order the model outputs.
enum COCOClasses {
    static let names: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
        "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
        "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
        "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    ]
}
