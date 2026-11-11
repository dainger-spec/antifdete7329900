// swift-tools-version:5.9
//
// PrivacyBrowser — multi-profile WebKit browser prototype for macOS.
//
// Targets:
//   BrowserCore     Platform-independent core: crypto, encrypted profile store,
//                   password vault, encrypted directory archives, sync format.
//                   Builds on macOS (CryptoKit + CommonCrypto) and on Linux
//                   (swift-crypto) so the security-critical code can be unit
//                   tested in CI without a Mac.
//   TunnelCore      Platform-independent WebRTC relay logic: STUN/TURN server, SOCKS5 UDP codec,
//                   the relay's route. Tested on Linux and macOS like BrowserCore.
//   NetworkGuardCore Platform-independent rules of the network guard (what a profile's process
//                   may reach while its WebRTC goes through its proxy), tested on Linux and macOS.
//   TunnelTransport macOS only: the relay's network side (SOCKS5 over Network.framework), the
//                   TURN server's UDP socket on loopback, the proxy's UDP check.
//   NetworkGuardExtension  macOS only: the content filter's system extension (docs/TUNNEL.md).
//                   Packaged and signed into the app only by `NE=1 scripts/build-app.sh`.
//   ObjCExceptions  macOS only: an Objective-C `@try` around a call, for Safari's code called
//                   from Swift tasks (PBCatchException).
//   PrivacyBrowser  macOS app (SwiftUI + AppKit + WebKit). macOS only.
//   pbupdate        Makes and checks the signed update feed (scripts/release.sh, docs/UPDATES.md)
//                   with BrowserCore's own checks. macOS and Linux.
//   UpdateInstaller macOS only: replaces the app with a checked release (code signature, process
//                   list, the swap), tested on real bundles by UpdateInstallerTests.
//   PrivacyBrowserUpdater  macOS only: the installer helper, Contents/Helpers/PrivacyBrowser
//                   Updater.app, which the app starts at the end of a quit (docs/UPDATES.md §3).
//
import PackageDescription

var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []

#if os(Linux)
// CryptoKit is Apple-only. swift-crypto exposes the same API surface on Linux.
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

var targets: [Target] = [
    .target(
        name: "BrowserCore",
        dependencies: coreDependencies,
        path: "Sources/BrowserCore"
    ),
    .testTarget(
        name: "BrowserCoreTests",
        dependencies: ["BrowserCore"],
        path: "Tests/BrowserCoreTests",
        // Read by the tests from the checkout (#filePath): the server's test vectors, as it publishes them.
        exclude: ["Fixtures"]
    ),
    .target(
        name: "TunnelCore",
        dependencies: coreDependencies,
        path: "Sources/TunnelCore"
    ),
    .testTarget(
        name: "TunnelCoreTests",
        dependencies: ["TunnelCore"],
        path: "Tests/TunnelCoreTests"
    ),
    .target(
        name: "NetworkGuardCore",
        dependencies: ["TunnelCore"],
        path: "Sources/NetworkGuardCore"
    ),
    .testTarget(
        name: "NetworkGuardCoreTests",
        dependencies: ["NetworkGuardCore"],
        path: "Tests/NetworkGuardCoreTests"
    ),
    .executableTarget(
        name: "pbupdate",
        dependencies: ["BrowserCore"],
        path: "Sources/pbupdate"
    ),
]

var products: [Product] = [
    .library(name: "BrowserCore", targets: ["BrowserCore"]),
    .library(name: "TunnelCore", targets: ["TunnelCore"]),
    .library(name: "NetworkGuardCore", targets: ["NetworkGuardCore"]),
    .executable(name: "pbupdate", targets: ["pbupdate"]),
]

#if os(macOS)
targets.append(contentsOf: [
    .target(
        name: "TunnelTransport",
        dependencies: ["TunnelCore"],
        path: "Sources/TunnelTransport"
    ),
    .executableTarget(
        name: "NetworkGuardExtension",
        dependencies: ["NetworkGuardCore"],
        path: "Sources/NetworkGuardExtension"
    ),
    // The system virtual camera's frames (docs/CAMERA.md): drawn in the app's own process from the
    // profile's settings (SystemCameraFeed) and handed to the extension — which runs as macOS's
    // camera user and cannot read the person's app group — through its sink stream.
    .target(
        name: "CameraRendering",
        path: "Sources/CameraRendering"
    ),
    // The system virtual camera (a CMIO Camera Extension; docs/CAMERA.md). It publishes the device
    // and passes on the frames the app sends to its sink stream; no BrowserCore dependency, so the
    // extension stays small. Built and laid out beside the app with CAM=check (CI checks it
    // compiles against the SDK), signed and embedded with CAM=1 (scripts/build-app.sh).
    .executableTarget(
        name: "CameraExtension",
        dependencies: ["CameraRendering"],
        path: "Sources/CameraExtension"
    ),
    .target(
        name: "ObjCExceptions",
        path: "Sources/ObjCExceptions"
    ),
    .executableTarget(
        name: "PrivacyBrowser",
        dependencies: ["BrowserCore", "TunnelCore", "TunnelTransport", "NetworkGuardCore", "ObjCExceptions", "CameraRendering"],
        path: "Sources/PrivacyBrowser"
    ),
    .target(
        name: "UpdateInstaller",
        dependencies: ["BrowserCore"],
        path: "Sources/UpdateInstaller"
    ),
    .executableTarget(
        name: "PrivacyBrowserUpdater",
        dependencies: ["BrowserCore", "UpdateInstaller"],
        path: "Sources/PrivacyBrowserUpdater"
    ),
    .testTarget(
        name: "UpdateInstallerTests",
        dependencies: ["BrowserCore", "UpdateInstaller"],
        path: "Tests/UpdateInstallerTests"
    ),
])
products.append(.executable(name: "PrivacyBrowser", targets: ["PrivacyBrowser"]))
products.append(.executable(name: "PrivacyBrowserUpdater", targets: ["PrivacyBrowserUpdater"]))
products.append(.executable(name: "NetworkGuardExtension", targets: ["NetworkGuardExtension"]))
products.append(.executable(name: "CameraExtension", targets: ["CameraExtension"]))
#endif

let package = Package(
    name: "PrivacyBrowser",
    // macOS 14 is the minimum: WKWebsiteDataStore(forIdentifier:) and
    // WKWebsiteDataStore.proxyConfigurations were introduced in macOS 14 (Sonoma).
    // Without them neither persistent per-profile isolation nor per-profile
    // proxies are available through public API.
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: packageDependencies,
    targets: targets
)
