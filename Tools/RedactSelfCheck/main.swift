import AVFoundation
import CoreImage
import Foundation
import Redact

// End-to-end check for Redact's offline media pipeline — the "decode -> blur -> watermark ->
// encode" path behind "Process file", which the live-camera path never touches.
//
//     swift run redact-selfcheck
//
// Fixtures are synthesised on the fly rather than checked in, so the source's exact duration,
// frame rate and orientation are known to the assertions and the repo stays free of binaries.

var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    let suffix = condition ? "" : "  (\(detail()))"
    print("  \(condition ? "PASS" : "FAIL")  \(label)\(suffix)")
    if !condition { failures += 1 }
}

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("redact-selfcheck-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
// Set REDACT_KEEP_OUTPUT=1 to leave the processed files behind for inspection, e.g. to eyeball
// the watermark or step through the outro frame by frame.
let keepOutput = ProcessInfo.processInfo.environment["REDACT_KEEP_OUTPUT"] == "1"
defer { if !keepOutput { try? FileManager.default.removeItem(at: scratch) } }
if keepOutput { print("keeping output in \(scratch.path)") }

let settings = MediaBlurSettings(selectedClasses: [0], style: .pixelate, method: .box, strength: 25)

/// Writes a short clip of flat-coloured frames, optionally with a silent audio track and a
/// non-identity preferred transform (as a portrait phone recording would carry).
func makeVideo(
    at url: URL, size: CGSize, seconds: Double, frameRate: Int32,
    audio: Bool = false, rotated: Bool = false
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
    ])
    videoInput.expectsMediaDataInRealTime = false
    if rotated { videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    writer.add(videoInput)

    var audioInput: AVAssetWriterInput?
    if audio {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        audioInput = input
    }

    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let context = CIContext()
    let frameCount = Int(Double(frameRate) * seconds)
    for i in 0..<frameCount {
        while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        guard let pool = adaptor.pixelBufferPool else { break }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { break }
        let shade = Double(i) / Double(max(frameCount - 1, 1))
        let image = CIImage(color: CIColor(red: shade, green: 0.4, blue: 1 - shade))
            .cropped(to: CGRect(origin: .zero, size: size))
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: frameRate))
    }
    videoInput.markAsFinished()

    if let audioInput {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        if let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            pcm.frameLength = frames // zero-filled; only the track's survival is under test
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: .zero, decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: format.formatDescription, sampleCount: CMItemCount(frames),
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
            )
            if let sampleBuffer {
                CMSampleBufferSetDataBufferFromAudioBufferList(
                    sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
                    blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                    bufferList: pcm.mutableAudioBufferList
                )
                while !audioInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                audioInput.append(sampleBuffer)
            }
        }
        audioInput.markAsFinished()
    }

    await writer.finishWriting()
    guard writer.status == .completed else {
        throw NSError(domain: "selfcheck", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "fixture writer failed: \(writer.error?.localizedDescription ?? "unknown")"
        ])
    }
}

func makeImage(at url: URL, size: CGSize) throws {
    let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    try (data as Data).write(to: url)
}

/// Number of samples actually readable from a track — a track can exist in the container while
/// carrying nothing, which would make a track-count assertion pass vacuously.
func sampleCount(in url: URL, mediaType: AVMediaType) async throws -> Int {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: mediaType).first else { return 0 }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var count = 0
    while output.copyNextSampleBuffer() != nil { count += 1 }
    return count
}

print("loading the CoreML model…")
let processor = MediaProcessor(frameProcessor: try FrameProcessor())

// MARK: - Video: the outro lands after the last real frame

print("\nvideo · 1s source + 2s outro")
let source = scratch.appendingPathComponent("source.mp4")
try await makeVideo(at: source, size: CGSize(width: 320, height: 240), seconds: 1.0, frameRate: 30)
let processed = scratch.appendingPathComponent("processed.mp4")

var lastProgress = 0.0
try await processor.processVideo(inputURL: source, outputURL: processed, settings: settings, outroSeconds: 2.0) {
    lastProgress = $0
}

check("output file written", FileManager.default.fileExists(atPath: processed.path))
check("progress reaches 100%", abs(lastProgress - 1.0) < 0.001, "ended at \(lastProgress)")

