import Foundation

/// What of a text that may quote the user can be written to the log in clear.
///
/// An Objective-C exception's reason says what went wrong — which method, which object was nil —
/// and that is what is needed to understand a crash; but it can also quote what it was working
/// on: a page's address, a file's path, a title. The log keeps the user's data private as it is
/// written (scripts/check_log_privacy.py), so the reason is logged twice: in full, privately, and
/// cut by this, in clear.
public enum LogRedaction {
    /// `reason` with everything that can be the user's replaced by a placeholder: web addresses and
    /// other URLs, host names (but not Apple's own reverse-DNS identifiers), file paths, e-mail
    /// addresses, anything in quotes, and runs of digits long enough to be a card or a phone
    /// number. What is left — method and class names, "nil", counts, memory addresses — stays, and
    /// so do the names of the resources the system could not find (`keepResourceNames`).
    /// At most `limit` characters.
    public static func exceptionReason(_ reason: String, limit: Int = 600) -> String {
        var kept: [String] = []
        var text = keepResourceNames(reason, &kept)
        for (pattern, placeholder) in rules {
            text = text.replacingOccurrences(of: pattern, with: placeholder, options: .regularExpression)
        }
        for (index, name) in kept.enumerated() {
            text = text.replacingOccurrences(of: token(index), with: name)
        }
        if text.count > limit {
            text = String(text.prefix(limit)) + "…"
        }
        return text
    }

    /// In order: the whole of a URL before its host is taken for a host name, an e-mail address
    /// before its domain is, quotes before a path inside them.
    private static let rules: [(String, String)] = [
        // Anything in quotes, of any kind: a title, a form's value, a key a page chose.
        (#""[^"]*""#, "\"…\""),
        (#"'[^']*'"#, "'…'"),
        ("“[^”]*”", "“…”"),
        ("«[^»]*»", "«…»"),
        // URLs of any scheme, up to the next space or closing bracket.
        (#"\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s<>"'\)\]\}]+"#, "<url>"),
        (#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, "<email>"),
        // A home folder's path before any other path: it names the user.
        (#"(?<![A-Za-z0-9_])~?/(?:[A-Za-z0-9._@%+~\-]+/?)+"#, "<path>"),
        // Host names, but not Apple's identifiers (com.apple.Safari.History says which service).
        (#"\b(?!com\.apple\.)(?:[A-Za-z0-9\-]+\.)+(?:com|net|org|io|ru|de|uk|fr|jp|cn|info|biz|co|app|dev|me|tv|us|eu|test|example|invalid|local|[a-z]{2})\b"#, "<host>"),
        // 9 digits or more, spaces and dashes between them allowed: a card, a phone, an account.
        (#"\b\d(?:[ \-]?\d){8,}\b"#, "<number>"),
    ]

    // MARK: Names of the system's files

    /// The nib or storyboard AppKit could not load, and the bundle it looked in: the names of the
    /// system's and the app's files, never the user's, and without them the missing one cannot be
    /// found ("could not load the nib 'AnnotatedBookmarksSidebarExpandedTableCellView' in bundle
    /// NSBundle </Applications/PrivacyBrowser.app> (loaded)"). Set aside before the rules run, put
    /// back after. A name is kept only when it is one a program gives (letters, digits, `_ . -`); a
    /// bundle only by its path's end where the rest could be the user's (`bundlePath`).
    private static func keepResourceNames(_ reason: String, _ kept: inout [String]) -> String {
        let name = #"[A-Za-z0-9_.\-]{1,120}"#
        var text = reason
        // "the nib 'Name'", "nib named 'Name'", "storyboard named 'Name'", and "the "Name" nib".
        for pattern in [#"\b(?:nib|nib named|storyboard named) (['"])"# + name + #"\1"#,
                        #"(['"])"# + name + #"\1(?= nib\b)"#] {
            text = replacing(pattern, in: text) { match in
                kept.append(match)
                return token(kept.count - 1)
            }
        }
        // NSBundle's own description of itself: "NSBundle </path/Name.app> (loaded)".
        text = replacing(#"NSBundle <(/[^<>\n]*?\.(?:app|framework|bundle|xpc|appex|plugin))> \(([a-z ]{1,20})\)"#, in: text) { match in
            guard let open = match.firstIndex(of: "<"), let close = match.lastIndex(of: ">") else { return match }
            let path = String(match[match.index(after: open)..<close])
            kept.append("NSBundle <\(bundlePath(path))>" + match[match.index(after: close)...])
            return token(kept.count - 1)
        }
        return text
    }

    /// A bundle's path as the log shows it: in full where it is the system's (`/System`, `/usr`,
    /// `/Library/Apple`) or an application directly in `/Applications`; anywhere else only the
    /// bundle's own name, after "~/…/" in the user's home folder and "…/" elsewhere — the folders
    /// above it can be named by the user.
    static func bundlePath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return path }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/") {
            return path
        }
        if parts.count == 2, parts[0] == "Applications" {
            return path
        }
        return (parts.first == "Users" ? "~/…/" : "…/") + last
    }

    /// Stands for a kept name while the rules run: private-use characters and a number, which no
    /// rule matches.
    private static func token(_ index: Int) -> String {
        "\u{E000}\(index)\u{E001}"
    }

    /// `text` with every match of `pattern` replaced by what `replacement` makes of it.
    private static func replacing(_ pattern: String, in text: String, _ replacement: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var rest = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[rest..<range.lowerBound]
            result += replacement(String(text[range]))
            rest = range.upperBound
        }
        return result + text[rest...]
    }
}
