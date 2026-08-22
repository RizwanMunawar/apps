// swift-tools-version: 5.9
import PackageDescription

// Three targets, mirroring the repo layout: the shell at the top level, each app in its own
// folder beside it, and a shared design core both sides link against.
//
//   Shared/   -> AppCore   design tokens, typography, zoom, reusable controls
//   redact/   -> Redact    the Redact app, self-contained (models/services/vm/views + model)
//   AppShell/ -> AppShell   the launcher: splash, sidebar, title bar, routing (the executable)
//
// Dependencies point one way only — AppShell -> Redact -> AppCore — so an app can never reach
// back into the shell, and adding a second app means a new folder plus one more target here.
let package = Package(
    name: "AppsReleases",
    platforms: [.macOS(.v14)],
    // Product name is the literal binary/bundle name ("apps-releases"); target names have to be
    // valid Swift module identifiers, so they can't carry the hyphen themselves.
    products: [.executable(name: "apps-releases", targets: ["AppShell"])],
    targets: [
        .target(name: "AppCore", path: "Shared"),
        .target(
            name: "Redact",
            dependencies: ["AppCore"],
            path: "redact",
            resources: [.copy("Resources/yolo26n-seg.mlpackage")]
        ),
        .executableTarget(
            name: "AppShell",
            dependencies: ["AppCore", "Redact"],
            path: "AppShell",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        ),
        // XCTest and swift-testing both ship with Xcode, not the Command Line Tools, so a normal
        // test target can't even compile on a CLT-only machine. This is a plain executable
        // instead: `swift run redact-selfcheck` exercises the offline media pipeline end to end
        // anywhere Swift is installed. It links Redact's public processing API rather than
        // reaching in with `@testable`, which only works in debug and would break release builds
        // (and therefore build-dmg.sh) outright.
        .executableTarget(
            name: "redact-selfcheck",
            dependencies: ["Redact"],
            path: "Tools/RedactSelfCheck"
        )
    ]
)
