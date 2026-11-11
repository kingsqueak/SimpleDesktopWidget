// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SimpleDesktopWidget",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SimpleDesktopWidget",
            path: "Sources/SimpleDesktopWidget"
        )
    ],
    swiftLanguageModes: [.v5]
)
