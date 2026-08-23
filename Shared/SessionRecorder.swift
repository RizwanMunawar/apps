import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// Records the app's own window to an MP4 while you work.
///
/// This is deliberately *not* a media source. Redact's file mode takes a video in and writes a
/// redacted one out; this does the opposite job — it captures what the app looks like while it
/// runs, so a live camera session or a long file job can be shown to someone who was not sitting
/// there. That is why it lives beside the window chrome rather than in the file picker.
///
/// Only this app's window is captured, via `SCContentFilter(desktopIndependentWindow:)`. Whatever
/// else is on screen — mail, messages, another customer's footage in a different app — is never
/// in the frame, which matters for the same reason Redact exists.
@MainActor
public final class SessionRecorder: NSObject, ObservableObject {
    public enum RecorderError: LocalizedError {
        case noWindow
        case permissionDenied
        case writerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noWindow:
                return "Couldn't find the app's window to record."
            case .permissionDenied:
                return "Screen Recording permission is off. Turn it on in System Settings → "
                     + "Privacy & Security → Screen Recording, then try again."
            case .writerFailed(let reason):
                return "Couldn't write the recording: \(reason)"
            }
        }
    }

    public static let shared = SessionRecorder()

    @Published public private(set) var isRecording = false
    @Published public private(set) var isStarting = false
    /// Seconds since recording began, for the timer in the title bar.
    @Published public private(set) var elapsed: TimeInterval = 0
    /// Set when a recording finishes, so the UI can offer "Show in Finder".
    @Published public private(set) var lastOutputURL: URL?
    @Published public var errorMessage: String?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var startedAt: CMTime?
    private var ticker: Timer?

    /// Frames arrive on this queue; everything that touches writer state hops back to the main
    /// actor, so the writer is only ever driven from one place.
    private let frameQueue = DispatchQueue(label: "com.rizwanai.recorder.frames")

    private override init() { super.init() }

    public var elapsedLabel: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Start

    public func start() {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        errorMessage = nil

        Task {
            do {
                try await beginCapture()
                isRecording = true
                isStarting = false
                startTicker()
            } catch {
                isStarting = false
                await teardown()
                errorMessage = (error as? RecorderError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func beginCapture() async throws {
        guard let window = try await ownWindow() else { throw RecorderError.noWindow }

        // Capture at the window's backing resolution so text in the recording stays sharp on a
        // Retina display rather than being upscaled from points.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = Int(window.frame.width * scale)
        let height = Int(window.frame.height * scale)

        let configuration = SCStreamConfiguration()
        configuration.width = max(2, width - width % 2)
        configuration.height = max(2, height - height % 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6

        try prepareWriter(width: configuration.width, height: configuration.height)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// The `SCWindow` corresponding to this app's key window.
    ///
    /// Matching on `windowID` rather than on title or owning app: a title can change while
    /// recording, and matching the app alone would also pick up panels and popovers.
    private func ownWindow() async throws -> SCWindow? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // SCShareableContent is what fails first when the TCC permission is missing, so this
            // is where "you have not granted Screen Recording" actually surfaces.
            throw RecorderError.permissionDenied
        }

        let target = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            $0.isVisible
        }
        guard let target else { throw RecorderError.noWindow }

        let identifier = CGWindowID(target.windowNumber)
        return content.windows.first { $0.windowID == identifier }
    }

    private func prepareWriter(width: Int, height: Int) throws {
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "Redact session \(stamp.string(from: Date()))"
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(name).mp4")

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // ~8 Mbps at 1080p: good enough that pixelation blocks and mask edges stay
                // legible in the recording, which is the whole point of showing it to someone.
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecorderError.writerFailed("the H.264 encoder rejected these dimensions")
        }
        writer.add(input)

        self.writer = writer
        self.videoInput = input
        self.outputURL = url
        self.startedAt = nil
    }

    private func startTicker() {
        elapsed = 0
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed += 0.5
            }
        }
    }

    // MARK: - Stop

    public func stop() {
        guard isRecording else { return }
        isRecording = false
        ticker?.invalidate()
        ticker = nil

        Task {
            let url = outputURL
            await teardown()
            // Only advertise a file that actually exists: a stream that failed before its first
            // frame leaves a zero-byte MP4 behind, and offering "Show in Finder" for that is
            // worse than saying nothing.
            if let url, (try? url.checkResourceIsReachable()) == true,
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                lastOutputURL = url
            } else {
                lastOutputURL = nil
                errorMessage = "The recording came out empty and was discarded."
                if let url { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private func teardown() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        if let videoInput, writer?.status == .writing {
            videoInput.markAsFinished()
            await writer?.finishWriting()
        }
        writer = nil
        videoInput = nil
        startedAt = nil
    }

    public func revealLastRecording() {
        guard let url = lastOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func dismissLastRecording() {
        lastOutputURL = nil
    }
}

// MARK: - Capture callbacks

extension SessionRecorder: SCStreamOutput {
    public nonisolated func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit emits frames even when nothing changed, flagged as such. Appending
        // those is harmless for playback but inflates the file, so they are dropped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        Task { @MainActor [weak self] in
            self?.append(sampleBuffer, at: presentationTime)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, at time: CMTime) {
        guard let writer, let videoInput else { return }

        if writer.status == .unknown {
            guard writer.startWriting() else {
                errorMessage = RecorderError.writerFailed(
                    writer.error?.localizedDescription ?? "unknown error"
                ).errorDescription
                return
            }
            writer.startSession(atSourceTime: time)
            startedAt = time
        }

        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }
}

extension SessionRecorder: SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording else { return }
            // The usual cause is the window closing mid-recording. Keep whatever was captured
            // rather than throwing the file away.
            self.errorMessage = "Recording stopped: \(error.localizedDescription)"
            self.stop()
        }
    }
}
