import Foundation
import NetworkExtension

// Entry point of the system extension: hand control to NetworkExtension, which instantiates
// the provider class named in Info.plist (NEProviderClasses → PacketTunnelProvider).
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
