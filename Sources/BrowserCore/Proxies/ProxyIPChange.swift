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
/// directly, and a proxy whose modem is reconnecting does not carry anything). The provider's
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

    /// `text` as an IP-change link: an http or https URL with a host, no user name or password in
    /// it (a key belongs in its query, where providers put it), at most `maximumLength` characters.
    /// Spaces around it are ignored; nil for anything else.
    public static func link(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength, !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
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
