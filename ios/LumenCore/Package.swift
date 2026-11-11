// swift-tools-version:5.9
// Lumen for iPhone — the app's core: models, storage, the sessions catalogue, address input, search
// engines, the account's document of rights. CryptoKit, and the Mac's platform-independent core
// BrowserCore (this repository's root package) for the vault and the sync — the same code as the
// Mac's, so the format is the same by construction (ios/SYNC_STEP1.md). `swift test` runs it on any
// Mac without a simulator.
import Foundation
import PackageDescription

// The root package's identity is its folder's name, which is the checkout's (CI: the repository's
// name; a worktree: its own): read it from where this manifest is.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let rootIdentity = root.lastPathComponent.lowercased()

let package = Package(
    name: "LumenCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LumenCore", targets: ["LumenCore"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(name: "LumenCore", dependencies: [.product(name: "BrowserCore", package: rootIdentity)]),
        // The account server's own test vectors (its docs/entitlement-test-vectors.json), read by path.
        .testTarget(name: "LumenCoreTests", dependencies: ["LumenCore", .product(name: "BrowserCore", package: rootIdentity)],
                    exclude: ["entitlement-test-vectors.json"]),
    ]
)
