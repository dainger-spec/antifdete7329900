import Foundation

/// A session's search engine: what the address bar does with text that is not an address.
public enum SearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case google, duckDuckGo, bing, yandex, startpage, brave, ecosia

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .yandex: return L("Яндекс")
        case .startpage: return "Startpage"
        case .brave: return "Brave Search"
        case .ecosia: return "Ecosia"
        }
    }

    /// `%s` is the query, percent-encoded.
    var template: String {
        switch self {
        case .google: return "https://www.google.com/search?q=%s"
        case .duckDuckGo: return "https://duckduckgo.com/?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .yandex: return "https://yandex.ru/search/?text=%s"
        case .startpage: return "https://www.startpage.com/do/search?q=%s"
        case .brave: return "https://search.brave.com/search?q=%s"
        case .ecosia: return "https://www.ecosia.org/search?q=%s"
        }
    }

    public var host: String { URL(string: template.replacingOccurrences(of: "%s", with: "x"))?.host ?? "" }

    public func searchURL(for query: String) -> URL {
        // Engine chosen for the session, unless the planted fault makes the bar ignore it.
        let engine = Faults.isActive(.searchEngineIgnored) ? SearchEngine.google : self
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: engine.template.replacingOccurrences(of: "%s", with: encoded))!
    }
}

/// What the address bar opens for what was typed: an address as it is, a host with a scheme added,
/// anything else as a search with the session's engine.
public enum AddressInput {
    public static func resolve(_ text: String, engine: SearchEngine) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("about:") {
            if let url = URL(string: trimmed), url.scheme != nil { return url }
        }
        if !trimmed.contains(" "), looksLikeHost(trimmed) {
            let scheme = isLocal(trimmed) ? "http://" : "https://"
            if let url = URL(string: scheme + trimmed), url.host != nil { return url }
        }
        return engine.searchURL(for: trimmed)
    }

    /// example.com, example.com/path, sub.example.co.uk:8080, 10.0.0.1, [::1], localhost:3000.
    static func looksLikeHost(_ text: String) -> Bool {
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if hostPart.hasPrefix("[") { return hostPart.contains("]") }
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        if host.lowercased() == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard labels.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return false }
        // The last label of a name is letters (a TLD); an IPv4 address is four numbers.
        if labels.allSatisfy({ Int($0) != nil }) { return labels.count == 4 }
        return labels.last!.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
    }

    static func isLocal(_ text: String) -> Bool {
        let host = (text.split(separator: "/").first.map(String.init) ?? text).split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        return host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }
}