let processedAsset = AVURLAsset(url: processed)
let videoTracks = try await processedAsset.loadTracks(withMediaType: .video)
check("exactly one video track", videoTracks.count == 1, "got \(videoTracks.count)")

// A markAsFinished in the wrong place drops every outro frame while still producing a perfectly
// valid — just too short — file, so duration is the assertion that catches it.
let duration = CMTimeGetSeconds(try await processedAsset.load(.duration))
check("duration ≈ source + outro (3.0s)", abs(duration - 3.0) < 0.3, "got \(String(format: "%.2f", duration))s")

if let track = videoTracks.first {
    let size = try await track.load(.naturalSize)
    check("resolution preserved (320x240)", size == CGSize(width: 320, height: 240), "got \(size)")
}

// MARK: - Video: audio survives

print("\nvideo · audio passthrough")
let withAudio = scratch.appendingPathComponent("with-audio.mp4")
try await makeVideo(at: withAudio, size: CGSize(width: 320, height: 240), seconds: 1.0, frameRate: 30, audio: true)
let fixtureSamples = try await sampleCount(in: withAudio, mediaType: .audio)
check("fixture carries real audio (guards a vacuous pass)", fixtureSamples > 0, "fixture had \(fixtureSamples) samples")

let audioOut = scratch.appendingPathComponent("with-audio-out.mp4")
try await processor.processVideo(inputURL: withAudio, outputURL: audioOut, settings: settings, outroSeconds: 0.5) { _ in }
let outSamples = try await sampleCount(in: audioOut, mediaType: .audio)
check("audio survives processing", outSamples > 0, "output had \(outSamples) audio samples")

// MARK: - Video: portrait orientation

print("\nvideo · rotated source")
let rotated = scratch.appendingPathComponent("rotated.mp4")
try await makeVideo(at: rotated, size: CGSize(width: 320, height: 240), seconds: 0.5, frameRate: 30, rotated: true)
let rotatedOut = scratch.appendingPathComponent("rotated-out.mp4")
try await processor.processVideo(inputURL: rotated, outputURL: rotatedOut, settings: settings, outroSeconds: 0) { _ in }
if let track = try await AVURLAsset(url: rotatedOut).loadTracks(withMediaType: .video).first {
    let size = try await track.load(.naturalSize)
    // The source's preferred transform is baked into the pixels, so a 90°-rotated 320x240 clip
    // has to come out as an upright 240x320 — not 320x240 with the image lying on its side.
    check("rotation baked in (240x320)", size == CGSize(width: 240, height: 320), "got \(size)")
}

// MARK: - Video: robustness

print("\nvideo · robustness")
let stale = scratch.appendingPathComponent("stale.mp4")
try Data("stale".utf8).write(to: stale)
try await processor.processVideo(inputURL: source, outputURL: stale, settings: settings, outroSeconds: 0.5) { _ in }
check("overwrites an existing destination", try await AVURLAsset(url: stale).loadTracks(withMediaType: .video).count == 1)

let notAVideo = scratch.appendingPathComponent("notes.txt")
try Data("hello".utf8).write(to: notAVideo)
do {
    try await processor.processVideo(
        inputURL: notAVideo, outputURL: scratch.appendingPathComponent("never.mp4"),
        settings: settings, outroSeconds: 0
    ) { _ in }
    check("throws on a file with no video track", false, "no error thrown")
} catch {
    check("throws on a file with no video track", true)
}

// MARK: - Image

print("\nimage")
let imageIn = scratch.appendingPathComponent("source.png")
try makeImage(at: imageIn, size: CGSize(width: 200, height: 120))
let imageOut = try processor.processImage(at: imageIn, settings: settings)
check(
    "resolution preserved (200x120)",
    imageOut.width == 200 && imageOut.height == 120,
    "got \(imageOut.width)x\(imageOut.height)"
)

let broken = scratch.appendingPathComponent("broken.png")
try Data("not a png".utf8).write(to: broken)
do {
    _ = try processor.processImage(at: broken, settings: settings)
    check("throws on an unreadable image", false, "no error thrown")
} catch {
    check("throws on an unreadable image", true)
}

// MARK: - Tracking

