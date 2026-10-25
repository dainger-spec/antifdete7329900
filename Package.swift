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
]

var products: [Product] = [
    .library(name: "BrowserCore", targets: ["BrowserCore"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "PrivacyBrowser",
        dependencies: ["BrowserCore"],
        path: "Sources/PrivacyBrowser"
    )
)
products.append(.executable(name: "PrivacyBrowser", targets: ["PrivacyBrowser"]))
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
