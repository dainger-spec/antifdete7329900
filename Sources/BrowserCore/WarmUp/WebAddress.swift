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
}
