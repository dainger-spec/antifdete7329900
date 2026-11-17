#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Where a proxy that a relay of the app's carries (`ProxySettings.localRelay`: a share link's,
/// `Kind.xray`, or an OpenVPN connection, `ProxySettings.openVPN`) is reached while the relay runs:
/// SOCKS5 on 127.0.0.1, at the relay's port, with a login made for that run. Everything that
/// connects through a profile's proxy asks here first (`connectable`), so such a proxy is only ever
/// reached through its relay — and, with no relay running for it, through nothing: the answer is nil
/// and the caller fails closed (`ProxyConfigurationFactory` gives such a profile a proxy that does
/// not exist, as it gives every store it does not trust). Never the link's server or the VPN server
/// itself: only the relay talks to those.
///
/// In the manager, a route is added when its relay is up and removed when it stops (`LocalRelays`,
/// which starts either kind). In a profile's own process, the manager hands the profile's route over
/// right after the grant (`encodeRecord`, `readRecord`): that process starts no relay and knows no
/// other.
public final class ProxyRoutes: @unchecked Sendable {
    public static let shared = ProxyRoutes()

    private let lock = NSLock()
    /// By what the proxy is known by (`key(of:)`): the relays running for it, newest last.
    private var routes: [String: [(id: UUID, route: Route)]] = [:]

    /// A relay's local side.
    public struct Route: Codable, Equatable, Sendable {
        public var port: Int
        public var username: String
        public var password: String

        public init(port: Int, username: String, password: String) {
            self.port = port
            self.username = username
            self.password = password
        }
    }

    public init() {}

    /// What a relay's route is known by, here and in the record a profile's process is given: a
    /// link's text (`ProxySettings.link`); for an OpenVPN connection, a digest of its configuration
    /// and login — another configuration, or another login to the same server, is another relay's.
    /// Nil for a proxy no relay carries.
    public static func key(of proxy: ProxySettings) -> String? {
        switch proxy.localRelay {
        case .xray?:
            return proxy.link
        case .openVPN?:
            guard let openVPN = proxy.openVPN else { return nil }
            let identity = [openVPN.configuration, proxy.username ?? "", proxy.password ?? ""].joined(separator: "\u{0}")
            return "openvpn:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        case nil:
            return nil
        }
    }

    /// `route` as the relay of whatever is known by `key` (`key(of:)`), under the relay's own `id`.
    public func add(_ route: Route, for key: String, id: UUID) {
        lock.withLock {
            routes[key, default: []].removeAll { $0.id == id }
            routes[key, default: []].append((id, route))
        }
    }

    public func remove(id: UUID) {
        lock.withLock {
            for key in Array(routes.keys) {
                routes[key]?.removeAll { $0.id == id }
                if routes[key]?.isEmpty == true { routes[key] = nil }
            }
        }
    }

    /// The relay running for `proxy` (the newest); nil for a proxy no relay carries, or for one none
    /// runs for.
    public func route(for proxy: ProxySettings) -> Route? {
        guard let key = Self.key(of: proxy) else { return nil }
        return lock.withLock { routes[key]?.last?.route }
    }

    /// What to connect to for `proxy`: itself for an HTTP or SOCKS5 proxy; for one a relay carries,
    /// SOCKS5 to its relay, with the profile's bypass list kept; nil when no relay runs for it — never
    /// the link's server or the VPN server, which nothing but the relay may be sent to.
    public func connectable(_ proxy: ProxySettings) -> ProxySettings? {
        guard proxy.localRelay != nil else { return proxy }
        guard let route = route(for: proxy) else { return nil }
        return Self.socks5(route, excludedDomains: proxy.excludedDomains)
    }

    public static func socks5(_ route: Route, excludedDomains: [String] = []) -> ProxySettings {
        ProxySettings(kind: .socks5, host: XrayConfig.listenAddress, port: route.port, username: route.username,
                      password: route.password, excludedDomains: excludedDomains)
    }

    /// Every route, by key (`key(of:)`).
    public func all() -> [String: Route] {
        lock.withLock { routes.compactMapValues { $0.last?.route } }
    }

    // MARK: The record a profile's process is given

    static let magic = Data("PBR1".utf8)
    static let maximumLength = 1 << 20

    /// One route of the record: `link` is the key it is known by (`key(of:)`) — named so since the
    /// links' relays, the first that had routes.
    struct Entry: Codable {
        var link: String
        var route: Route
    }

    /// `PBR1`, the length (4 bytes, big-endian), then JSON of the routes — written right after the
    /// grant on the profile's standard input, always, an empty list included, so that the process
    /// reads exactly what was written. It holds the relays' logins (and a link's text, its key): wipe
    /// it once written.
    public static func encodeRecord(_ routes: [String: Route]) throws -> Data {
        let entries = routes.sorted { $0.key < $1.key }.map { Entry(link: $0.key, route: $0.value) }
        let json = try JSONEncoder().encode(entries)
        var record = magic
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { record.append(contentsOf: $0) }
        record.append(json)
        return record
    }

    /// Reads one record (`encodeRecord`) from a stream: `next(n)` returns up to `n` bytes, or nothing
    /// at its end. Exactly the record is read, nothing after it.
    public static func readRecord(_ next: (Int) -> Data?) throws -> [String: Route] {
        func exactly(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let chunk = next(count - data.count), !chunk.isEmpty else {
                    throw CoreError.corruptData("proxy routes end after \(data.count) of \(count) bytes")
                }
                data.append(chunk)
            }
            return data
        }
        guard try exactly(magic.count) == magic else { throw CoreError.unsupportedFormat("not the proxy routes") }
        let length = Int(try exactly(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length > 0, length <= maximumLength else { throw CoreError.corruptData("proxy routes length \(length)") }
        let entries = try JSONDecoder().decode([Entry].self, from: exactly(length))
        var routes: [String: Route] = [:]
        for entry in entries { routes[entry.link] = entry.route }
        return routes
    }

    /// Overwrites a record once it has been written where it was going.
    public static func erase(_ record: inout Data) {
        record.resetBytes(in: 0..<record.count)
        record = Data()
    }
}