print("\ntracking")

func box(_ x: Double, _ y: Double, _ size: Double = 0.2) -> CGRect {
    CGRect(x: x, y: y, width: size, height: size)
}

func detection(_ rect: CGRect, confidence: Float = 0.9, classIndex: Int = 0) -> Detection {
    Detection(classIndex: classIndex, confidence: confidence, boundingBox: rect, maskImage: nil)
}

// A steadily moving object should be reported once it has been seen enough times, and its box
// should follow the object rather than sitting where it started.
let tracker = FastTracker()
var lastOutput: [Detection] = []
for step in 0..<8 {
    lastOutput = tracker.update(with: [detection(box(0.1 + Double(step) * 0.05, 0.4))])
}
check("a moving object is tracked", lastOutput.count == 1, "got \(lastOutput.count) tracks")
if let tracked = lastOutput.first {
    let expected = 0.1 + 7 * 0.05
    check(
        "tracked box follows the object",
        abs(tracked.boundingBox.minX - expected) < 0.08,
        "box at \(String(format: "%.3f", tracked.boundingBox.minX)), object at \(String(format: "%.3f", expected))"
    )
}

// The point of the whole exercise: one frame where the detector sees nothing must not unblur.
let coasted = tracker.update(with: [])
check("a dropped frame still gets covered", coasted.count == 1, "got \(coasted.count) tracks")

// ...but a track that is never seen again is eventually let go, rather than blurring forever.
var abandoned: [Detection] = []
for _ in 0..<40 { abandoned = tracker.update(with: []) }
check("a long-gone object is dropped", abandoned.isEmpty, "still holding \(abandoned.count) tracks")

// A single weak blip is noise, not an object.
let noiseTracker = FastTracker()
let blip = noiseTracker.update(with: [detection(box(0.5, 0.5), confidence: 0.2)])
check("a one-frame weak blip is ignored", blip.isEmpty, "got \(blip.count) tracks")

// Two objects of different classes must not swap identities when they overlap.
let pairTracker = FastTracker()
for _ in 0..<4 {
    _ = pairTracker.update(with: [
        detection(box(0.2, 0.2), classIndex: 0),
        detection(box(0.22, 0.22), classIndex: 2),
    ])
}
let pair = pairTracker.update(with: [
    detection(box(0.2, 0.2), classIndex: 0),
    detection(box(0.22, 0.22), classIndex: 2),
])
check("overlapping objects of different classes stay separate", pair.count == 2, "got \(pair.count) tracks")
check(
    "each keeps its own class",
    Set(pair.map(\.classIndex)) == Set([0, 2]),
    "classes \(pair.map(\.classIndex).sorted())"
)

// FastTracker's whole reason to exist over plain ByteTrack: when something walks in front of a
// tracked object, the track should survive the pass-behind instead of being given up on after the
// usual couple of missed frames.
let occlusionTracker = FastTracker()
for _ in 0..<5 {
    _ = occlusionTracker.update(with: [detection(box(0.30, 0.40, 0.10), classIndex: 0)])
}
// A big object of another class moves over it, and the small one stops being detected.
var occluded: [Detection] = []
for _ in 0..<6 {
    occluded = occlusionTracker.update(with: [detection(box(0.25, 0.35, 0.30), classIndex: 5)])
}
check(
    "an occluded object stays covered while something passes in front",
    occluded.contains { $0.classIndex == 0 },
    "classes still tracked: \(occluded.map(\.classIndex).sorted())"
)

// Without an occluder, the same run of misses does give the track up, so the check above is
// testing occlusion handling rather than just a long buffer.
let plainTracker = FastTracker()
for _ in 0..<5 { _ = plainTracker.update(with: [detection(box(0.30, 0.40, 0.10), classIndex: 0)]) }
var unoccluded: [Detection] = []
for _ in 0..<6 { unoccluded = plainTracker.update(with: []) }
check(
    "a plain disappearance is given up on",
    !unoccluded.contains { $0.classIndex == 0 },
    "still tracking \(unoccluded.count)"
)

// MARK: - Highlight colour

print("\nhighlights")

