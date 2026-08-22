import Foundation

/// Every app the shell can launch. Add a case here (plus a home-tile glyph in `AppTile` and a
/// destination in `AppContainer`) to register a new app — nothing else in the shell changes.
enum AppID: String, CaseIterable, Identifiable {
    case redact

    var id: String { rawValue }

    var name: String {
        switch self {
        case .redact: return "Redact"
        }
    }

    var tagline: String {
        switch self {
        case .redact: return "Blur faces & objects live on your webcam"
        }
    }
}
