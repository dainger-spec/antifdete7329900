import Foundation

/// What checking a proxy found: asked THROUGH the proxy (never around it), a geolocation service
/// answered — or nothing did. Kept with the proxy in the list, so the list shows which proxies
/// work, where they exit and how slow they are, without checking again.
///
/// A proxy is alive when a service's answer came back through it. Where it exits (IP, country,
/// time zone) is filled in when that answer said so; a proxy can be alive with its country unknown
/// (a service that answered without a location, e.g. rate-limited).
public struct ProxyCheckResult: Codable, Equatable, Sendable {
    public enum Failure: String, Codable, Sendable {
        /// Nothing answered through the proxy in time: it is down, refused the connection, cannot
        /// reach the services, or its address does not resolve.
        case noAnswer
        /// The proxy asked for a user name and password (407) and the entry has none.
        case needsCredentials
        /// The entry's settings cannot be applied (the check would have had to go direct).
        case invalidSettings
    }

    public var checkedAt: Date
    /// Nil: alive. Otherwise why the proxy is taken for dead.
    public var failure: Failure?
    /// The address the service saw the request come from: the proxy's exit IP.
    public var exitIP: String?
    /// ISO 3166-1 alpha-2, upper case.
    public var countryCode: String?
    /// IANA identifier of where the exit IP is.
    public var timeZoneIdentifier: String?
    /// How long the answering request took through the proxy (connection, tunnel and answer).
    public var latencyMilliseconds: Int?

    public init(checkedAt: Date = Date(), failure: Failure? = nil, exitIP: String? = nil, countryCode: String? = nil,
                timeZoneIdentifier: String? = nil, latencyMilliseconds: Int? = nil) {
        self.checkedAt = checkedAt
        self.failure = failure
        self.exitIP = exitIP
        self.countryCode = countryCode
        self.timeZoneIdentifier = timeZoneIdentifier
        self.latencyMilliseconds = latencyMilliseconds
    }

    public var isAlive: Bool { failure == nil }

    /// A service answered through the proxy in `latency` seconds; `location` is what it said, when
    /// it said where.
    public static func alive(location: ProxyLocation?, latency: TimeInterval?, at time: Date = Date()) -> ProxyCheckResult {
        ProxyCheckResult(checkedAt: time, failure: nil, exitIP: location?.exitIP, countryCode: location?.countryCode,
                         timeZoneIdentifier: location?.timeZoneIdentifier,
                         latencyMilliseconds: latency.map { max(1, Int(($0 * 1000).rounded())) })
    }

    public static func dead(_ failure: Failure, at time: Date = Date()) -> ProxyCheckResult {
        ProxyCheckResult(checkedAt: time, failure: failure)
    }

    /// What this check found, as the lookup at a launch through `proxy` remembers it
    /// (`ProfileConfiguration.lastProxyLocation`): nil unless the proxy answered with a time zone.
    public func location(for proxy: ProxySettings) -> ProxyLocation? {
        guard isAlive, let timeZoneIdentifier else { return nil }
        return ProxyLocation(timeZoneIdentifier: timeZoneIdentifier, countryCode: countryCode,
                             proxyEndpoint: ProxyLocation.endpoint(of: proxy), resolvedAt: checkedAt, exitIP: exitIP)
    }
}

/// One proxy of the list: its settings as a profile would use them, the name the user gave it, and
/// what its last check found.
public struct ProxyListEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The user's name for it ("Berlin 1"). Empty: it is shown by its address.
    public var label: String
    public var proxy: ProxySettings
    public var addedAt: Date
    public var lastCheck: ProxyCheckResult?

    public init(id: UUID = UUID(), label: String = "", proxy: ProxySettings, addedAt: Date = Date(),
                lastCheck: ProxyCheckResult? = nil) {
        self.id = id
        self.label = label
        self.proxy = proxy
        self.addedAt = addedAt
        self.lastCheck = lastCheck
    }

    /// "host:port", an IPv6 host in brackets.
    public var address: String {
        let host = proxy.host.contains(":") ? "[\(proxy.host)]" : proxy.host
        return "\(host):\(proxy.port)"
    }

    /// The label, or the address without one.
    public var displayName: String { label.isEmpty ? address : label }

    private enum CodingKeys: String, CodingKey {
        case id, label, proxy, addedAt, lastCheck
    }

    /// Tolerant: a check result that no longer decodes (written by a later build) is dropped, never
    /// a reason to lose the proxy.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        proxy = try c.decode(ProxySettings.self, forKey: .proxy)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
        lastCheck = (try? c.decodeIfPresent(ProxyCheckResult.self, forKey: .lastCheck)) ?? nil
    }
}

/// The proxies the user keeps at hand, to give to profiles (`ProxyAssignment`) and to check.
///
/// Stored encrypted at the vault root as `proxies.bin`: AES-GCM under `HKDF(VMK, "proxy-list")`,
/// AAD `proxy-list:v1:<vaultID>` — the credentials in it are as safe as a profile's. This Mac's
/// only, never synced (as `settings.bin`): the profiles a proxy was given to carry their own copy
/// of it, which syncs with them.
public struct ProxyList: Codable, Equatable, Sendable {
    /// More than any provider's list a person would paste; keeps the file and the checks bounded.
    public static let maximumEntries = 10_000

