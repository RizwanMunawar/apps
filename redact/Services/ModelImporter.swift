import CoreML
import Foundation

enum ModelImportError: LocalizedError {
    case unsupportedExtension(String)
    case ultralyticsMissing
    case exportFailed(String)
    case exportProducedNothing

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let ext):
            return "Redact can't read a .\(ext) file. Pick a .pt, .onnx, .mlpackage or .mlmodel file."
        case .ultralyticsMissing:
            return "Converting a .pt or .onnx model needs Ultralytics on this device. Install it with 'pip install ultralytics coremltools', then try again. A .mlpackage file works without it."
        case .exportFailed(let reason):
            return "The model couldn't be converted to CoreML. \(reason)"
        case .exportProducedNothing:
            return "The conversion finished but produced no CoreML model."
        }
    }
}

/// Turns a model file the user picked into a compiled `.mlmodelc` Redact can load.
///
/// CoreML files are compiled directly. PyTorch and ONNX files have to go through Ultralytics'
/// own exporter, which is a Python tool, so those are converted by shelling out to `yolo export`
/// rather than reimplementing the conversion.
public enum ModelImporter {
    /// Extensions the file picker offers and this importer accepts. Anything else is rejected.
    public static let allowedExtensions = ["pt", "onnx", "mlpackage", "mlmodel", "mlmodelc"]

    /// Whether a `.pt` or `.onnx` could be converted right now.
    ///
    /// Worth answering before the user picks a file rather than after: the conversion is the only
    /// part of this app that depends on anything being installed, and finding that out from a
    /// failure dialog after choosing a model is a poor way to learn it. Everything else, including
    /// the bundled model and any `.mlpackage`, works with nothing installed at all.
    ///
    /// Probing runs subprocesses, so the answer is computed once and cached.
    public static func ultralyticsAvailable() -> Bool {
        if let cached = cachedAvailability { return cached }
        let available = locateUltralytics() != nil
        cachedAvailability = available
        return available
    }

    private nonisolated(unsafe) static var cachedAvailability: Bool?

    /// Shown when it isn't there, so the fix is on screen rather than in a support thread.
    public static let installHint = "pip install ultralytics coremltools"

    /// Where converted and compiled models are kept between launches.
    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("apps-releases/Redact/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// - Parameter status: called with a short line and a rough completion fraction as each step
    ///   starts, so a long Python export doesn't look like a hang.
    ///
    ///   The fraction is by stage, not by bytes: `yolo export` reports nothing machine-readable
    ///   while it runs, so a real percentage would be invented. The stages are honest about where
    ///   the time goes, which is the conversion itself.
    public static func compiledModel(from url: URL, status: @escaping (String, Double) -> Void) throws -> URL {
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { throw ModelImportError.unsupportedExtension(ext) }

        switch ext {
        case "mlmodelc":
            status("Ready", 1)
            return url
        case "mlpackage", "mlmodel":
            status("Compiling the model", 0.4)
            let compiled = try compile(url, named: url.deletingPathExtension().lastPathComponent)
            status("Ready", 1)
            return compiled
        default:
            status("Reading the model", 0.05)
            let exported = try exportToCoreML(url, status: status)
            status("Compiling the model", 0.85)
            let compiled = try compile(exported, named: url.deletingPathExtension().lastPathComponent)
            status("Ready", 1)
            return compiled
        }
    }

    private static func compile(_ url: URL, named name: String) throws -> URL {
        let compiled = try MLModel.compileModel(at: url)
        // compileModel writes into a temp directory the system is free to clear, so move the
        // result somewhere durable before handing it back.
        let destination = storeDirectory.appendingPathComponent("\(name).mlmodelc")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: compiled, to: destination)
        return destination
    }

    // MARK: - Ultralytics

    /// Runs `yolo export ... format=coreml` on a copy of the file in a scratch directory, so the
    /// exporter's output lands there instead of beside the user's original model.
    private static func exportToCoreML(_ url: URL, status: @escaping (String, Double) -> Void) throws -> URL {
        status("Looking for Ultralytics", 0.1)
        guard let tool = locateUltralytics() else { throw ModelImportError.ultralyticsMissing }
        status("Converting to CoreML", 0.2)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let localCopy = workDir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: localCopy)

        let process = Process()
        process.executableURL = tool.executable
        process.arguments = tool.arguments + ["export", "model=\(localCopy.path)", "format=coreml", "imgsz=640"]
        process.currentDirectoryURL = workDir
        process.environment = environmentWithToolPaths()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Drain before waiting: a full pipe buffer would block the exporter forever.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8) ?? ""
            throw ModelImportError.exportFailed(lastMeaningfulLine(of: text))
        }

        let produced = try FileManager.default
            .contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .filter { ["mlpackage", "mlmodel"].contains($0.pathExtension.lowercased()) }
        guard let exported = produced.first else { throw ModelImportError.exportProducedNothing }

        // Move it out of the scratch directory the defer above is about to delete.
        let kept = storeDirectory.appendingPathComponent(exported.lastPathComponent)
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: exported, to: kept)
        status("Converted", 0.8)
        return kept
    }

    private struct Tool {
        let executable: URL
        let arguments: [String]
    }

    /// A packaged .app launches with a bare PATH, so the usual install locations are searched by
    /// hand rather than relying on the environment.
    private static func locateUltralytics() -> Tool? {
        let searchPaths = toolSearchPaths()

        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("yolo")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return Tool(executable: candidate, arguments: [])
            }
        }

        // No `yolo` shim, but the package may still be importable from a python on PATH.
        for directory in searchPaths {
            for name in ["python3", "python"] {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
                if canImportUltralytics(python: candidate) {
                    return Tool(executable: candidate, arguments: ["-m", "ultralytics.cfg"])
                }
            }
        }
        return nil
    }

    private static func canImportUltralytics(python: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import ultralytics"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = environmentWithToolPaths()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func toolSearchPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.local/bin", "\(home)/miniconda3/bin", "\(home)/anaconda3/bin",
            "\(home)/.pyenv/shims", "\(home)/venv/bin", "\(home)/.venv/bin",
        ]
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: inherited.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func environmentWithToolPaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = toolSearchPaths().joined(separator: ":")
        return environment
    }

    /// Python tracebacks end with the line that actually explains the failure, so surface that
    /// rather than the first line or the whole wall of output.
    private static func lastMeaningfulLine(of text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "No output from the exporter." }
        return last
    }
}
