// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppsReleases",
    platforms: [.macOS(.v14)],
    // Product name is the literal binary/bundle name ("apps-releases"); the target name has to
    // be a valid Swift module identifier, so it can't carry the hyphen itself.
    products: [.executable(name: "apps-releases", targets: ["AppShell"])],
    targets: [
        .executableTarget(
            name: "AppShell",
            path: "Sources/AppShell",
            resources: [
                .copy("Apps/Redact/Resources/yolo26n-seg.mlpackage"),
                .copy("Resources/Fonts/Archivo-Variable.ttf")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        )
    ]
)
