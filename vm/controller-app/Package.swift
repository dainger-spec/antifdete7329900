// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VMController",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VMController",
            path: "Sources"
        )
    ]
)
