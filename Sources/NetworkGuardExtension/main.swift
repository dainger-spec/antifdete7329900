import Foundation
import NetworkExtension

// Entry point of the network guard's system extension: hand control to NetworkExtension, which
// instantiates the filter class named in Info.plist (NEProviderClasses →
// NetworkGuardExtension.GuardFilterProvider, module-qualified), and listen on the Mach service the
// app holds profiles' processes through (GuardService).
autoreleasepool {
    NEProvider.startSystemExtensionMode()
    GuardService.shared.start()
}
dispatchMain()
