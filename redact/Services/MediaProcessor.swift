@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import ImageIO
import Foundation

enum MediaProcessingError: LocalizedError {
    case unreadableImage
    case noVideoTrack
    case pixelBufferCreationFailed
    case writerFailed(String)
    case audioTrackUnsupported

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "Couldn't read that image file."
        case .noVideoTrack: return "That file has no video track."
        case .pixelBufferCreationFailed: return "Couldn't prepare a frame buffer."
        case .writerFailed(let reason): return "Couldn't write the processed video: \(reason)"
        case .audioTrackUnsupported: return "That video's audio track can't be carried into an MP4."
        }
    }
}

public struct MediaBlurSettings: Sendable {
    public var selectedClasses: Set<Int>
    public var style: BlurStyle
    public var method: BlurMethod
    public var strength: Double
    /// Track objects between frames so the blur stays put. Only meaningful for video.
    public var tracking: Bool

    public init(
        selectedClasses: Set<Int>, style: BlurStyle, method: BlurMethod, strength: Double,
        tracking: Bool = true
    ) {
        self.selectedClasses = selectedClasses
        self.style = style
        self.method = method
        self.strength = strength
        self.tracking = tracking
    }
}

/// Runs the same detect+blur pipeline the live camera uses over a single image or an entire
/// video file — "decode, process, re-encode", the same shape as any offline transcode. Video
/// audio passes through untouched; a short branded outro is appended after the last real frame.
///
/// Not `Sendable` and not shared across concurrent calls — like `FrameProcessor` itself, this is
/// only ever driven from one call at a time (the view model serializes image/video jobs), so
/// `frameProcessor`'s "single caller" invariant holds here too.
public final class MediaProcessor {
    private let frameProcessor: FrameProcessor
    private let ciContext = RenderContext.shared

    public init(frameProcessor: FrameProcessor) {
        self.frameProcessor = frameProcessor
    }

    // MARK: - Image

