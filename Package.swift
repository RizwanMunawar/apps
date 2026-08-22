// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Redact",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Redact", targets: ["Redact"])],
    targets: [
        .executableTarget(
            name: "Redact",
            path: "Sources/Redact",
            resources: [.copy("Resources/yolo26n-seg.mlpackage")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        )
    ]
)
