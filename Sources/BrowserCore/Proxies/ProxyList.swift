import Foundation

/// What checking a proxy found: first the proxy itself, step by step (`ProxyProbe`, `diagnosis`:
/// does its name resolve, does it take a connection, does it answer as SOCKS5 or HTTP, does it take
/// the login, does it open a tunnel); then, through it (never around it), a geolocation service —
/// where it exits. Kept with the proxy in the list, so the list shows which proxies work, why the
/// others do not, where they exit and how slow they are, without checking again.
///
/// A proxy is alive when a service's answer came back through it. Where it exits (IP, country,
/// time zone, city, network) is filled in when that answer said so; a proxy can be alive with its
/// country unknown (a service that answered without a location, e.g. rate-limited).
public struct ProxyCheckResult: Codable, Equatable, Sendable {
    public enum Failure: String, Codable, Sendable {
        /// Nothing answered through the proxy in time: it is down, refused the connection, cannot
        /// reach the services, or its address does not resolve (`diagnosis` says which).
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
    /// How long it takes to get through the proxy: the median of the probe's tunnels (connection,
    /// handshake, login, tunnel answered), or, without them, the answering request's time.
    public var latencyMilliseconds: Int?
    /// The proxy itself, step by step; nil in results of builds from before the probe.
    public var diagnosis: ProxyDiagnosis?
    /// Where the exit IP is, as the service said: the city, and the network ("AS13335") and who
    /// runs it.
    public var city: String?
    public var asn: String?
    public var organization: String?
    /// What the check found about the proxy's type, when the list did not have it right.
    public var kindFinding: KindFinding?

    /// The type the check found, against what the list had.
    public enum KindFinding: Codable, Equatable, Sendable {
        /// The list had none (an import line without a scheme): the check found it.
        case found
        /// The list's type did not answer; this one did, and the entry now has it.
        case corrected(from: ProxySettings.Kind)
    }

    public init(checkedAt: Date = Date(), failure: Failure? = nil, exitIP: String? = nil, countryCode: String? = nil,
                timeZoneIdentifier: String? = nil, latencyMilliseconds: Int? = nil, diagnosis: ProxyDiagnosis? = nil,
                city: String? = nil, asn: String? = nil, organization: String? = nil) {
        self.checkedAt = checkedAt
        self.failure = failure
        self.exitIP = exitIP
        self.countryCode = countryCode
        self.timeZoneIdentifier = timeZoneIdentifier
        self.latencyMilliseconds = latencyMilliseconds
        self.diagnosis = diagnosis
        self.city = city
        self.asn = asn
        self.organization = organization
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
    /// False until a check found the type: the entry came from an import line without a scheme,
    /// and `proxy.kind` is a placeholder. Such an entry is given to no profile.
    public var kindKnown: Bool
    public var addedAt: Date
    public var lastCheck: ProxyCheckResult?

    public init(id: UUID = UUID(), label: String = "", proxy: ProxySettings, kindKnown: Bool = true, addedAt: Date = Date(),
                lastCheck: ProxyCheckResult? = nil) {
        self.id = id
        self.label = label
        self.proxy = proxy
        self.kindKnown = kindKnown
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
        case id, label, proxy, kindKnown, addedAt, lastCheck
    }

    /// Tolerant: a check result that no longer decodes (written by a later build) is dropped, never
    /// a reason to lose the proxy. An entry from before types could be unknown has a known one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        proxy = try c.decode(ProxySettings.self, forKey: .proxy)
        kindKnown = try c.decodeIfPresent(Bool.self, forKey: .kindKnown) ?? true
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
        lastCheck = (try? c.decodeIfPresent(ProxyCheckResult.self, forKey: .lastCheck)) ?? nil
    }

    /// The proxy as a profile can use it: nil while its type is unknown.
    public var usableProxy: ProxySettings? { kindKnown ? proxy : nil }
}

/// The proxies the user keeps at hand, to give to profiles (`ProxyAssignment`) and to check.
///
/// Stored encrypted at the vault root as `proxies.bin`: AES-GCM under `HKDF(VMK, "proxy-list")`,
/// AAD `proxy-list:v1:<vaultID>` — the credentials in it are as safe as a profile's. This Mac's
/// only, never synced (as `settings.bin`).
///
/// A profile uses an entry when its proxy is that entry's — the same host, port and user name
/// (`identity(of:)`, `entry(for:)`): the link is the proxy itself, so it holds on every Mac the
/// profile syncs to, survives an edit of the entry (the profiles that used it follow,
/// `ProfileRepository.follow`), and a profile whose proxy was typed into it, not chosen from the
/// list, still has it. Each profile carries its own copy of its proxy, which is what it connects
/// with and what syncs: a list that is missing an entry, or another Mac's list, never leaves a
/// profile without its proxy. Profiles' proxies from before the list are taken into it once, at
/// the first unlock that has a list (`takeIn(profileProxies:)`).
public struct ProxyList: Codable, Equatable, Sendable {
    /// More than any provider's list a person would paste; keeps the file and the checks bounded.
    public static let maximumEntries = 10_000

    var format = 1
    public private(set) var entries: [ProxyListEntry]
    /// The profiles' own proxies have been taken into the list (`takeIn(profileProxies:)`): it is
    /// done once, so that a proxy removed from the list later does not come back.
    public private(set) var profilesTakenIn = false

    public init(entries: [ProxyListEntry] = []) {
        self.entries = entries
    }

    public func entry(_ id: UUID) -> ProxyListEntry? { entries.first { $0.id == id } }

    /// The entry a profile with `proxy` uses: the one with the same host, port and user name.
    public func entry(for proxy: ProxySettings) -> ProxyListEntry? {
        let identity = Self.identity(of: proxy)
        return entries.first { Self.identity(of: $0.proxy) == identity }
    }

