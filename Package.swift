// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveBlur",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LiveBlur", targets: ["LiveBlur"])],
    targets: [
        .executableTarget(
            name: "LiveBlur",
            path: "Sources/LiveBlur",
            resources: [.copy("Resources/yolo26n-seg.mlpackage")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        )
    ]
)
