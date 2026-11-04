import Foundation

/// A profile's cookies written out for another browser, a cookie extension or an automation
/// tool — the three shapes those read, and the ones this app's own import reads back
/// (`CookieImporter`), so that a file exported here imports here unchanged.
///
///   * `netscape`: the `cookies.txt` of curl, wget, yt-dlp and most cookie extensions' "export as
///     Netscape": one tab-separated line per cookie, `#HttpOnly_` before the domain of an
///     HttpOnly one (curl's convention), 0 as the expiry of a session cookie.
///   * `extensionJSON`: EditThisCookie's and Cookie-Editor's array (`domain` with its leading dot
///     for a domain cookie, `hostOnly`, `session`, `expirationDate` in Unix seconds,
///     `sameSite` as `no_restriction` / `lax` / `strict` / `unspecified`).
///   * `playwright`: the `cookies` of a Playwright `storageState` file, which Puppeteer's
///     `page.setCookie` takes as well (`expires` -1 for a session cookie, `sameSite` as
///     `Strict` / `Lax` / `None`).
///
/// The file holds every cookie in plaintext, values included: a session cookie in it is the
/// session itself. Where it goes is the user's decision, made with that said.
public enum CookieExport {
    public enum Format: String, CaseIterable, Codable, Sendable {
        case netscape, extensionJSON, playwright

        public var fileExtension: String { self == .netscape ? "txt" : "json" }
    }

    /// The file, cookies sorted by domain, path and name. A cookie whose fields cannot be written
    /// in the Netscape format (a tab or a line break in one) is left out of that format only.
    public static func data(_ cookies: [ImportedCookie], format: Format) -> Data {
        let sorted = cookies.sorted { CookieKey($0) < CookieKey($1) }
        switch format {
        case .netscape:
            return Data(netscape(sorted).utf8)
        case .extensionJSON:
            return json(sorted.map(extensionEntry))
        case .playwright:
            return json(sorted.map(playwrightEntry))
        }
    }

    /// How many of `cookies` a file in `format` holds (the Netscape format drops the unwritable).
    public static func count(_ cookies: [ImportedCookie], format: Format) -> Int {
        format == .netscape ? cookies.filter(isWritableAsLine).count : cookies.count
    }

    private static func isWritableAsLine(_ cookie: ImportedCookie) -> Bool {
        ![cookie.name, cookie.value, cookie.domain, cookie.path].contains { $0.contains(where: { "\t\r\n".contains($0) }) }
    }

    private static func netscape(_ cookies: [ImportedCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File", "# Exported by PrivacyBrowser. Every value here is in plaintext.", ""]
        for cookie in cookies where isWritableAsLine(cookie) {
            let expiry = cookie.expires.map { String(Int64($0.timeIntervalSince1970.rounded(.down))) } ?? "0"
            let fields = [(cookie.httpOnly ? "#HttpOnly_" : "") + cookie.storedDomain,
                          cookie.hostOnly ? "FALSE" : "TRUE",
                          cookie.path,
                          cookie.secure ? "TRUE" : "FALSE",
                          expiry, cookie.name, cookie.value]
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func extensionEntry(_ cookie: ImportedCookie) -> [String: Any] {
        var entry: [String: Any] = [
            "domain": cookie.storedDomain, "hostOnly": cookie.hostOnly, "httpOnly": cookie.httpOnly,
            "name": cookie.name, "path": cookie.path, "secure": cookie.secure, "session": cookie.expires == nil,
            "storeId": "0", "value": cookie.value,
        ]
        switch cookie.sameSite {
        case .none?: entry["sameSite"] = "no_restriction"
        case .lax?: entry["sameSite"] = "lax"
        case .strict?: entry["sameSite"] = "strict"
        case nil: entry["sameSite"] = "unspecified"
        }
        if let expires = cookie.expires { entry["expirationDate"] = expires.timeIntervalSince1970.rounded(.down) }
        return entry
    }

    private static func playwrightEntry(_ cookie: ImportedCookie) -> [String: Any] {
        var entry: [String: Any] = [
            "name": cookie.name, "value": cookie.value, "domain": cookie.storedDomain, "path": cookie.path,
            "expires": cookie.expires.map { $0.timeIntervalSince1970.rounded(.down) } ?? -1,
            "httpOnly": cookie.httpOnly, "secure": cookie.secure,
        ]
        switch cookie.sameSite {
        case .none?: entry["sameSite"] = "None"
        case .lax?: entry["sameSite"] = "Lax"
        case .strict?: entry["sameSite"] = "Strict"
        case nil: entry["sameSite"] = "Lax" // Playwright requires one; Lax is what browsers assume
        }
        return entry
    }

    private static func json(_ entries: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }
}
