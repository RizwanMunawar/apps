import Foundation

/// Finds Redact's resource bundle, without relying on SwiftPM's generated `Bundle.module`.
///
/// `Bundle.module` looks in exactly two places: next to `Bundle.main.bundleURL`, and an absolute
/// path into the build directory baked in at compile time. Neither is right for a packaged app.
/// For an `.app`, `bundleURL` is the `.app` itself, while resources belong in `Contents/Resources`
/// where a bundle can actually be signed — so the first lookup always misses and it falls through
/// to the build path.
///
/// That fallback is worse than it looks. On the machine that built the app it happens to exist,
/// so everything appears to work; on anyone else's machine it does not, and `Bundle.module` calls
/// `fatalError` on launch. Here it also pointed inside `~/Downloads`, a TCC-protected folder, so
/// the lookup blocked in `opendir` waiting on a permission prompt that never came.
///
/// So: look where the resources actually are, and keep `Bundle.module` only as the last resort
/// for `swift run` and the self-check, where it is correct.
enum RedactResources {
    private static let bundleName = "AppsReleases_Redact.bundle"

    static let bundle: Bundle = {
        // A packaged .app: Contents/Resources/AppsReleases_Redact.bundle.
        if let resources = Bundle.main.resourceURL,
           let found = Bundle(url: resources.appendingPathComponent(bundleName)) {
            return found
        }
        // Beside the executable, which is where a plain `swift build` leaves it.
        let beside = Bundle.main.bundleURL.appendingPathComponent(bundleName)
        if let found = Bundle(url: beside) {
            return found
        }
        return Bundle.module
    }()

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext)
    }
}
