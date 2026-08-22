import Accelerate
import CoreML
import CoreImage
import CoreVideo
import Foundation

enum DetectorError: LocalizedError {
    case modelResourceMissing
    case unexpectedOutputShape
    var errorDescription: String? {
        switch self {
        case .modelResourceMissing: return "The YOLO26 model resource is missing from the app bundle."
        case .unexpectedOutputShape: return "The YOLO26 model returned an output shape we don't know how to decode."
        }
    }
}

/// Runs YOLO26n-seg on individual video frames. Detection is synchronous and blocking by design —
/// call it from a background queue; AVFoundation's `alwaysDiscardsLateVideoFrames` then naturally
/// paces capture to whatever rate inference can sustain.
final class YOLODetector {
    private static let inputSide: CGFloat = 640
    private static let confidenceThreshold: Float = 0.4
    private static let protoSide = 160
    private static let maskCoefficientCount = 32

    private let model: MLModel
    private let inputFeatureName: String
    private let detectionOutputName: String
    private let protoOutputName: String
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Reused across frames instead of allocating a fresh 640x640 IOSurface-backed buffer per call —
    /// the camera's serial queue guarantees `detect(in:)` never runs concurrently with itself.
    private lazy var letterboxBuffer: CVPixelBuffer? = makePixelBuffer(width: Int(Self.inputSide), height: Int(Self.inputSide))
    /// The letterbox pad color never changes, so build it once instead of per frame.
    private let padCanvas = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255))
        .cropped(to: CGRect(x: 0, y: 0, width: YOLODetector.inputSide, height: YOLODetector.inputSide))

    init() throws {
        guard let packageURL = Bundle.module.url(forResource: "yolo26n-seg", withExtension: "mlpackage") else {
            throw DetectorError.modelResourceMissing
        }

        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("apps-releases/Redact", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cachedModelURL = cacheDir.appendingPathComponent("yolo26n-seg.mlmodelc")

        let config = MLModelConfiguration()
        // .all routes through a GPU/MPSGraph compute path that crashes on some Mac/driver
        // combinations; CPU+ANE is still fast for a nano model and avoids that path entirely.
        config.computeUnits = .cpuAndNeuralEngine

        let compiledURL: URL
        if FileManager.default.fileExists(atPath: cachedModelURL.path) {
            compiledURL = cachedModelURL
        } else {
            let freshlyCompiled = try MLModel.compileModel(at: packageURL)
            try? FileManager.default.removeItem(at: cachedModelURL)
            try FileManager.default.copyItem(at: freshlyCompiled, to: cachedModelURL)
            compiledURL = cachedModelURL
        }

        model = try MLModel(contentsOf: compiledURL, configuration: config)
        guard let input = model.modelDescription.inputDescriptionsByName.keys.first else {
            throw DetectorError.modelResourceMissing
        }
        inputFeatureName = input

        var detectionName: String?
        var protoName: String?
        for (name, desc) in model.modelDescription.outputDescriptionsByName {
            guard let shape = desc.multiArrayConstraint?.shape.map({ $0.intValue }) else { continue }
            if shape.count == 3 { detectionName = name }
            if shape.count == 4 { protoName = name }
        }
        guard let detectionName, let protoName else { throw DetectorError.modelResourceMissing }
        detectionOutputName = detectionName
        protoOutputName = protoName
    }

    /// - Parameter includeMasks: when false, skips the (more expensive) per-detection mask decode
    ///   and every `Detection.maskImage` is nil. The model still computes both outputs internally
    ///   either way — this only controls whether we decode the mask branch on the CPU side.
    func detect(in pixelBuffer: CVPixelBuffer, includeMasks: Bool) throws -> [Detection] {
        let frameWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let side = Self.inputSide

        let scale = min(side / frameWidth, side / frameHeight)
        let scaledW = frameWidth * scale
        let scaledH = frameHeight * scale
        let padX = (side - scaledW) / 2
        let padY = (side - scaledH) / 2

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let letterboxed = source
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: padX, y: padY))
        let composed = letterboxed.composited(over: padCanvas)

        guard let inputBuffer = letterboxBuffer else { return [] }
        ciContext.render(composed, to: inputBuffer)

        let provider = try MLDictionaryFeatureProvider(dictionary: [inputFeatureName: MLFeatureValue(pixelBuffer: inputBuffer)])
        let result = try model.prediction(from: provider)
        guard let detectionArray = result.featureValue(for: detectionOutputName)?.multiArrayValue,
              detectionArray.shape.count == 3 else {
            throw DetectorError.unexpectedOutputShape
        }

        let detectionCount = detectionArray.shape[1].intValue
        let valuesPerDetection = detectionArray.shape[2].intValue
        guard valuesPerDetection >= 6 else { throw DetectorError.unexpectedOutputShape }
        let hasMaskCoefficients = includeMasks && valuesPerDetection >= 6 + Self.maskCoefficientCount

        let rowStride = detectionArray.strides[1].intValue
        let colStride = detectionArray.strides[2].intValue
        let pointer = detectionArray.dataPointer.bindMemory(to: Float32.self, capacity: detectionArray.count)

        var protoPointer: UnsafePointer<Float32>?
        var protoChannelStride = Self.protoSide * Self.protoSide
        if hasMaskCoefficients, let protoArray = result.featureValue(for: protoOutputName)?.multiArrayValue, protoArray.shape.count == 4 {
            protoChannelStride = protoArray.strides[1].intValue
            protoPointer = UnsafePointer(protoArray.dataPointer.bindMemory(to: Float32.self, capacity: protoArray.count))
        }

        var detections: [Detection] = []
        detections.reserveCapacity(16)
        for i in 0..<detectionCount {
            let base = i * rowStride
            let confidence = pointer[base + 4 * colStride]
            guard confidence >= Self.confidenceThreshold else { continue }

            let x1 = CGFloat(pointer[base + 0 * colStride])
            let y1 = CGFloat(pointer[base + 1 * colStride])
            let x2 = CGFloat(pointer[base + 2 * colStride])
            let y2 = CGFloat(pointer[base + 3 * colStride])
            let classIndex = Int(pointer[base + 5 * colStride])

            let origX1 = ((x1 - padX) / scale).clamped(to: 0...frameWidth)
            let origY1 = ((y1 - padY) / scale).clamped(to: 0...frameHeight)
            let origX2 = ((x2 - padX) / scale).clamped(to: 0...frameWidth)
            let origY2 = ((y2 - padY) / scale).clamped(to: 0...frameHeight)
            guard origX2 > origX1, origY2 > origY1 else { continue }

            let normalized = CGRect(
                x: origX1 / frameWidth,
                y: origY1 / frameHeight,
                width: (origX2 - origX1) / frameWidth,
                height: (origY2 - origY1) / frameHeight
            )

            var maskImage: CIImage?
            if let protoPointer {
                let coeffsBase = base + 6 * colStride
                maskImage = decodeMask(
                    coeffsBase: coeffsBase, coeffStride: colStride, pointer: pointer,
                    protoPointer: protoPointer, protoChannelStride: protoChannelStride,
                    frameWidth: frameWidth, frameHeight: frameHeight, scale: scale, padX: padX, padY: padY
                )
            }

            detections.append(Detection(classIndex: classIndex, confidence: confidence, boundingBox: normalized, maskImage: maskImage))
        }
        return detections
    }

    /// Decodes one detection's mask from its 32 coefficients + the shared prototype planes,
    /// via a weighted sum of prototypes (Accelerate-vectorized), thresholded at the logit's zero
    /// crossing (equivalent to sigmoid > 0.5 without needing the sigmoid itself), then maps the
    /// resulting 640x640-space mask back into the original frame's coordinate space using the
    /// same letterbox scale/pad already computed for this frame.
    private func decodeMask(
        coeffsBase: Int, coeffStride: Int, pointer: UnsafePointer<Float32>,
        protoPointer: UnsafePointer<Float32>, protoChannelStride: Int,
        frameWidth: CGFloat, frameHeight: CGFloat, scale: CGFloat, padX: CGFloat, padY: CGFloat
    ) -> CIImage? {
        let planeCount = Self.protoSide * Self.protoSide
        var accum = [Float32](repeating: 0, count: planeCount)
        accum.withUnsafeMutableBufferPointer { buf in
            guard let dest = buf.baseAddress else { return }
            for c in 0..<Self.maskCoefficientCount {
                var coeff = pointer[coeffsBase + c * coeffStride]
                let channelPtr = protoPointer + c * protoChannelStride
                vDSP_vsma(channelPtr, 1, &coeff, dest, 1, dest, 1, vDSP_Length(planeCount))
            }
        }

        var maskBytes = [UInt8](repeating: 0, count: planeCount)
        for i in 0..<planeCount { maskBytes[i] = accum[i] > 0 ? 255 : 0 }

        let maskAtProtoRes = maskBytes.withUnsafeBytes { raw -> CIImage in
            CIImage(
                bitmapData: Data(raw), bytesPerRow: Self.protoSide,
                size: CGSize(width: Self.protoSide, height: Self.protoSide),
                format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()
            )
        }

        // Prototype grid is stride-4 relative to the 640x640 letterboxed input.
        let protoToInputScale = Self.inputSide / CGFloat(Self.protoSide)
        let maskAt640 = maskAtProtoRes.transformed(by: CGAffineTransform(scaleX: protoToInputScale, y: protoToInputScale))

        // Reverse the same letterbox transform used to build the model input, mapping this mask
        // into the original frame's pixel space and CoreImage coordinate convention.
        let cropped = maskAt640.cropped(to: CGRect(x: padX, y: padY, width: frameWidth * scale, height: frameHeight * scale))
        let mapped = cropped
            .transformed(by: CGAffineTransform(translationX: -padX, y: -padY))
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        return mapped
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return buffer
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
