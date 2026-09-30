import AppCore
import CoreGraphics
import CoreVideo
import Foundation

@MainActor
final class BlurSessionViewModel: ObservableObject {
    /// Matches `AppID.redact.rawValue` in the shell: the key the sidebar's live dot reads. A raw
    /// string rather than a shared constant because the dependency only points one way, so Redact
    /// must not import the launcher.
    static let appID = "redact"

    @Published private(set) var previewImage: CGImage?
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var activeBlurCount = 0
    @Published var errorMessage: String?

    /// What the loaded model is, for the info popover.
    @Published private(set) var modelInfo: ModelInfo?
    /// Classes the loaded model can detect. Empty until the model finishes loading.
    @Published private(set) var classes: [DetectableClass] = []
    @Published private(set) var isLoadingModel = false
    /// Nil until checked. Drives the note about what a `.pt` or `.onnx` would need.
    @Published private(set) var canConvertModels: Bool?
    @Published private(set) var modelStatus: String?
    /// Rough completion of a model import, for the progress readout next to the status line.
    @Published private(set) var modelProgress: Double = 0

    /// Faces by default: they are what people most often need hidden, and covering a whole person
    /// to hide one face blurs far more of the frame than it has to.
    @Published var selectedClassIndices: Set<Int> = [FaceDetector.classIndex] { didSet { settings.selectedClasses = selectedClassIndices } }
    @Published var blurStyle: BlurStyle = .pixelate { didSet { settings.style = blurStyle } }
    @Published var blurMethod: BlurMethod = .box { didSet { settings.method = blurMethod } }
    @Published var blurStrength: Double = 25 { didSet { settings.strength = blurStrength } }
    /// Steadies the blur by following objects between frames rather than trusting each frame's
    /// detections on their own. On by default: without it, a single missed frame is a visible
    /// flash of whatever was meant to stay hidden.
    @Published var trackingEnabled = true { didSet { settings.tracking = trackingEnabled } }

    /// False while Redact's screen is off-screen. The camera keeps running so switching apps
    /// doesn't interrupt a session, but building a `CGImage` nobody is going to draw is the
    /// single biggest per-frame allocation, so that part is skipped until the view comes back.
    private var isPreviewVisible = true

    private let camera = CameraCaptureService()
    private let settings = PipelineSettings()
    /// Read from the camera queue, written from the main actor, hence the lock inside.
    private let visibility = VisibilityFlag()
    private var processor: FrameProcessor?
    private var frameCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    // The *compiled* model is remembered, not the file the user picked. Remembering the original
    // means re-running the whole Ultralytics conversion on every launch, which takes half a minute
    // and silently falls back to the built-in model if that file has since moved or Python is not
    // where it was — so the model you chose quietly stops being the one in use.
    private static let compiledPathKey = "redact.customModel.compiledPath"
    private static let nameKey = "redact.customModel.name"
    private static let fileNameKey = "redact.customModel.fileName"

    init() {
        settings.selectedClasses = selectedClassIndices
        settings.style = blurStyle
        settings.method = blurMethod
        settings.strength = blurStrength
        settings.tracking = trackingEnabled

        // Load the model up front rather than on the first frame, so the class picker and the
        // info popover have something to show the moment the app opens.
        Task { await loadInitialModel() }
        // Probing spawns subprocesses, so keep it off the main thread and out of the launch path.
        // `self` is still being initialised here, so the probe is started as a detached task that
        // captures nothing and hands the answer back through a plain closure.
        Self.probeConversionSupport { [weak self] available in
            self?.canConvertModels = available
        }
    }

    private static func probeConversionSupport(_ report: @escaping @MainActor (Bool) -> Void) {
        Task.detached(priority: .background) {
            let available = ModelImporter.ultralyticsAvailable()
            await MainActor.run { report(available) }
        }
    }

    // MARK: - Model

    /// The shared `FrameProcessor` (and its CoreML model, which is expensive to load), so file
    /// processing reuses the exact same instance instead of loading the model a second time.
    func sharedProcessor() throws -> FrameProcessor {
        if let processor { return processor }
        let processor = try FrameProcessor()
        adopt(processor)
        return processor
    }

    private func loadInitialModel() async {
        // Reload a previously chosen model straight from its compiled form: no conversion, no
        // dependency on the original file still being there.
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.compiledPathKey),
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let name = defaults.string(forKey: Self.nameKey) ?? url.deletingPathExtension().lastPathComponent
            let fileName = defaults.string(forKey: Self.fileNameKey) ?? url.lastPathComponent

            isLoadingModel = true
            modelStatus = "Loading model"
            let restored = await Task.detached { () -> FrameProcessor? in
                guard let detector = try? YOLODetector(
                    compiledModelURL: url, name: name, fileName: fileName, isBuiltIn: false
                ) else { return nil }
                return FrameProcessor(detector: detector)
            }.value
            isLoadingModel = false
            modelStatus = nil

