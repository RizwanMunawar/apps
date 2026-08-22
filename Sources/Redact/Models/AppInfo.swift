import Foundation

/// Reads the version straight from the bundle so it can never drift from what's actually
/// installed — always keep `CFBundleShortVersionString` in Info.plist in sync with the release
/// tag this build ships under (see Scripts/build-dmg.sh).
enum AppInfo {
    static var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? ""
    }

    // Source lives in the private RizwanMunawar/rizwanai monorepo (apps/redact), but its Releases
    // aren't publicly downloadable from a private repo, so binaries ship from apps-releases, a
    // small public repo shared by every app in this family (tagged "redact-v1.0.0" etc, one
    // prefix per app, so they can all live in the same repo's Releases).
    static let releaseURL = URL(string: "https://github.com/RizwanMunawar/apps-releases/releases/tag/redact-v1.0.0")!
}
