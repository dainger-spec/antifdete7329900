import Foundation

/// What a person asked for by pressing Return in Safari's address bar of a profile — so that a
/// profile's process can do it itself when Safari's own code throws on the way (`AddressBarCommit`).
///
/// A customer typed "google" and pressed Return: the field showed the committed search, the page
/// stayed empty, and the window said "This Safari feature is not available in a profile". Whatever
/// Safari's code threw in the commit — the search address, the top hit, recording a typed address,
/// the completion chosen — the person's intent is plain from the field: an address, or a search
/// with the profile's engine.
public enum AddressBarIntent {
    /// The page for what the field held at Return: a web address as it is (a host name without a
    /// scheme as https), anything else a search with `engine`. Nil for an empty field.
    public static func destination(typed text: String, engine: SearchEngine) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return WebAddress.url(fromAddressBarInput: trimmed, engine: engine)
    }

    /// The names an engine's results pages are served under (Safari's own provider list may use a
    /// regional host): "google." matches www.google.com and www.google.ru.
    static func hostWords(of engine: SearchEngine) -> [String] {
        switch engine {
        case .google: return ["google."]
        case .bing: return ["bing.com"]
        case .yahoo: return ["yahoo."]
        case .duckDuckGo: return ["duckduckgo.com"]
        case .ecosia: return ["ecosia.org"]
        case .yandex: return ["yandex.", "ya.ru"]
        }
    }

    /// Whether `target` — a host as a proxy sees it, "www.google.com:443" — serves `engine`'s results.
    /// Never a test's own `.invalid` host (www.google.selftest.invalid is a page of the check's).
    public static func isResultsHost(_ target: String, of engine: SearchEngine) -> Bool {
        var host = target.lowercased()
        if let colon = host.lastIndex(of: ":"), !host.contains("]") { host = String(host[..<colon]) }
        guard !host.isEmpty, !host.hasSuffix(".invalid") else { return false }
        let labels = "." + host
        return hostWords(of: engine).contains { word in
            if word.hasSuffix(".") { return labels.contains("." + word) }
            return host == word || host.hasSuffix("." + word)
        }
    }
}
