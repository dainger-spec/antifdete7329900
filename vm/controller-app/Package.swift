// swift-tools-version: 5.9
//
// VM controller for the VM-based Safari direction (docs/VM_ARCHITECTURE.md).
//
// Targets:
//   VMControllerCore  Platform-independent logic: locating tart and the bash
//                     prototype, parsing `tart` and script output into stages,
//                     the stage state machine, process-group spawning. Builds
//                     and is unit tested on Linux too.
//   VMController      Command-line controller.
//   VMLauncher        SwiftUI app (macOS only). scripts/build-app.sh wraps it
//                     into VMLauncher.app.
//
import PackageDescription

var products: [Product] = [
    .executable(name: "VMController", targets: ["VMController"]),
]

var targets: [Target] = [
    .target(
        name: "VMControllerCore",
        path: "Sources/VMControllerCore"
    ),
    .executableTarget(
        name: "VMController",
        dependencies: ["VMControllerCore"],
        path: "Sources/VMController"
    ),
    .testTarget(
        name: "VMControllerCoreTests",
        dependencies: ["VMControllerCore"],
        path: "Tests/VMControllerCoreTests"
    ),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "VMLauncher",
        dependencies: ["VMControllerCore"],
        path: "Sources/VMLauncher"
    )
)
products.append(.executable(name: "VMLauncher", targets: ["VMLauncher"]))
#endif

let package = Package(
    name: "VMController",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
