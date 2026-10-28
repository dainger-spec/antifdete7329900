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
//   SafariBridge    macOS only: Objective-C calls into Safari.framework's private classes for the
//                   experimental Safari window, each inside @try (docs/SAFARI_FRAMEWORK_PATH.md).
//   PrivacyBrowser  macOS app (SwiftUI + AppKit + WebKit). macOS only.
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
]

var products: [Product] = [
    .library(name: "BrowserCore", targets: ["BrowserCore"]),
    .library(name: "TunnelCore", targets: ["TunnelCore"]),
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
        name: "SafariBridge",
        path: "Sources/SafariBridge",
        cSettings: [.unsafeFlags(["-fobjc-arc"])]
    ),
    .executableTarget(
        name: "PrivacyBrowser",
        dependencies: ["BrowserCore", "TunnelCore", "TunnelTransport", "SafariBridge"],
        path: "Sources/PrivacyBrowser"
    ),
])
products.append(.executable(name: "PrivacyBrowser", targets: ["PrivacyBrowser"]))
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
