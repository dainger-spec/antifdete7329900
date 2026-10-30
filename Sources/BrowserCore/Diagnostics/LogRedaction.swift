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
    /// number. What is left — method and class names, "nil", counts, memory addresses — stays.
    /// At most `limit` characters.
    public static func exceptionReason(_ reason: String, limit: Int = 600) -> String {
        var text = reason
        for (pattern, placeholder) in rules {
            text = text.replacingOccurrences(of: pattern, with: placeholder, options: .regularExpression)
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
}