    /// What makes two proxies the same one: the host (in any case), the port and the user name. The
    /// type, TLS and the password are how to reach it, not which one it is (a check may find the
    /// type; a new password is the same proxy). Another user name is another proxy: gateway
    /// providers pick the exit — the country, the session — from it.
    public static func identity(of proxy: ProxySettings) -> String {
        [proxy.host.lowercased(), String(proxy.port), proxy.username ?? ""].joined(separator: "\u{0}")
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
            let entry = ProxyListEntry(label: Self.cleanLabel(line.label), proxy: line.proxy, kindKnown: line.kindGiven, addedAt: time)
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
    ///
    /// The type the check found is the entry's from then on when the entry had none (an import
    /// line without a scheme), or when its own did not answer and another did: a proxy listed as
    /// SOCKS5 that only answers as HTTP is an HTTP proxy. Returns the entry's proxy as it was, when
    /// that changed it — the profiles that use it follow (`ProfileRepository.follow`).
    @discardableResult
    public mutating func record(_ result: ProxyCheckResult, for id: UUID) -> ProxySettings? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var result = result
        let before = entries[index].proxy
        let kinds = result.diagnosis?.kinds ?? []
        if let found = kinds.first, !entries[index].kindKnown || !kinds.contains(before.kind) {
            result.kindFinding = entries[index].kindKnown ? .corrected(from: before.kind) : .found
            entries[index].proxy.kind = found
            if found == .socks5 { entries[index].proxy.tlsToProxy = false }
            entries[index].kindKnown = true
        }
        entries[index].lastCheck = result
        return entries[index].proxy != before ? before : nil
    }

    /// The profiles' own proxies — typed into profiles before the list existed — taken into the
    /// list, once (`profilesTakenIn`): each one the list does not have yet (`identity(of:)`)
    /// becomes an entry, with its type, shown by its address. Nothing of a profile changes. Returns
    /// the entries added.
    @discardableResult
    public mutating func takeIn(profileProxies: [ProxySettings], at time: Date = Date()) -> [UUID] {
        guard !profilesTakenIn else { return [] }
        profilesTakenIn = true
        var known = Set(entries.map { Self.identity(of: $0.proxy) })
        var added: [UUID] = []
        for proxy in profileProxies where entries.count < Self.maximumEntries {
            guard (try? proxy.validate()) != nil, known.insert(Self.identity(of: proxy)).inserted else { continue }
            var listed = proxy
            listed.excludedDomains = [] // a profile's bypass list is that profile's
            let entry = ProxyListEntry(proxy: listed, kindKnown: true, addedAt: time)
            entries.append(entry)
            added.append(entry.id)
        }
        return added
    }

    /// Why an edit of an entry was not made.
    public enum EditProblem: Error, Equatable, Sendable {
        case notFound
        /// The proxy does not validate (`ProxySettings.validate`): its message.
        case invalid(String)
        /// Another entry is that proxy already (the same host, port and user name).
        case alreadyListed(UUID)
    }

    /// Changes entry `id`: its label, and its proxy as typed in the editor (the type known from
    /// then on). A changed proxy drops the last check, which was about the other one. Returns the
    /// proxy as it was, for the profiles that used it to follow (`ProfileRepository.follow`).
    @discardableResult
    public mutating func update(_ id: UUID, label: String, proxy: ProxySettings) throws -> ProxySettings {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw EditProblem.notFound }
        do { try proxy.validate() } catch { throw EditProblem.invalid((error as? CoreError)?.description ?? "\(error)") }
        let identity = Self.identity(of: proxy)
        if let other = entries.first(where: { $0.id != id && Self.identity(of: $0.proxy) == identity }) {
            throw EditProblem.alreadyListed(other.id)
        }
        let before = entries[index].proxy
        var listed = proxy
        listed.excludedDomains = []
        entries[index].label = Self.cleanLabel(label)
        if listed != before || !entries[index].kindKnown {
            entries[index].proxy = listed
            entries[index].kindKnown = true
            entries[index].lastCheck = nil
        }
        return before
    }

    /// The entries as text, one per line, in the form the import reads back
    /// (`scheme://user:password@host:port  # label`; no scheme while the type is unknown). The
    /// user names and passwords are in it in plaintext: the file is only what the user asked for.
    public static func exportText(_ entries: [ProxyListEntry]) -> String {
        var lines = ["# PrivacyBrowser proxies. The user names and passwords below are in plaintext."]
        for entry in entries {
            let proxy = entry.proxy
            var line = ""
            if entry.kindKnown {
                line += proxy.kind == .socks5 ? "socks5://" : (proxy.tlsToProxy ? "https://" : "http://")
            }
            if let user = proxy.username, !user.isEmpty {
                line += Self.userInfo(user) + ":" + Self.userInfo(proxy.password ?? "") + "@"
            }
            line += (proxy.host.contains(":") ? "[\(proxy.host)]" : proxy.host) + ":\(proxy.port)"
            let label = Self.cleanLabel(entry.label)
            if !label.isEmpty { line += "  # " + label }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A user name or password as the userinfo of an address: everything but letters, digits and
    /// `-._~` percent-encoded, so that ":", "@", "#", "%" and spaces come back as they were.
    static func userInfo(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
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
        case format, entries, profilesTakenIn
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
        profilesTakenIn = try c.decodeIfPresent(Bool.self, forKey: .profilesTakenIn) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(entries, forKey: .entries)
        try c.encode(profilesTakenIn, forKey: .profilesTakenIn)
    }

    /// Moves an unkeyed container past an element that did not decode.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension ProxyList {
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<ProxyList> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("proxies.bin"), key: try vault.proxyListKey,
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
