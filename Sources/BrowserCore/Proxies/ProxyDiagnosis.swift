import Foundation

/// What a proxy did when it was asked, step by step (`ProxyProbe`): whether its name resolves,
/// whether it takes a connection, whether it answers as a SOCKS5 or an HTTP proxy (both are
/// tried: the type is found, not assumed), whether it takes the login, and whether it opens a
/// tunnel to a site. Each way of failing is its own verdict, because each asks something else of
/// the person: "the proxy does not answer" covers a typo in the address, a proxy that is down, one
/// that only serves the addresses on its whitelist and one that wants another password, and only
/// the first step that failed tells them apart.
///
/// Nothing in it is secret: no user name or password, only what the proxy answered (an HTTP status
/// line, a SOCKS5 reply) and the address the connection was made to.
public struct ProxyDiagnosis: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, CaseIterable, Sendable {
        /// The proxy's host name does not exist (the resolver said so).
        case hostNotFound
        /// The resolver did not answer, or failed (no network, a DNS problem), so nothing is known.
        case resolverFailed
        /// The name was answered by a VPN's DNS with substitute addresses only (`SubstituteDNS`), and
        /// no proxy answered there: such a DNS gives any name an address, one that does not exist
        /// too, so whether the host exists cannot be told from this Mac (`connectedAddress` is the
        /// substitute tried).
        case substituteDNS
        /// The host refused the connection: nothing listens on that port.
        case refused
        /// The host cannot be reached at all (no route to it).
        case unreachable
        /// The connection got no answer at all: a firewall drops it, or the address is wrong.
        case connectTimeout
        /// The connection was taken, and then nothing came back — not as SOCKS5, not as HTTP. What a
        /// proxy that serves only the addresses on its whitelist does to the others, or one whose
        /// back end is gone.
        case silent
        /// The connection was taken and closed again without a word.
        case closedWithoutAnswer
        /// Something answered, neither as a SOCKS5 nor as an HTTP proxy (`answer` says what).
        case notAProxy
        /// It asks for a user name and password, and none were given.
        case credentialsNeeded
        /// It refused the user name and password given.
        case credentialsRejected
        /// It answered, and refused to serve this Mac (an HTTP 403: often a proxy bound to IP
        /// addresses, of which this Mac's is not one).
        case refusedByProxy
        /// It took the connection and the login, and could not reach the site asked for (its own
        /// connection out failed: a SOCKS5 error, an HTTP 502/503/504, or no answer in time).
        case noUpstream
        /// A proxy spoken to through TLS (`https://`): the connection was taken; what happens
        /// inside TLS is checked end to end (a request through it), not here.
        case reachable
        /// It answered, took the login (or needed none), and opened a tunnel to the site.
        case works
    }

    /// How the login went.
    public enum Authentication: String, Codable, Sendable {
        /// The proxy asked for none.
        case notRequired
        /// Given, and taken.
        case accepted
        /// Given, and refused.
        case rejected
        /// Asked for, and none given.
        case missing
    }

    public var verdict: Verdict
    /// The types that answered the handshake, the one to use first (SOCKS5 and HTTP on the same
    /// port both happen).
    public var kinds: [ProxySettings.Kind]
    public var authentication: Authentication?
    /// What the proxy said where it says why: an HTTP status line, a SOCKS5 reply, the first bytes
    /// of something else. Never a user name or password.
    public var answer: String?
    /// The address the connection was made to, as the resolver gave it (for `substituteDNS`, the
    /// one tried).
    public var connectedAddress: String?
    /// How long setting up a tunnel took, in milliseconds (connection, handshake, login, tunnel
    /// answered), once per try that got that far.
    public var latencies: [Int]
    /// How many tunnels were tried for `latencies`.
    public var latencyAttempts: Int

    public init(verdict: Verdict, kinds: [ProxySettings.Kind] = [], authentication: Authentication? = nil,
                answer: String? = nil, connectedAddress: String? = nil, latencies: [Int] = [], latencyAttempts: Int = 0) {
        self.verdict = verdict
        self.kinds = kinds
        self.authentication = authentication
        self.answer = answer
        self.connectedAddress = connectedAddress
        self.latencies = latencies
        self.latencyAttempts = latencyAttempts
    }

    /// It carries traffic, as far as the probe can tell (end to end is the checker's next step).
    public var isWorking: Bool { verdict == .works || verdict == .reachable }

    /// The middle of `latencies` (the lower of the two middles of an even count).
    public var medianLatency: Int? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// Which step failed, in the order the probe takes them (for the report): 1 the name, 2 the
    /// connection, 3 the handshake, 4 the login, 5 the tunnel; nil when none did.
    public var failedStep: Int? {
        switch verdict {
        case .hostNotFound, .resolverFailed, .substituteDNS: return 1
        case .refused, .unreachable, .connectTimeout: return 2
        case .silent, .closedWithoutAnswer, .notAProxy: return 3
        case .credentialsNeeded, .credentialsRejected, .refusedByProxy: return 4
        case .noUpstream: return 5
        case .reachable, .works: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case verdict, kinds, authentication, answer, connectedAddress, latencies, latencyAttempts
    }

    /// Tolerant: a verdict a later build wrote, and this one does not know, reads as "no answer"
    /// rather than costing the whole check result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = (try? c.decode(Verdict.self, forKey: .verdict)) ?? .silent
        kinds = (try? c.decodeIfPresent([ProxySettings.Kind].self, forKey: .kinds)) ?? []
        authentication = (try? c.decodeIfPresent(Authentication.self, forKey: .authentication)) ?? nil
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        connectedAddress = try c.decodeIfPresent(String.self, forKey: .connectedAddress)
        latencies = try c.decodeIfPresent([Int].self, forKey: .latencies) ?? []
        latencyAttempts = try c.decodeIfPresent(Int.self, forKey: .latencyAttempts) ?? 0
    }
}
