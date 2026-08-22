import Foundation

/// The 80 COCO classes YOLO26 is pretrained on, in the exact index order the model outputs.
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

struct DetectableClass: Identifiable, Hashable {
    let index: Int
    let name: String
    var id: Int { index }
    var displayName: String { name.capitalized }
    var glyph: String {
        switch name {
        case "person": return "person.fill"
        case "cat", "dog", "bird", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe": return "pawprint.fill"
        case "car", "bus", "train", "truck", "motorcycle", "bicycle", "boat", "airplane": return "car.fill"
        case "cell phone": return "iphone"
        case "laptop", "tv", "mouse", "keyboard", "remote": return "display"
        case "book": return "book.fill"
        case "bottle", "wine glass", "cup": return "cup.and.saucer.fill"
        case "handbag", "backpack", "suitcase": return "bag.fill"
        default: return "square.dashed"
        }
    }

    static let all: [DetectableClass] = COCOClasses.names.enumerated().map { DetectableClass(index: $0.offset, name: $0.element) }
}
