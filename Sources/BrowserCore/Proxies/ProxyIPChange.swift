import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A mobile proxy's "change IP" link: the provider's address that, opened, gives the proxy a new
/// exit IP — the modem behind it reconnects. Providers sell mobile proxies with one, written after
/// the proxy in brackets (`socks5://user:pass@host:port[https://…]`, `ProxyListImport`).
///
/// The link holds the provider's key for that modem: it is kept in the encrypted proxy list like
/// the proxy's password, sent only to its own host, and never logged — not even its host.
///
/// It is opened from the app itself, not through the proxy (the provider's API is reachable
/// directly, and a proxy whose modem is reconnecting does not carry anything) — from this Mac's
/// own connection, which the editor says. So a link entered (the editor, an import line) is taken
/// only to a host on the internet: not this Mac, its local network or a link-local address, by
/// name (localhost, .local, a name of one label…) or by address; one already in the list is kept
/// as it is (`storedLink`) but not opened (`mayOpen`); a redirect is followed only on the same
/// host (`mayFollowRedirect`). The provider's
/// answer is the only word on whether it worked: a 2xx answer whose text does not say it failed.
/// The new exit IP is found afterwards by checking the proxy again (`ProxyChecker`), once it
/// carries traffic again.
public enum ProxyIPChange {
    /// The longest link taken (providers' are well under it).
    public static let maximumLength = 2048
    /// How long the provider is given to answer.
    public static let timeout: TimeInterval = 30
    /// After the provider answered, how long the proxy is given to carry traffic again — checked
    /// every few seconds (`settleCheckInterval`) — before the change is reported without a new IP.
    public static let settleLimit: TimeInterval = 45
    public static let settleCheckInterval: TimeInterval = 4

    /// `text` as an IP-change link: an http or https URL with a host on the internet
    /// (`isInternetHost`), no user name or password in it (a key belongs in its query, where
    /// providers put it), at most `maximumLength` characters. Spaces around it are ignored; nil
    /// for anything else.
    ///
    /// http stays allowed: providers that run their own modem servers hand out http links to
    /// their server's public address and port (`http://<server>:7001/…`), and https-only would
    /// leave those proxies without their link. Such a link crosses this Mac's own network
    /// unencrypted, key and all; the editor says the link is opened from this Mac's connection,
    /// and https is what to give when the provider has it.
    public static func link(from text: String) -> URL? {
        guard let url = storedLink(from: text), let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
              isInternetHost(host) else { return nil }
        return url
    }

    /// `text` as a link kept in the proxy list: the rule before hosts were looked at — an http or
    /// https URL with a host, no user name or password, at most `maximumLength` characters. A link
    /// saved before that rule (to a host of the local network, say) is read and written back as it
    /// is, never dropped: it is the person's. It is not opened (`mayOpen`), and the editor asks for
    /// another when it is edited (`link(from:)`).
    public static func storedLink(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength, !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// Whether `link` may be opened: one `link(from:)` takes — to a host on the internet. A link
    /// kept from before the rule on hosts that names this Mac or its network is not.
    public static func mayOpen(_ link: URL) -> Bool {
        self.link(from: link.absoluteString) != nil
    }

    /// Whether `host` (a URL's) names a host on the internet, as far as its text tells: not
    /// localhost or a name under .localhost, .local, .home.arpa, .internal or .lan; not a name of
    /// one label (the local network's search domains complete it); not an IPv4 address in a
    /// private, loopback, link-local, shared (100.64/10), multicast or reserved range — nor one
    /// written in a form other than four decimal numbers (`127.1`, `0x7f.0.0.1`, `2130706433`
    /// reach 127.0.0.1 too); not an IPv6 address outside global unicast (2000::/3).
    ///
    /// A name is not resolved here: one that a DNS answer points at a local address is not
    /// caught. What this keeps out is a link written to reach this Mac or its network.
    public static func isInternetHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name = String(name.dropLast()) }
        guard !name.isEmpty else { return false }
        if name.contains(":") { return isGlobalIPv6(name) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return false }
        // Numbers only, in any of the forms an address can be written in: an IPv4 address.
        let numeric = labels.allSatisfy { label in
            label.allSatisfy(\.isNumber) || (label.hasPrefix("0x") && label.dropFirst(2).allSatisfy(\.isHexDigit))
        }
        if numeric || labels.last?.allSatisfy(\.isNumber) == true { return isPublicIPv4(labels) }
        let local = ["localhost", "local", "home.arpa", "internal", "lan"]
        return !local.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// Four decimal numbers (no leading zero, none over 255) outside the ranges that are not the
    /// internet's.
    static func isPublicIPv4(_ labels: [String]) -> Bool {
        guard labels.count == 4 else { return false }
        var octets: [Int] = []
        for label in labels {
            guard !label.isEmpty, label.count <= 3, label.allSatisfy({ $0.isASCII && $0.isNumber }),
                  label == "0" || !label.hasPrefix("0"), let value = Int(label), value <= 255 else { return false }
            octets.append(value)
        }
        let (a, b) = (octets[0], octets[1])
        switch a {
        case 0, 10, 127: return false                       // this network, private, loopback
        case 100 where (64...127).contains(b): return false // shared address space (carrier NAT)
        case 169 where b == 254: return false               // link-local
        case 172 where (16...31).contains(b): return false  // private
        case 192 where b == 168: return false               // private
        case 192 where b == 0 && octets[2] == 0: return false // IETF protocol assignments
        case 198 where b == 18 || b == 19: return false     // benchmarking
        case 224...255: return false                        // multicast, reserved, broadcast
        default: return true
        }
    }

