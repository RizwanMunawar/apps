import CoreImage
import CoreVideo
import Foundation

/// Runs detection + blur compositing for a single frame. Instances are only ever driven from the
/// camera's own serial frame queue, so concurrent calls never happen despite the `Sendable` escape hatch.
final class FrameProcessor: @unchecked Sendable {
    private let detector: YOLODetector
    private let ciContext = CIContext()

    init() throws {
        detector = try YOLODetector()
    }

    func process(pixelBuffer: CVPixelBuffer, selectedClasses: Set<Int>, style: BlurStyle, method: BlurMethod, strength: Double) -> (image: CGImage?, detectionCount: Int) {
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        guard !selectedClasses.isEmpty else {
            return (ciContext.createCGImage(frame, from: frame.extent), 0)
        }
        guard let detections = try? detector.detect(in: pixelBuffer, includeMasks: method == .segmentation) else {
            return (ciContext.createCGImage(frame, from: frame.extent), 0)
        }
        let matched = detections.filter { selectedClasses.contains($0.classIndex) }
        let composed = BlurCompositor.apply(matched, style: style, method: method, strength: strength, to: frame)
        return (ciContext.createCGImage(composed, from: composed.extent), matched.count)
    }
}

/// Thread-safe settings snapshot the real-time pipeline reads from a background queue while
/// SwiftUI mutates it from the main actor.
final class PipelineSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var _selectedClasses: Set<Int> = [0]
    private var _style: BlurStyle = .pixelate
    private var _method: BlurMethod = .box
    private var _strength: Double = 25

    var selectedClasses: Set<Int> {
        get { lock.lock(); defer { lock.unlock() }; return _selectedClasses }
        set { lock.lock(); _selectedClasses = newValue; lock.unlock() }
    }
    var style: BlurStyle {
        get { lock.lock(); defer { lock.unlock() }; return _style }
        set { lock.lock(); _style = newValue; lock.unlock() }
    }
    var method: BlurMethod {
        get { lock.lock(); defer { lock.unlock() }; return _method }
        set { lock.lock(); _method = newValue; lock.unlock() }
    }
    var strength: Double {
        get { lock.lock(); defer { lock.unlock() }; return _strength }
        set { lock.lock(); _strength = newValue; lock.unlock() }
    }
}
