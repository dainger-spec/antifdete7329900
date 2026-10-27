import Foundation

/// What the address bar (and the warm-up robot) makes of typed text: a web address, or a search.
public enum WebAddress {
    /// The search engine of the address bar.
    public static let searchURLTemplate = "https://duckduckgo.com/?q="

    /// The search results page for `query`.
    public static func searchURL(for query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        return URL(string: searchURLTemplate + encoded)
    }

    /// A typed web address: an http(s) or about URL as it is; a host name without a scheme
    /// (`example.com`, `example.com/path`, `localhost:8080`) as https. Nil for anything else.
    public static func url(fromTypedAddress input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "about"].contains(scheme) {
            return url
        }
        if !text.contains(" "), text.contains(".") || text.hasPrefix("localhost"), let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        return nil
    }

    /// The address bar: a web address, else a search for the text.
    public static func url(fromAddressBarInput input: String) -> URL? {
        url(fromTypedAddress: input) ?? searchURL(for: input)
    }

    /// `a` and `b` are the same page, whatever their fragments, once written as a browser writes
    /// them: scheme and host in lower case, no default port, "/" for an empty path. (A typed
    /// `example.com#news` is the page WebKit shows as `https://example.com/#news`, and still is
    /// once the page has rewritten that to `#/news`.)
    public static func isSameDocument(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return document(a) == document(b)
    }

    private static func document(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return String(url.absoluteString.prefix { $0 != "#" })
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.host != nil, parts.path.isEmpty { parts.path = "/" }
        parts.fragment = nil
        return parts.string ?? String(url.absoluteString.prefix { $0 != "#" })
    }
}
