import AppCore
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Drives the "Process file" workflow, which runs in four steps: pick a file, look at it, apply
/// the blur, then export. Blurring is deliberately not automatic on load, so the settings can be
/// dialled in against the real footage before anything is processed.
@MainActor
final class FileProcessingViewModel: ObservableObject {
    enum Kind { case image, video }

    enum Stage: Equatable {
        /// Nothing picked yet.
        case empty
        /// A file is loaded and showing, untouched.
        case loaded
        /// The blur is running.
        case processing
        /// A processed result is ready to export.
        case done
        case failed(String)
    }

    @Published private(set) var stage: Stage = .empty
    @Published private(set) var inputURL: URL?
    @Published private(set) var kind: Kind?
    @Published private(set) var progress: Double = 0

    /// The untouched file, shown as soon as it's picked.
    @Published private(set) var sourceImage: CGImage?
    /// Frames arriving from the encoder while a video is processing, so the blur is visible as it
    /// happens rather than hidden behind a progress bar.
    @Published private(set) var livePreview: CGImage?

    @Published private(set) var resultImage: CGImage?
    @Published private(set) var resultVideoURL: URL?

    /// Set when an export finishes, so the UI can confirm it rather than leaving the user
    /// wondering whether the button did anything. Cleared when the message is dismissed.
    @Published var exportOutcome: ExportOutcome?

    struct ExportOutcome: Identifiable {
        let id = UUID()
        let succeeded: Bool
        let url: URL
        let message: String
    }

    /// True while the finished result is being written to wherever the user chose.
    @Published private(set) var isExporting = false

    var isProcessing: Bool { stage == .processing }
    /// Applying is blocked mid-export: the export is reading the very result a new run would
    /// throw away.
    var canApply: Bool { (stage == .loaded || stage == .done) && !isExporting }
    var canExport: Bool { stage == .done && !isExporting }
    /// Everything that changes what the blur looks like is frozen while a file job is running,
    /// since those settings were already baked into the run in progress.
    var settingsLocked: Bool { isProcessing || isExporting }

    /// Reads the shared blur settings (classes, style, method, strength) from the same view model
    /// the live camera uses, so the two modes never drift out of sync with each other.
    private unowned let session: BlurSessionViewModel
    private var mediaProcessor: MediaProcessor?

    init(session: BlurSessionViewModel) {
        self.session = session
    }

