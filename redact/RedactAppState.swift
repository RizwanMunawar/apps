import AppCore
import Foundation

/// Redact's live state, owned outside the view hierarchy.
///
/// SwiftUI tears a screen's `@StateObject`s down as soon as you navigate away from it, which
/// would kill the capture session the moment you clicked another app in the sidebar. Holding the
/// view models here instead means switching apps, or going back to the App Hub, leaves the camera
/// running and every setting exactly where it was; coming back re-attaches to the same session.
///
/// The cost of keeping an app resident is one capture session and one loaded model, so the view
/// models release the expensive part instead: while the screen is off-screen no preview images
/// are built, which is where nearly all of the per-frame memory went.
@MainActor
public final class RedactAppState: ObservableObject {
    public static let shared = RedactAppState()

    let session: BlurSessionViewModel
    let file: FileProcessingViewModel

    /// Which mode the screen was left in, so returning to Redact doesn't reset it to the camera.
    @Published var mode: RedactMode = .live

    private init() {
        let session = BlurSessionViewModel()
        self.session = session
        self.file = FileProcessingViewModel(session: session)
    }
}
