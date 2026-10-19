// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ScreenFrame",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ScreenFrame",
            path: "Sources/ScreenFrame"
        )
    ],
    swiftLanguageModes: [.v5]
)