    // MARK: - Step 1: pick

    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.message = "Pick an image or video to blur"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func load(url: URL) {
        reset()
        inputURL = url
        let fileKind: Kind = Self.isVideo(url) ? .video : .image
        kind = fileKind

        if fileKind == .image {
            // A thumbnail, not the full image: a 48MP photo held as a CGImage is hundreds of
            // megabytes, and this copy exists only to be drawn in the preview pane. Processing
            // re-reads the file at full resolution when the blur is applied.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1600,
                  ] as CFDictionary) else {
                stage = .failed("That image couldn't be opened.")
                return
            }
            sourceImage = image
        }
        stage = .loaded
    }

    // MARK: - Step 3: apply

    func apply() {
        guard let inputURL, let kind, canApply else { return }

        guard let processor = try? session.sharedProcessor() else {
            stage = .failed("The detection model isn't loaded yet.")
            return
        }
        let mediaProcessor = self.mediaProcessor ?? MediaProcessor(frameProcessor: processor)
        self.mediaProcessor = mediaProcessor

        // Drop any previous result so re-applying with new settings can't leave the old export
        // sitting around as the thing the Export button would write.
        discardResult()
        progress = 0
        livePreview = nil
        stage = .processing

        let settings = MediaBlurSettings(
            selectedClasses: session.selectedClassIndices, style: session.blurStyle,
            method: session.blurMethod, strength: session.blurStrength,
            tracking: session.trackingEnabled
        )

        switch kind {
        case .video:
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("redact-\(UUID().uuidString)").appendingPathExtension("mp4")
            Task { [weak self] in
                do {
                    try await mediaProcessor.processVideo(
                        inputURL: inputURL, outputURL: outputURL, settings: settings,
                        preview: { frame in
                            Task { @MainActor [weak self] in self?.livePreview = frame }
                        },
                        progress: { value in
                            Task { @MainActor [weak self] in self?.progress = value }
                        }
                    )
                    guard let self else { return }
                    self.resultVideoURL = outputURL
                    self.progress = 1
                    self.stage = .done
                } catch {
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        case .image:
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let image = try mediaProcessor.processImage(at: inputURL, settings: settings)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.resultImage = image
                        self.progress = 1
                        self.stage = .done
                    }
                } catch {
                    await MainActor.run { [weak self] in self?.stage = .failed(error.localizedDescription) }
                }
            }
        }
    }

    // MARK: - Step 4: export

    /// Everything Redact exports is named after the source with the product's name appended, so
    /// a file is recognisable later without opening it.
    nonisolated static func exportName(for source: URL?, kind: Kind) -> String {
        let base = source?.deletingPathExtension().lastPathComponent ?? "redact"
        return "\(base) - rizwanai-apps.\(kind == .video ? "mp4" : "png")"
    }

    /// How long the "please wait" is held for, even when the write finishes instantly. Without it
    /// the panel closes and nothing visibly happens, which reads as the button not working.
    private static let minimumExportDisplay: Duration = .seconds(5)
    /// Writing a file that is already on this disk should be near-instant; if it somehow isn't,
    /// say so rather than sitting on a spinner forever.
    private static let exportTimeout: Duration = .seconds(30)

    func export() {
        guard canExport, let kind else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = kind == .image ? [.png] : [.mpeg4Movie]
        panel.nameFieldStringValue = Self.exportName(for: inputURL, kind: kind)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        let image = resultImage
        let videoURL = resultVideoURL

        Task { [weak self] in
            async let held: Void = { try? await Task.sleep(for: Self.minimumExportDisplay) }()

            let outcome: ExportOutcome
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await Task.detached(priority: .userInitiated) {
                            switch kind {
                            case .image:
                                guard let image, let data = Self.pngData(from: image) else {
                                    throw ExportError.nothingToWrite
                                }
                                try data.write(to: destination)
                            case .video:
                                guard let videoURL else { throw ExportError.nothingToWrite }
                                // A save panel can hand back a path that already exists, and
                                // copyItem refuses to overwrite, so clear the way first.
                                try? FileManager.default.removeItem(at: destination)
                                try FileManager.default.copyItem(at: videoURL, to: destination)
                            }
                        }.value
                    }
                    group.addTask {
                        try await Task.sleep(for: Self.exportTimeout)
                        throw ExportError.timedOut
                    }
                    // Whichever finishes first decides it; cancel the loser.
                    try await group.next()
                    group.cancelAll()
                }
                outcome = ExportOutcome(
                    succeeded: true, url: destination,
                    message: "\(kind == .video ? "Video" : "Image") exported successfully."
                )
            } catch {
                outcome = ExportOutcome(
                    succeeded: false, url: destination,
                    message: "The export failed. \(error.localizedDescription)"
                )
            }

            await held
            self?.isExporting = false
            self?.exportOutcome = outcome
        }
    }

    enum ExportError: LocalizedError {
        case nothingToWrite
        case timedOut

        var errorDescription: String? {
            switch self {
            case .nothingToWrite: return "There is no processed result to export yet."
            case .timedOut: return "Writing the file took too long and was stopped."
            }
        }
    }

    func revealExport() {
        guard let outcome = exportOutcome, outcome.succeeded else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outcome.url])
    }

    // MARK: - Reset

    func reset() {
        discardResult()
        inputURL = nil
        kind = nil
        sourceImage = nil
        livePreview = nil
        progress = 0
        stage = .empty
    }

    /// Back to the untouched file, keeping it loaded so settings can be changed and re-applied.
    func discardResult() {
        resultImage = nil
        if let resultVideoURL {
            try? FileManager.default.removeItem(at: resultVideoURL)
        }
        resultVideoURL = nil
    }

    private static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    nonisolated private static func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
