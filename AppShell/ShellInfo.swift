import AppCore

/// The shell's visible product name. Deliberately different from `apps-releases`, the bundle id
/// and binary name, which stays as-is internally (Info.plist, Package.swift product).
enum ShellInfo {
    static let displayName = Brand.name
}