    public func processImage(at url: URL, settings: MediaBlurSettings) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MediaProcessingError.unreadableImage
        }
        guard let pixelBuffer = Self.pixelBuffer(from: cgImage) else {
            throw MediaProcessingError.pixelBufferCreationFailed
        }
        let result = frameProcessor.process(
            pixelBuffer: pixelBuffer, selectedClasses: settings.selectedClasses,
            style: settings.style, method: settings.method, strength: settings.strength
        )
        guard let blurred = result.image else { throw MediaProcessingError.unreadableImage }
        let watermarked = WatermarkRenderer.watermarked(CIImage(cgImage: blurred))
        guard let final = ciContext.createCGImage(watermarked, from: watermarked.extent) else {
            throw MediaProcessingError.unreadableImage
        }
        return final
    }

    /// Renders a CGImage into a fresh 32BGRA CVPixelBuffer — the input format `FrameProcessor`
    /// (and the detector beneath it) expects, same as what the camera delivers.
    static func pixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width, height = cgImage.height
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Video

    /// Decode -> blur -> watermark -> encode over a whole video file, then append a branded
    /// outro. Audio is copied through untouched.
    ///
    /// - Parameter outroSeconds: length of the branded outro appended after the last real frame.
    public func processVideo(
        inputURL: URL, outputURL: URL, settings: MediaBlurSettings, outroSeconds: Double = 3.5,
        preview: ((CGImage) -> Void)? = nil,
        progress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw MediaProcessingError.noVideoTrack }
        // A separate asset instance for audio, not just a separate reader: two AVAssetReaders
        // attached to the *same* AVAsset silently yield no samples on the second one, which
        // showed up as processed clips coming out completely silent.
        let audioAsset = AVURLAsset(url: inputURL)
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first

        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        var frameRate = try await videoTrack.load(.nominalFrameRate)
        if frameRate <= 1 { frameRate = 30 }

        let outputSize = Self.orientedSize(naturalSize: naturalSize, transform: transform)
        let orientCIImage = Self.orientationTransform(naturalSize: naturalSize, transform: transform)

        try? FileManager.default.removeItem(at: outputURL)

        // Video and audio get their own readers rather than two outputs on one. A single reader
        // hands its outputs samples roughly in step, so draining video to completion before
        // touching audio can stall it; independent readers have no such coupling, which lets the
        // two passes stay simple and sequential.
        let videoReader = try AVAssetReader(asset: asset)
        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoReaderOutput.alwaysCopiesSampleData = false
        guard videoReader.canAdd(videoReaderOutput) else { throw MediaProcessingError.writerFailed("reader rejected video track") }
        videoReader.add(videoReaderOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
        ])
        videoWriterInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
        ])
        guard writer.canAdd(videoWriterInput) else { throw MediaProcessingError.writerFailed("writer rejected video input") }
        writer.add(videoWriterInput)

        var audioWriterInput: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let sourceFormat = try await audioTrack.load(.formatDescriptions).first
            let reader = try AVAssetReader(asset: audioAsset)

            // Passthrough first: copying the original samples is both faster and lossless. It
            // needs `sourceFormatHint` — without one the writer simply refuses the input
            // (`canAdd` returns false), which is exactly how audio silently vanished before.
            var output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            var input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: sourceFormat)

            if !writer.canAdd(input) {
                // Some source codecs can't be carried into MP4 untouched. Decode to PCM and
                // re-encode as AAC instead, matching the source's channel count and sample rate,
                // rather than dropping the audio track on the floor.
                let asbd = sourceFormat.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: Int(asbd?.mChannelsPerFrame ?? 2),
                    AVSampleRateKey: asbd?.mSampleRate ?? 44_100,
                    AVEncoderBitRateKey: 128_000,
                ])
            }

            output.alwaysCopiesSampleData = false
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else {
                // Better to fail loudly than to hand back a video whose audio quietly disappeared.
                throw MediaProcessingError.audioTrackUnsupported
            }
            reader.add(output)
            writer.add(input)
            audioReader = reader
            audioReaderOutput = output
            audioWriterInput = input
        }

        guard videoReader.startReading() else {
            throw MediaProcessingError.writerFailed(videoReader.error?.localizedDescription ?? "reader failed to start")
        }
        if let audioReader, !audioReader.startReading() {
            throw MediaProcessingError.writerFailed(audioReader.error?.localizedDescription ?? "audio reader failed to start")
        }
        guard writer.startWriting() else {
            throw MediaProcessingError.writerFailed(writer.error?.localizedDescription ?? "writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let frameProcessor = self.frameProcessor
        let ciContext = self.ciContext

        // Both writer inputs are driven at the same time. AVAssetWriter paces its inputs against
        // each other, so finishing all of the video before touching audio deadlocks: the writer
        // sits waiting on the audio it has not been given, and the audio input is never asked
        // for data. Concurrent pull loops are the pattern AVFoundation is built around.
        let boxedVideoInput = UncheckedSendable(videoWriterInput)
        let boxedAudioInput = UncheckedSendable(audioWriterInput)
        let boxedAdaptor = UncheckedSendable(adaptor)
        let boxedVideoOutput = UncheckedSendable(videoReaderOutput)
        let boxedAudioOutput = UncheckedSendable(audioReaderOutput)
        let boxedWriter = UncheckedSendable(writer)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let videoInput = boxedVideoInput.value
                let videoOutput = boxedVideoOutput.value
                let adaptor = boxedAdaptor.value
                let writer = boxedWriter.value

                var lastPreviewAt: CFAbsoluteTime = 0
                // A fresh tracker per export: carrying tracks over from a previous run would
                // start the video with boxes belonging to entirely different footage.
                let tracker = settings.tracking ? FastTracker() : nil
                let lastPTS = try await Self.drain(input: videoInput, on: "redact.media.video-write") { input, resume in
                    var latest = CMTime.zero
                    while input.isReadyForMoreMediaData {
                        guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                            resume(.success(latest))
                            return
                        }
                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        latest = pts

                        let result = frameProcessor.process(
                            pixelBuffer: pixelBuffer, selectedClasses: settings.selectedClasses,
                            style: settings.style, method: settings.method, strength: settings.strength,
                            tracker: tracker, upright: orientCIImage
                        )
                        guard let blurred = result.image else { continue }

                        // Blur boxes are computed in the buffer's native (unrotated) space, so
                        // orient the whole already-blurred frame afterward — the blur patches
                        // rotate along with everything else and stay aligned.
                        let oriented = CIImage(cgImage: blurred).transformed(by: orientCIImage)
                        let watermarked = WatermarkRenderer.watermarked(oriented)

                        guard let outputBuffer = Self.pixelBuffer(from: adaptor, size: outputSize) else { continue }
                        ciContext.render(watermarked, to: outputBuffer, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: CGColorSpaceCreateDeviceRGB())

                        if !adaptor.append(outputBuffer, withPresentationTime: pts) {
                            resume(.failure(MediaProcessingError.writerFailed(writer.error?.localizedDescription ?? "append failed")))
                            return
                        }
                        let fraction = min(CMTimeGetSeconds(pts) / totalSeconds, 1.0) * 0.9
                        DispatchQueue.main.async { progress(fraction) }

                        // Showing every frame would swamp the main thread and slow the export
                        // down; a handful per second is enough to watch the blur working.
                        if let preview {
                            let now = CFAbsoluteTimeGetCurrent()
                            if now - lastPreviewAt >= 1.0 / 12.0 {
                                lastPreviewAt = now
                                let scaled = Self.downscaledForPreview(watermarked)
                                if let previewImage = ciContext.createCGImage(scaled, from: scaled.extent) {
                                    DispatchQueue.main.async { preview(previewImage) }
                                }
                            }
                        }
                    }
                }

                // The outro goes onto the same input, so it has to be appended before the input
                // is marked finished — marking it inside the pull loop above would silently drop
                // every outro frame while still producing a valid (just too short) file.
                try await Self.appendOutro(
                    adaptor: adaptor, input: videoInput, ciContext: ciContext, outputSize: outputSize,
                    startPTS: lastPTS, frameRate: frameRate,
                    seconds: min(outroSeconds, Self.maximumOutroSeconds)
                )
                videoInput.markAsFinished()
                DispatchQueue.main.async { progress(0.97) }
                if let preview {
                    let outro = WatermarkRenderer.outroFrame(size: outputSize, progress: 0.6)
                    if let outroImage = ciContext.createCGImage(outro, from: outro.extent) {
                        DispatchQueue.main.async { preview(outroImage) }
                    }
                }
            }

            if let audioInput = boxedAudioInput.value, let audioOutput = boxedAudioOutput.value {
                let writer = boxedWriter.value
                group.addTask {
                    _ = try await Self.drain(input: audioInput, on: "redact.media.audio-write") { input, resume in
                        while input.isReadyForMoreMediaData {
                            guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
                                resume(.success(.zero))
                                return
                            }
                            if !input.append(sampleBuffer) {
                                resume(.failure(MediaProcessingError.writerFailed(writer.error?.localizedDescription ?? "audio append failed")))
                                return
                            }
                        }
                    }
                    audioInput.markAsFinished()
                }
            }

            try await group.waitForAll()
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw MediaProcessingError.writerFailed(writer.error?.localizedDescription ?? "unknown writer failure")
        }
        progress(1.0)
    }

    /// Bridges one `requestMediaDataWhenReady` pull loop into async/await, returning the last
    /// presentation timestamp `body` reported.
    ///
    /// `body` is handed the input plus a `resume` it calls exactly once, when the track is
    /// exhausted or an append fails. AVFoundation can re-enter the block after that point, so
    /// resumption is latched: the second and later calls are dropped rather than trapping on a
    /// double-resume, and re-entrant invocations return immediately.
    private static func drain(
        input: AVAssetWriterInput,
        on label: String,
        body: @escaping (AVAssetWriterInput, @escaping (Result<CMTime, Error>) -> Void) -> Void
    ) async throws -> CMTime {
        let latch = ResumeLatch()
        let queue = DispatchQueue(label: label)
        // AVFoundation's writer inputs are explicitly non-Sendable, but the pull block only ever
        // runs on `queue` — one serial queue, one input — so crossing the boundary here is safe
        // in a way the compiler can't see.
        let boxed = UncheckedSendable(input)
        let result: CMTime = try await withCheckedThrowingContinuation { continuation in
            latch.attach(continuation)
            input.requestMediaDataWhenReady(on: queue) {
                guard !latch.isFinished else { return }
                body(boxed.value) { outcome in latch.finish(outcome) }
            }
        }
        return result
    }

    /// Appends `seconds` of the animated outro card at `frameRate`, continuing from `startPTS`.
    ///
    /// Each frame is composited at its own point in the animation, so the card fades and drifts
    /// rather than sitting frozen. That is only CIImage transforms per frame on top of the two
    /// cached bitmaps, so it costs no more than the static version did.
    private static func appendOutro(
        adaptor: AVAssetWriterInputPixelBufferAdaptor, input: AVAssetWriterInput, ciContext: CIContext,
        outputSize: CGSize, startPTS: CMTime, frameRate: Float, seconds: Double
    ) async throws {
        guard seconds > 0 else { return }
        let frameCount = max(1, Int((Double(frameRate) * seconds).rounded()))
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let buffer = Self.pixelBuffer(from: adaptor, size: outputSize) else { continue }
            let progress = frameCount == 1 ? 1 : Double(i) / Double(frameCount - 1)
            let frame = WatermarkRenderer.outroFrame(size: outputSize, progress: progress)
            ciContext.render(frame, to: buffer, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: CGColorSpaceCreateDeviceRGB())
            let pts = CMTimeAdd(startPTS, CMTimeMultiply(frameDuration, multiplier: Int32(i + 1)))
            adaptor.append(buffer, withPresentationTime: pts)
        }
    }

    /// Hard ceiling on the outro, however long a caller asks for.
    public static let maximumOutroSeconds: Double = 4

    /// Longest side a preview frame is rendered at. The pane showing them is a few hundred
    /// points wide, so anything past this is memory and copy cost for pixels nobody sees.
    private static let previewMaxSide: CGFloat = 900

    private static func downscaledForPreview(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > previewMaxSide else { return image }
        let scale = previewMaxSide / longest
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func pixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor, size: CGSize) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// The output frame size after applying the track's preferred transform — a 90°-rotated
    /// (e.g. portrait phone) video needs width/height swapped versus its stored natural size.
    private static func orientedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// `preferredTransform` rotates around the original origin, which can leave the image
    /// sitting partly outside the positive coordinate space CoreImage expects — this normalizes
    /// it back to a 0,0-origin rect of `orientedSize`, the standard fix for this exact problem.
    private static func orientationTransform(naturalSize: CGSize, transform: CGAffineTransform) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let normalize = CGAffineTransform(translationX: -transformedRect.origin.x, y: -transformedRect.origin.y)
        return transform.concatenating(normalize)
    }
}

/// One-shot continuation holder for `MediaProcessor.drain`. `requestMediaDataWhenReady` blocks
/// are re-entrant and can fire again after the loop has already reported completion, and
/// resuming a `CheckedContinuation` twice traps — so resumption is latched behind a lock and
/// every call after the first is dropped.
private final class ResumeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CMTime, Error>?
    private var finished = false

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func attach(_ continuation: CheckedContinuation<CMTime, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func finish(_ outcome: Result<CMTime, Error>) {
        lock.lock()
        let pending = finished ? nil : continuation
        finished = true
        continuation = nil
        lock.unlock()
        pending?.resume(with: outcome)
    }
}

/// Carries a value the compiler can't prove `Sendable` across a concurrency boundary the author
/// has verified by hand. Only used where a serial queue already guarantees exclusive access.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