            if let restored {
                adopt(restored)
                return
            }
            // The stored model is unusable, so stop pointing at it.
            forgetCustomModel()
        }
        await loadBuiltInModel()
    }

    private func forgetCustomModel() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.compiledPathKey)
        defaults.removeObject(forKey: Self.nameKey)
        defaults.removeObject(forKey: Self.fileNameKey)
    }

    private func loadBuiltInModel() async {
        isLoadingModel = true
        modelStatus = "Loading model"
        modelProgress = 0
        let result = await Task.detached { () -> Result<FrameProcessor, Error> in
            do { return .success(try FrameProcessor()) } catch { return .failure(error) }
        }.value
        isLoadingModel = false
        modelStatus = nil
        switch result {
        case .success(let processor): adopt(processor)
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    /// Loads a model the user picked. PyTorch and ONNX files are converted to CoreML first, which
    /// can take a while, hence the running status text.
    @discardableResult
    func loadModel(at url: URL, remember: Bool = true) async -> Bool {
        guard !isLoadingModel else { return false }
        isLoadingModel = true
        errorMessage = nil
        modelStatus = "Reading the model"
        modelProgress = 0

        let name = url.deletingPathExtension().lastPathComponent
        let fileName = url.lastPathComponent

        let result = await Task.detached { [weak self] () -> Result<(FrameProcessor, URL), Error> in
            do {
                let compiled = try ModelImporter.compiledModel(from: url) { line, fraction in
                    Task { @MainActor in
                        self?.modelStatus = line
                        self?.modelProgress = fraction
                    }
                }
                let detector = try YOLODetector(
                    compiledModelURL: compiled, name: name, fileName: fileName, isBuiltIn: false
                )
                return .success((FrameProcessor(detector: detector), compiled))
            } catch {
                return .failure(error)
            }
        }.value

        isLoadingModel = false
        modelStatus = nil
        modelProgress = 0

        switch result {
        case .success(let (processor, compiled)):
            stop()
            adopt(processor)
            if remember {
                let defaults = UserDefaults.standard
                defaults.set(compiled.path, forKey: Self.compiledPathKey)
                defaults.set(name, forKey: Self.nameKey)
                defaults.set(fileName, forKey: Self.fileNameKey)
            }
            return true
        case .failure(let error):
            errorMessage = error.localizedDescription
            return false
        }
    }

    func useBuiltInModel() async {
        guard modelInfo?.isBuiltIn != true else { return }
        stop()
        forgetCustomModel()
        processor = nil
        await loadBuiltInModel()
    }

    private func adopt(_ processor: FrameProcessor) {
        self.processor = processor
        modelInfo = processor.info
        classes = processor.classes
        // A custom model's classes have nothing to do with the previous model's indices, so start
        // from the default rather than carrying a stale selection across: faces, whether from
        // Vision or the model's own class, or the first class for a model with no faces at all.
        // A detection-only model cannot honour mask mode, so fall back rather than leaving a
        // selection that quietly behaves as box anyway.
        if processor.info.supportsSegmentation == false, blurMethod == .mask { blurMethod = .box }
        let valid = Set(classes.map(\.index))
        let kept = selectedClassIndices.intersection(valid)
        let fallback = classes.first { $0.name.lowercased() == FaceDetector.className } ?? classes.first
        selectedClassIndices = kept.isEmpty ? Set(fallback.map { [$0.index] } ?? []) : kept
    }

    /// Called as Redact's screen appears and disappears. Leaving the session running is the
    /// point; this only controls whether frames are turned into images for it.
    func setPreviewVisible(_ visible: Bool) {
        isPreviewVisible = visible
        visibility.isVisible = visible
        // Drop the last frame on the way out so a full-resolution image isn't pinned in memory
        // for as long as the app stays open on another screen.
        if !visible { previewImage = nil }
    }

    // MARK: - Camera

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        Task {
            do {
                let processor = try sharedProcessor()
                try await camera.requestAccessAndStart()

                let settings = self.settings
                let visibility = self.visibility
                // One tracker for this camera run, rebuilt on every start so a new session never
                // inherits tracks from the last one.
                let tracker = FastTracker()
                camera.onFrame = { [weak self, settings, processor, visibility, tracker] pixelBuffer in
                    let classes = settings.selectedClasses
                    let style = settings.style
                    let method = settings.method
                    let strength = settings.strength
                    let wantsImage = visibility.isVisible
                    let result = processor.process(
                        pixelBuffer: pixelBuffer, selectedClasses: classes, style: style,
                        method: method, strength: strength, producingImage: wantsImage,
                        tracker: settings.tracking ? tracker : nil
                    )
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let image = result.image { self.previewImage = image }
                        self.activeBlurCount = result.classIndices.count
                        self.recordFrame()
                    }
                }
                isRunning = true
                isStarting = false
                AppActivity.shared.setActive(Self.appID, true)
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
        previewImage = nil
        AppActivity.shared.setActive(Self.appID, false)
    }

    // MARK: - Classes

    func toggleClass(_ index: Int) {
        if selectedClassIndices.contains(index) {
            selectedClassIndices.remove(index)
        } else {
            selectedClassIndices.insert(index)
        }
    }

    func selectAllClasses() {
        selectedClassIndices = Set(classes.map(\.index))
    }

    func clearAllClasses() {
        selectedClassIndices = []
    }

    /// The shapes this model can produce. A plain detection model has no mask branch, so offering
    /// "Mask" would be a control that silently does nothing.
    var availableMethods: [BlurMethod] {
        guard modelInfo?.supportsSegmentation == true else { return [.box] }
        return BlurMethod.allCases
    }

    /// Short label for the class dropdown's button, e.g. "Person" or "12 classes".
    var classSelectionLabel: String {
        switch selectedClassIndices.count {
        case 0: return "Nothing selected"
        case 1:
            guard let index = selectedClassIndices.first,
                  let match = classes.first(where: { $0.index == index }) else { return "1 class" }
            return match.displayName
        case classes.count where !classes.isEmpty: return "All \(classes.count) classes"
        default: return "\(selectedClassIndices.count) classes"
        }
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