/// Counts pixels close to the app's accent blue, which is what both marking modes draw in.
func accentPixelCount(in image: CIImage, size: CGSize) -> Int {
    let context = CIContext()
    let width = Int(size.width), height = Int(size.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        context.render(
            image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
            bounds: CGRect(origin: .zero, size: size),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }
    let target = (r: 0.200 * 255, g: 0.475 * 255, b: 0.965 * 255)
    var count = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let dr = abs(Double(pixels[index]) - target.r)
        let dg = abs(Double(pixels[index + 1]) - target.g)
        let db = abs(Double(pixels[index + 2]) - target.b)
        if dr < 40, dg < 40, db < 40 { count += 1 }
    }
    return count
}

let frameSize = CGSize(width: 400, height: 300)
let plainFrame = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: CGRect(origin: .zero, size: frameSize))

// A circular mask standing in for a segmentation silhouette.
let maskRect = CGRect(x: 140, y: 90, width: 120, height: 120)
let circleMask = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
    .cropped(to: maskRect)
    .applyingFilter("CIMaskToAlpha")
    .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: frameSize)))

let boxed = BlurCompositor.apply(
    [Detection(classIndex: 0, confidence: 0.9, boundingBox: CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4), maskImage: nil)],
    style: .pixelate, method: .box, strength: 20, to: plainFrame
)
let boxedBlue = accentPixelCount(in: boxed, size: frameSize)
check("box mode outlines the detection in accent blue", boxedBlue > 200, "only \(boxedBlue) accent pixels")

let segmented = BlurCompositor.apply(
    [Detection(classIndex: 0, confidence: 0.9, boundingBox: CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4), maskImage: circleMask)],
    style: .pixelate, method: .mask, strength: 20, to: plainFrame
)
let segmentedBlue = accentPixelCount(in: segmented, size: frameSize)
check("segmentation outlines the mask in the same accent blue", segmentedBlue > 200, "only \(segmentedBlue) accent pixels")

// MARK: - Watermark geometry

print("\nwatermark")
let frame = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
check("watermarking preserves the frame's extent", WatermarkRenderer.watermarked(frame).extent == frame.extent)
check(
    "outro frame fills the requested size",
    WatermarkRenderer.outroFrame(size: CGSize(width: 640, height: 480)).extent == CGRect(x: 0, y: 0, width: 640, height: 480)
)

// MARK: - Custom model import (opt-in)

// Needs a real model file, so it only runs when one is pointed at:
//     REDACT_MODEL=/path/to/yolo11n.pt swift run redact-selfcheck
// A .pt or .onnx goes through Ultralytics; a .mlpackage is compiled directly.
if let modelPath = ProcessInfo.processInfo.environment["REDACT_MODEL"] {
    print("\ncustom model · \(URL(fileURLWithPath: modelPath).lastPathComponent)")
    let source = URL(fileURLWithPath: modelPath)
    do {
        var lastFraction = 0.0
        let compiled = try ModelImporter.compiledModel(from: source) { line, fraction in
            lastFraction = fraction
            print("        \(line) \(Int(fraction * 100))%")
        }
        check("import reports 100% when finished", lastFraction == 1, "ended at \(Int(lastFraction * 100))%")
        check("compiled model exists on disk", FileManager.default.fileExists(atPath: compiled.path), compiled.path)
        check("compiled model outlives the temporary directory it was built in",
              !compiled.path.hasPrefix(FileManager.default.temporaryDirectory.path), compiled.path)

        let name = source.deletingPathExtension().lastPathComponent
        let detector = try YOLODetector(
            compiledModelURL: compiled, name: name, fileName: source.lastPathComponent, isBuiltIn: false
        )
        check("the imported model is the one selected", detector.info.name == name, "got \(detector.info.name)")
        check("it is reported as a custom model", detector.info.isBuiltIn == false)
        check("its classes are read from the model", detector.info.classCount > 0, "got \(detector.info.classCount)")
        check("its input size is read from the model", detector.info.inputSide > 0, "got \(detector.info.inputSide)")
        print("        task: \(detector.info.task), classes: \(detector.info.classCount), first: \(detector.classes.first?.name ?? "-")")
    } catch {
        check("importing the model succeeds", false, error.localizedDescription)
    }
}

print("\n\(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")")
exit(failures == 0 ? 0 : 1)
