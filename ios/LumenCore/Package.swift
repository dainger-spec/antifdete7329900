// swift-tools-version:5.9
// Lumen for iPhone — the app's core: models, storage, the sessions catalogue, address input, search
// engines. Foundation only, so `swift test` runs it on any Mac (and Linux) without a simulator.
import PackageDescription

let package = Package(
    name: "LumenCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LumenCore", targets: ["LumenCore"])],
    targets: [
        .target(name: "LumenCore"),
        .testTarget(name: "LumenCoreTests", dependencies: ["LumenCore"]),
    ]
)
