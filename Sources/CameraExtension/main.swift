import CoreMediaIO
import Foundation

// Entry point of the system virtual camera's extension (docs/CAMERA.md). Hands control to
// CoreMediaIO, which runs the provider that publishes the virtual camera device; the device
// passes on the frames the app sends to its sink stream (SystemCameraFeed). Mirrors the shape of
// NetworkGuardExtension/main.swift (a system extension's executable that starts its service and
// then runs its run loop).
let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
