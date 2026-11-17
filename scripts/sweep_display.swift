// The main display set to a mode of the given size, for the sweep's small-screen state
// (scripts/sweep_state.sh): `swift scripts/sweep_display.swift 1280 800`. Lists the display's modes,
// picks the one of that size (at one point per pixel, the non-Retina one, when there is a choice),
// and says what the display is afterwards. Exit 0 when the display has that size, 1 when not.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let width = arguments.count > 1 ? Int(arguments[1]) ?? 1280 : 1280
let height = arguments.count > 2 ? Int(arguments[2]) ?? 800 : 800
let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
for mode in modes {
    print("mode \(mode.width)×\(mode.height) points, \(mode.pixelWidth)×\(mode.pixelHeight) pixels")
}
let fitting = modes.filter { $0.width == width && $0.height == height }
let chosen = fitting.first { $0.pixelWidth == $0.width } ?? fitting.first
if let chosen {
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayWithDisplayMode(config, display, chosen, nil)
    let status = CGCompleteDisplayConfiguration(config, .permanently)
    print("set \(chosen.width)×\(chosen.height) (\(chosen.pixelWidth)×\(chosen.pixelHeight) pixels): \(status.rawValue)")
} else {
    print("no mode of \(width)×\(height) on this display")
}
let now = CGDisplayCopyDisplayMode(display)
print("the display is now \(now?.width ?? 0)×\(now?.height ?? 0) points, \(now?.pixelWidth ?? 0)×\(now?.pixelHeight ?? 0) pixels")
exit(now?.width == width && now?.height == height ? 0 : 1)
