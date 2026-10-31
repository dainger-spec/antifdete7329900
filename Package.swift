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
//   TunnelCore      Platform-independent WebRTC relay logic for the packet tunnel: IPv4/IPv6
//                   UDP packets, STUN/TURN server, SOCKS5 UDP codec, profile routes. Tested on
//                   Linux and macOS like BrowserCore.
//   TunnelTransport macOS only: the relay's network side (SOCKS5 over Network.framework) and
//                   a UDP host for the TURN server outside the tunnel (CI harness).
//   PacketTunnelExtension  macOS only: the NEPacketTunnelProvider system extension's executable.
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
        path: "Tests/BrowserCoreTests"
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
    .executableTarget(
        name: "pbupdate",
        dependencies: ["BrowserCore"],
        path: "Sources/pbupdate"
    ),
]

var products: [Product] = [
    .library(name: "BrowserCore", targets: ["BrowserCore"]),
    .library(name: "TunnelCore", targets: ["TunnelCore"]),
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
        name: "PacketTunnelExtension",
        dependencies: ["TunnelCore", "TunnelTransport"],
        path: "Sources/PacketTunnelExtension"
    ),
    .target(
        name: "ObjCExceptions",
        path: "Sources/ObjCExceptions"
    ),
    .executableTarget(
        name: "PrivacyBrowser",
        dependencies: ["BrowserCore", "TunnelCore", "TunnelTransport", "ObjCExceptions"],
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
products.append(.executable(name: "PacketTunnelExtension", targets: ["PacketTunnelExtension"]))
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
