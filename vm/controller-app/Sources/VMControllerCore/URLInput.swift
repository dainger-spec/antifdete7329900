import Foundation

public enum URLInput {
    /// Normalizes what the user typed into an http(s) URL the in-VM agent
    /// accepts (`^https?://`, no whitespace or control characters), or nil.
    /// A bare host ("example.com") gets https://.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return nil }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard text.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        components.scheme = scheme // the agent's check is case-sensitive
        return components.string
    }
}
