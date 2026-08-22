import CoreImage
import CoreVideo
import Foundation

/// Runs detection + blur compositing for a single frame. Instances are only ever driven from the
/// camera's own serial frame queue, so concurrent calls never happen despite the `Sendable` escape hatch.
public final class FrameProcessor: @unchecked Sendable {
    private let detector: YOLODetector
    private let ciContext = RenderContext.shared

    public convenience init() throws {
        self.init(detector: try YOLODetector())
    }

    init(detector: YOLODetector) {
        self.detector = detector
    }

    var info: ModelInfo { detector.info }
    var classes: [DetectableClass] { detector.classes }

    /// - Parameter producingImage: when false the frame is still detected and composited, but no
    ///   `CGImage` is built. Used while Redact's screen is off-screen, where that allocation is
    ///   pure waste.
    /// - Parameter tracker: when supplied, detections are run through it before blurring, which
    ///   steadies the boxes and keeps covering an object through a frame the detector missed. Pass
    ///   nil for one-shot work like a still image, where there is nothing to track across.
    func process(
        pixelBuffer: CVPixelBuffer, selectedClasses: Set<Int>, style: BlurStyle,
        method: BlurMethod, strength: Double, producingImage: Bool = true,
        tracker: FastTracker? = nil
    ) -> (image: CGImage?, classIndices: [Int]) {
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        func rendered(_ image: CIImage) -> CGImage? {
            producingImage ? ciContext.createCGImage(image, from: image.extent) : nil
        }

        guard !selectedClasses.isEmpty else {
            return (rendered(frame), [])
        }
        guard let detections = try? detector.detect(in: pixelBuffer, includeMasks: method == .mask) else {
            return (rendered(frame), [])
        }
        var matched = detections.filter { selectedClasses.contains($0.classIndex) }
        // Track only what is actually being blurred: everything else would just be tracks nobody
        // looks at, and changing the class selection then cleanly resets the ones that matter.
        if let tracker { matched = tracker.update(with: matched) }
        let composed = BlurCompositor.apply(matched, style: style, method: method, strength: strength, to: frame)
        return (rendered(composed), matched.map(\.classIndex))
    }
}

/// Whether Redact's screen is currently on-screen. Same shape as `PipelineSettings`: written on
/// the main actor, read from the camera's frame queue.
final class VisibilityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isVisible = true

    var isVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isVisible }
        set { lock.lock(); _isVisible = newValue; lock.unlock() }
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
    private var _tracking = true

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
    var tracking: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _tracking }
        set { lock.lock(); _tracking = newValue; lock.unlock() }
    }
}
