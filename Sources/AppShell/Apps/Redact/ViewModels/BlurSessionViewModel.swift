import CoreGraphics
import CoreVideo
import Foundation

@MainActor
final class BlurSessionViewModel: ObservableObject {
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var activeBlurCount = 0
    @Published var errorMessage: String?

    @Published var selectedClassIndices: Set<Int> = [0] { didSet { settings.selectedClasses = selectedClassIndices } }
    @Published var blurStyle: BlurStyle = .pixelate { didSet { settings.style = blurStyle } }
    @Published var blurMethod: BlurMethod = .box { didSet { settings.method = blurMethod } }
    @Published var blurStrength: Double = 25 { didSet { settings.strength = blurStrength } }

    private let camera = CameraCaptureService()
    private let settings = PipelineSettings()
    private var processor: FrameProcessor?
    private var frameCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    init() {
        settings.selectedClasses = selectedClassIndices
        settings.style = blurStyle
        settings.method = blurMethod
        settings.strength = blurStrength
    }

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        Task {
            do {
                let processor = try self.processor ?? FrameProcessor()
                self.processor = processor
                try await camera.requestAccessAndStart()

                let settings = self.settings
                camera.onFrame = { [weak self, settings, processor] pixelBuffer in
                    let classes = settings.selectedClasses
                    let style = settings.style
                    let method = settings.method
                    let strength = settings.strength
                    let result = processor.process(pixelBuffer: pixelBuffer, selectedClasses: classes, style: style, method: method, strength: strength)
                    guard let image = result.image else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.previewImage = image
                        self.activeBlurCount = result.classIndices.count
                        self.recordFrame()
                    }
                }
                isRunning = true
                isStarting = false
            } catch {
                errorMessage = error.localizedDescription
                isStarting = false
            }
        }
    }

    func stop() {
        camera.onFrame = nil
        camera.stop()
        isRunning = false
        fps = 0
        activeBlurCount = 0
    }

    func toggleClass(_ index: Int) {
        if selectedClassIndices.contains(index) {
            selectedClassIndices.remove(index)
        } else {
            selectedClassIndices.insert(index)
        }
    }

    func selectAllClasses() {
        selectedClassIndices = Set(DetectableClass.all.map { $0.index })
    }

    func clearAllClasses() {
        selectedClassIndices = []
    }

    private func recordFrame() {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 1.0 {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            fpsWindowStart = now
        }
    }
}
