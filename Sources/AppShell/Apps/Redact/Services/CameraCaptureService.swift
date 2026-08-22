@preconcurrency import AVFoundation
import CoreVideo

enum CameraError: LocalizedError {
    case accessDenied
    case noDevice
    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Camera access was denied. Enable it in System Settings > Privacy & Security > Camera."
        case .noDevice: return "No camera was found on this Mac."
        }
    }
}

/// Captures live frames from the default video device and hands each one off via `onFrame`.
/// Frames are delivered on a dedicated background queue, never the main thread.
final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // Lazy so simply constructing this service (e.g. as a view model's stored property, before
    // the user has clicked "Start camera") never allocates a capture session.
    lazy var session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let output = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "com.redact.cameraFrames", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "com.redact.cameraSession", qos: .userInitiated)

    func requestAccessAndStart() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw CameraError.accessDenied }
        default:
            throw CameraError.accessDenied
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .hd1280x720
                if self.session.canAddInput(input) { self.session.addInput(input) }
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                self.session.commitConfiguration()
                self.session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
