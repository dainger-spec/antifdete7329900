import Foundation
open class NEVPNProtocol { public var passwordReference: Data? }
open class NETunnelProviderProtocol: NEVPNProtocol { public var providerConfiguration: [String: Any]? }
public final class NEIPv4Route { public static func `default`() -> NEIPv4Route { NEIPv4Route() } }
public final class NEIPv6Route { public static func `default`() -> NEIPv6Route { NEIPv6Route() } }
public final class NEIPv4Settings { public init(addresses: [String], subnetMasks: [String]) {}; public var includedRoutes: [NEIPv4Route]? }
public final class NEIPv6Settings { public init(addresses: [String], networkPrefixLengths: [NSNumber]) {}; public var includedRoutes: [NEIPv6Route]? }
public final class NEDNSSettings { public init(servers: [String]) {} }
public final class NEPacketTunnelNetworkSettings {
    public init(tunnelRemoteAddress: String) {}
    public var ipv4Settings: NEIPv4Settings?; public var ipv6Settings: NEIPv6Settings?; public var mtu: NSNumber?; public var dnsSettings: NEDNSSettings?
}
public enum NEProviderStopReason: Int { case none }
open class NEPacketTunnelProvider {
    public var protocolConfiguration: NEVPNProtocol? { nil }
    public let packetFlow = NEPacketTunnelFlow()
    public init() {}
    open func startTunnel(options: [String: NSObject]?) async throws {}
    open func stopTunnel(with reason: NEProviderStopReason) async {}
    public func setTunnelNetworkSettings(_ settings: NEPacketTunnelNetworkSettings?) async throws {}
}
