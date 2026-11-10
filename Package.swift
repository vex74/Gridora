// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LaunchOS",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LaunchOS",
            path: "Sources/LaunchOS"
        )
    ]
)