    var format = 1
    public private(set) var entries: [ProxyListEntry]

    public init(entries: [ProxyListEntry] = []) {
        self.entries = entries
    }

    public func entry(_ id: UUID) -> ProxyListEntry? { entries.first { $0.id == id } }

    /// What makes two entries the same proxy: kind, host (in any case), port, TLS and credentials —
    /// what a profile connects with. Another user name is another proxy (gateway proxies pick the
    /// exit from it); the bypass list is not part of it.
    public static func identity(of proxy: ProxySettings) -> String {
        [proxy.kind.rawValue, proxy.host.lowercased(), String(proxy.port), proxy.tlsToProxy ? "tls" : "",
         proxy.username ?? "", proxy.password ?? ""].joined(separator: "\u{0}")
    }

    public struct AddResult: Equatable, Sendable {
        /// The new entries, in the order given.
        public var added: [UUID] = []
        /// Proxies the list already had: not added again.
        public var alreadyListed = 0
        /// Left out because the list holds `maximumEntries`.
        public var overLimit = 0

        public init(added: [UUID] = [], alreadyListed: Int = 0, overLimit: Int = 0) {
            self.added = added
            self.alreadyListed = alreadyListed
            self.overLimit = overLimit
        }
    }

    /// Adds the proxies a pasted list held (`ProxyListImport`), after the ones already listed. A
    /// proxy already in the list (`identity(of:)`) is not added twice; one that does not validate
    /// is never added.
    @discardableResult
    public mutating func add(_ lines: [ProxyListImport.Line], at time: Date = Date()) -> AddResult {
        var result = AddResult()
        var known = Set(entries.map { Self.identity(of: $0.proxy) })
        for line in lines {
            guard (try? line.proxy.validate()) != nil else { continue }
            let identity = Self.identity(of: line.proxy)
            guard !known.contains(identity) else {
                result.alreadyListed += 1
                continue
            }
            guard entries.count < Self.maximumEntries else {
                result.overLimit += 1
                continue
            }
            let entry = ProxyListEntry(label: Self.cleanLabel(line.label), proxy: line.proxy, addedAt: time)
            entries.append(entry)
            known.insert(identity)
            result.added.append(entry.id)
        }
        return result
    }

    public mutating func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
    }

    public mutating func rename(_ id: UUID, to label: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].label = Self.cleanLabel(label)
    }

    /// Keeps what a check of entry `id` found. An entry removed while it was being checked stays
    /// removed.
    public mutating func record(_ result: ProxyCheckResult, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastCheck = result
    }

    /// One line, at most 64 characters, without the spaces around it.
    static func cleanLabel(_ label: String) -> String {
        let line = label.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    }

    /// Round robin: the first profile gets the first proxy, the second the second, and after the
    /// last proxy the next profile gets the first again. With one proxy every profile gets it; with
    /// none, nobody gets anything.
    public static func rotation(of proxies: [ProxyListEntry], over profiles: [UUID]) -> [ProxyAssignment] {
        guard !proxies.isEmpty else { return [] }
        return profiles.enumerated().map { index, profile in
            ProxyAssignment(profileID: profile, entry: proxies[index % proxies.count])
        }
    }

    private enum CodingKeys: String, CodingKey {
        case format, entries
    }

    /// Tolerant: an entry that does not decode (written by a later build, say with a kind of proxy
    /// this one does not know) is left out rather than costing the whole list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        var list = try c.nestedUnkeyedContainer(forKey: .entries)
        var entries: [ProxyListEntry] = []
        while !list.isAtEnd {
            if let entry = try? list.decode(ProxyListEntry.self) {
                entries.append(entry)
            } else {
                _ = try list.decode(Skipped.self)
            }
        }
        self.entries = entries
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(entries, forKey: .entries)
    }

    /// Moves an unkeyed container past an element that did not decode.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension ProxyList {
    static func file(for vault: UnlockedVault) -> EncryptedDocumentFile<ProxyList> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("proxies.bin"), key: vault.proxyListKey,
                              aad: "proxy-list:v1:\(vault.vaultID.uuidString)")
    }

    /// The vault's proxy list; empty before the first proxy was added.
    public static func load(from vault: UnlockedVault) throws -> ProxyList {
        let list = try file(for: vault).load() ?? ProxyList()
        guard list.format == 1 else { throw CoreError.unsupportedFormat("proxy list format \(list.format)") }
        return list
    }

    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}

/// A profile and the proxy of the list it is to get.
public struct ProxyAssignment: Equatable, Sendable {
    public var profileID: UUID
    public var entry: ProxyListEntry

    public init(profileID: UUID, entry: ProxyListEntry) {
        self.profileID = profileID
        self.entry = entry
    }
}
