import Foundation

/// Reads the version straight from the bundle so it can never drift from what's actually
/// installed — always keep `CFBundleShortVersionString` in Info.plist in sync with the release
/// tag this build ships under (see Scripts/build-dmg.sh).
enum AppInfo {
    static var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? ""
    }

    // Redact ships as part of the apps-releases shell (one .dmg contains every app), so this
    // points at the shell's own release rather than a Redact-only artifact.
    static let releaseURL = URL(string: "https://github.com/RizwanMunawar/apps/releases/tag/v1.0.0")!
}