    /// Global unicast (2000::/3) only: not loopback (::1), unspecified, an IPv4-mapped or NAT64
    /// address, unique local (fc00::/7), link-local (fe80::/10) or multicast.
    static func isGlobalIPv6(_ address: String) -> Bool {
        guard address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }), !address.hasPrefix(":"),
              let first = address.split(separator: ":", omittingEmptySubsequences: false).first,
              (1...4).contains(first.count), let group = UInt16(first, radix: 16) else { return false }
        return (0x2000...0x3FFF).contains(group)
    }

    /// Whether a redirect from `original` to `target` is followed: on the same host, to a link
    /// this would take (`link(from:)`), and not from https down to http. A provider's API that
    /// sends its caller elsewhere — another host, this Mac, its network — is not followed there:
    /// the answer is the redirect itself, which is not a 2xx, so the change reads as refused.
    public static func mayFollowRedirect(from original: URL, to target: URL) -> Bool {
        guard let from = original.host?.lowercased(), let to = target.host?.lowercased(), from == to,
              link(from: target.absoluteString) != nil else { return false }
        return !(original.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http")
    }

    /// The request that opens `link`: a plain GET, nothing of the app's (no cookies, no cache),
    /// with a neutral User-Agent — the provider learns nothing but that its link was opened.
    public static func request(for link: URL) -> URLRequest {
        var request = URLRequest(url: link, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Lumen", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return request
    }

    /// What the provider answered.
    public enum Answer: Equatable, Sendable {
        /// It took the change. `message`: its own words, when it said any (shortened).
        case accepted(message: String?)
        /// It answered, and not with a change: an HTTP error, or a 2xx whose text says it failed
        /// (too soon after the last change, a wrong key). `message`: its words, when it gave any.
        case refused(status: Int, message: String?)
        /// No answer: the link's host could not be reached, or did not answer in time.
        case unreachable(String)
    }

    /// The provider's answer as `Answer`, from the HTTP status and the body. The words that mean
    /// "failed" are the ones providers' APIs use in JSON (`"status": "error"`, `"success": false`,
    /// `"ok": false`, an `"error"` that is not empty or null) or as plain text starting with
    /// "error" or "fail".
    public static func answer(status: Int, body: Data) -> Answer {
        let message = shown(body)
        guard (200..<300).contains(status) else { return .refused(status: status, message: message) }
        if saysFailed(body) { return .refused(status: status, message: message) }
        return .accepted(message: message)
    }

    static func saysFailed(_ body: Data) -> Bool {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let status = object["status"] as? String, ["error", "fail", "failed", "err"].contains(status.lowercased()) { return true }
            if let success = object["success"] as? Bool, !success { return true }
            if let ok = object["ok"] as? Bool, !ok { return true }
            if let result = object["result"] as? String, ["error", "fail", "failed"].contains(result.lowercased()) { return true }
            if let error = object["error"] {
                if let text = error as? String { return !text.isEmpty }
                if let flag = error as? Bool { return flag }
                return !(error is NSNull)
            }
            return false
        }
        let text = String(decoding: body.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("error") || text.hasPrefix("fail")
    }

    /// The body as a line to show: its `message` (or `msg`, `error`, `status`) when it is JSON,
    /// else its text; control characters and markup taken out, at most 160 characters. Nil when
    /// there is nothing readable.
    static func shown(_ body: Data) -> String? {
        var text: String?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for key in ["message", "msg", "error", "status", "result"] {
                if let value = object[key] as? String, !value.isEmpty {
                    text = value
                    break
                }
            }
        } else {
            let raw = String(decoding: body.prefix(4096), as: UTF8.self)
            // An HTML page says nothing worth showing in a line.
            if !raw.lowercased().contains("<html") { text = raw }
        }
        guard let text else { return nil }
        let cleaned = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > 160 ? String(cleaned.prefix(159)) + "…" : cleaned
    }

    /// A launch may change the IP of `entry` first: it changes at launch, has a link, and no other
    /// running profile (`runningProxies`, the identities of the proxies of the profiles running
    /// now, `ProxyList.identity(of:)`) is on that proxy — its pages would lose their IP mid-session.
    public static func mayChange(_ entry: ProxyListEntry, runningProxies: [String]) -> Bool {
        guard entry.changesIPOnLaunch, entry.changeIPURL != nil else { return false }
        return !runningProxies.contains(ProxyList.identity(of: entry.proxy))
    }
}
