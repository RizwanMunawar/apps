import Foundation

/// Which apps are currently doing something (Redact's camera running, a file mid-export). Apps
/// publish into it; the shell's sidebar reads it to light the green dot on a row. Lives in
/// AppCore rather than the shell so an app can report activity without importing the launcher —
/// which would make the dependency arrow point backwards.
@MainActor
public final class AppActivity: ObservableObject {
    public static let shared = AppActivity()

    @Published public private(set) var activeIDs: Set<String> = []

    private init() {}

    public func setActive(_ id: String, _ isActive: Bool) {
        if isActive { activeIDs.insert(id) } else { activeIDs.remove(id) }
    }

    public func isActive(_ id: String) -> Bool { activeIDs.contains(id) }
}
