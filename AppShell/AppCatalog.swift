import Foundation

/// Every app the shell can launch. Add a case here (plus a mark in `AppSidebar` and a
/// destination in `AppContainer`) to register a new app — nothing else in the shell changes.
enum AppID: String, CaseIterable, Identifiable {
    case redact

    var id: String { rawValue }

    var name: String {
        switch self {
        case .redact: return "Redact"
        }
    }

    /// The one-line description under the app's name in the sidebar.
    var tagline: String {
        switch self {
        case .redact: return "Hide anything"
        }
    }

}
