#if os(macOS)
import Foundation

/// What the app asks of the network guard, over XPC, through the extension's Mach service
/// (`NEMachServiceName` in its Info.plist). Only Lumen signed by the guard's own team is let in
/// (`NSXPCConnection.setCodeSigningRequirement`). Everything goes as JSON (`GuardRegistration`,
/// `GuardReport`), so that both sides decode it the same way the tests do.
@objc public protocol NetworkGuardControl {
    /// The guard's version (its CFBundleVersion: a new one each build) and whether its filter runs.
    func hello(reply: @escaping (String, Bool) -> Void)
    /// Holds a profile's process to its proxy: `GuardRegistration`, JSON. False, with the reason,
    /// when it does not (unreadable, not a process of Lumen's, the filter not running).
    func hold(_ registration: Data, reply: @escaping (Bool, String?) -> Void)
    /// The process stopped, or its profile no longer needs holding.
    func release(_ pid: Int32, reply: @escaping () -> Void)
    /// What the guard did for `pid`: `GuardReport`, JSON.
    func report(_ pid: Int32, reply: @escaping (Data) -> Void)
}

/// Names both sides agree on.
public enum NetworkGuardNames {
    /// The app's Info.plist key holding the guard extension's bundle identifier (NE builds only).
    public static let appInfoKey = "PBGuardExtensionBundleIdentifier"
    /// The extension's Info.plist key holding the app's bundle identifier (the only client let in).
    public static let extensionAppKey = "PBGuardAppIdentifier"
}
#endif
