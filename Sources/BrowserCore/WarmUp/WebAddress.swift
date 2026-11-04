import Foundation

/// A profile's search engine: what its address bar searches with, and its warm-up's searches. Each
/// is reached through the profile's proxy like any page.
public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case duckDuckGo, google, bing, yahoo, ecosia, yandex

    /// The engine of a profile that names none (every profile from before there was a choice).
    public static let standard = SearchEngine.duckDuckGo

    /// Its own name, as it calls itself.
    public var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .yahoo: return "Yahoo"
        case .ecosia: return "Ecosia"
        case .yandex: return "Yandex"
        }
    }

    /// The results page's address; the query is appended, percent-encoded.
    public var searchURLTemplate: String {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/?q="
        case .google: return "https://www.google.com/search?q="
        case .bing: return "https://www.bing.com/search?q="
        case .yahoo: return "https://search.yahoo.com/search?p="
        case .ecosia: return "https://www.ecosia.org/search?q="
        case .yandex: return "https://yandex.ru/search/?text="
        }
    }
}

/// What the address bar (and the warm-up robot) makes of typed text: a web address, or a search.
public enum WebAddress {
    /// The search results page for `query`, with `engine`.
    public static func searchURL(for query: String, engine: SearchEngine = .standard) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        return URL(string: engine.searchURLTemplate + encoded)
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

    /// The address bar: a web address, else a search for the text with `engine`.
    public static func url(fromAddressBarInput input: String, engine: SearchEngine = .standard) -> URL? {
        url(fromTypedAddress: input) ?? searchURL(for: input, engine: engine)
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
