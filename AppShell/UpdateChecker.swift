import AppKit
import Foundation

/// Checks GitHub Releases for a newer build and fetches the installer.
///
/// The app's own version is `CFBundleShortVersionString` in Info.plist, which is linked into the
/// binary and copied into the bundle by Scripts/build-app.sh. That string is the single source of
/// truth; a release is "newer" when its tag compares higher.
///
/// Installing is deliberately hand-off rather than silent: the download lands in Downloads and
/// the disk image is opened, so the usual drag-to-Applications step still happens in front of the
/// user. Replacing a running app in place needs a helper tool and a signed, notarised update
/// feed, which this ad-hoc-signed build has no way to verify.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case downloaded(URL)
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let downloadURL: URL?
    }

    @Published private(set) var state: State = .idle
    /// The newest published release, held regardless of whether it is newer than what is
    /// installed, so hovering the version can show what that release contained.
    @Published private(set) var latestRelease: Release?

    /// Shown in the App Hub footer and the update popover.
    let currentVersion: String = {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()

    private static let repository = "RizwanMunawar/apps"
    private static let lastCheckKey = "redact.lastUpdateCheck"
    /// Don't hit the API on every launch; once a day is plenty for a desktop app.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    var updateAvailable: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    /// - Parameter force: bypasses the once-a-day throttle, for the explicit "Check now" button.
    func check(force: Bool = false) async {
        guard !isBusy else { return }
        if !force {
            let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
            if last > 0, Date().timeIntervalSince1970 - last < Self.checkInterval { return }
        }

        state = .checking
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            latestRelease = release
            state = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// One click: look, and if there is something newer, start fetching it. No dialog to dismiss
    /// and nothing to confirm, because "check and then update" is the only thing the button was
    /// ever going to be used for.
    func checkAndUpdate() async {
        await check(force: true)
        if let release = updateAvailable { download(release) }
    }

    /// Fills in `latestRelease` for the hover card without disturbing `state`, so pointing at the
    /// version never looks like it started something.
    func loadReleaseNotesIfNeeded() async {
        guard latestRelease == nil, !isBusy else { return }
        latestRelease = try? await fetchLatest()
    }

    func download(_ release: Release) {
        guard let downloadURL = release.downloadURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        state = .downloading(0)
        Task {
            do {
                let (temporaryURL, _) = try await URLSession.shared.download(from: downloadURL)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let destination = downloads.appendingPathComponent(downloadURL.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                state = .downloaded(destination)
                // Opening the disk image mounts it and shows the drag-to-Applications window.
                NSWorkspace.shared.open(destination)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - GitHub

    private func fetchLatest() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
            throw UpdateError.badResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw UpdateError.noReleases
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = json["html_url"] as? String,
              let pageURL = URL(string: page)
        else { throw UpdateError.badResponse }

        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
        let downloadURL = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:))

        return Release(
            version: tag,
            notes: (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: pageURL,
            downloadURL: downloadURL
        )
    }

    enum UpdateError: LocalizedError {
        case badResponse
        case noReleases

        var errorDescription: String? {
            switch self {
            case .badResponse: return "Couldn't read the release list from GitHub."
            case .noReleases: return "No releases have been published yet."
            }
        }
    }

    /// Compares dotted version strings numerically, ignoring a leading "v" on either side, so
    /// "v1.10.0" correctly beats "1.9.0" where a plain string comparison would not.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
