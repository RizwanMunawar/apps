import Foundation

/// Reads the version straight from the bundle so it can never drift from what's actually
/// installed — always keep `CFBundleShortVersionString` in Info.plist in sync with the GitHub
/// release tag this build ships under (see Scripts/build-dmg.sh).
enum AppInfo {
    static var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? ""
    }

    static let releaseURL = URL(string: "https://github.com/RizwanMunawar/rizwanai/releases/tag/redact-v1.0.0")!
}
