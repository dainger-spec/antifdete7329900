// swift-tools-version:5.9
// Lumen for iPhone — the app's core: models, storage, the sessions catalogue, address input, search
// engines, the account's document of rights. Foundation and CryptoKit only, so `swift test` runs it
// on any Mac without a simulator.
import PackageDescription

let package = Package(
    name: "LumenCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LumenCore", targets: ["LumenCore"])],
    targets: [
        .target(name: "LumenCore"),
        // The account server's own test vectors (its docs/entitlement-test-vectors.json), read by path.
        .testTarget(name: "LumenCoreTests", dependencies: ["LumenCore"], exclude: ["entitlement-test-vectors.json"]),
    ]
)
