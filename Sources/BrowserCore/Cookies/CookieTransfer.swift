import Foundation
#if canImport(FoundationNetworking)
// On Linux `HTTPCookie` lives in FoundationNetworking, not Foundation.
import FoundationNetworking
#endif

/// One browser cookie in a storage-neutral form, used to move cookies between a profile's
/// WebKit cookie store and files (`CookieTransfer`).
///
/// Domain convention (shared by WebKit/CFNetwork, curl and the Netscape file format): a
/// leading dot marks a *domain* cookie, which is also sent to subdomains; no dot marks a
/// *host-only* cookie, sent to exactly that host. `hostOnly` is derived from it, never stored,
/// so the two cannot disagree.
///
/// Not represented: partitioned (CHIPS) cookie keys, priority and the RFC 2965 version.
/// WebKit's public `WKHTTPCookieStore` does not expose them either.
public struct CookieRecord: Codable, Equatable, Sendable {
    /// Careful with `.none` where a `SameSite?` is expected: the compiler reads it as
    /// `Optional.none` (nil). Write `CookieRecord.SameSite.none` or `.some(.none)` there.
    public enum SameSite: String, Codable, CaseIterable, Sendable {
        case lax, strict, none
    }

    /// Lowercased by `normalized()`. Leading dot = domain cookie; see the type comment.
    public var domain: String
    public var path: String
    public var name: String
    public var value: String
    public var secure: Bool
    public var httpOnly: Bool
    /// `nil` = session cookie (dropped when the profile's session ends).
    public var expires: Date?
    /// `nil` = not specified. Browsers then apply their own default (Lax in Chromium, None in
    /// WebKit), so `nil` and `.none` are not the same thing in an export.
    public var sameSite: SameSite?

    public init(domain: String, path: String = "/", name: String, value: String,
                secure: Bool = false, httpOnly: Bool = false, expires: Date? = nil,
                sameSite: SameSite? = nil) {
        self.domain = domain
        self.path = path
        self.name = name
        self.value = value
        self.secure = secure
        self.httpOnly = httpOnly
        self.expires = expires
        self.sameSite = sameSite
    }

    /// True when the cookie is sent only to exactly `bareDomain` (domain has no leading dot).
    public var hostOnly: Bool { !domain.hasPrefix(".") }

    /// The domain without its leading dot, for display and grouping.
    public var bareDomain: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }

    public var isSession: Bool { expires == nil }

    /// Expired cookies are kept by the parsers (a file is imported as written); the app
    /// decides whether to drop them. Session cookies never count as expired.
    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expires else { return false }
        return expires <= date
    }

    /// Whether the record can be imported or exported, after the normalization the parsers
    /// apply (domain lowercased, empty path → "/", expiry truncated to whole seconds, at
    /// least 1). Also false for name + value over 4096 bytes or a path over 1024 bytes.
    public var isValid: Bool { normalized() != nil }

    private enum CodingKeys: String, CodingKey {
        case domain, path, name, value, secure, httpOnly, expires, sameSite
    }

    /// Tolerant decoding: fields added in later versions fall back to their defaults, and an
    /// unknown `sameSite` value reads as "not specified" instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domain = try c.decode(String.self, forKey: .domain)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/"
        name = try c.decode(String.self, forKey: .name)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        httpOnly = try c.decodeIfPresent(Bool.self, forKey: .httpOnly) ?? false
        expires = try c.decodeIfPresent(Date.self, forKey: .expires)
        sameSite = (try? c.decodeIfPresent(String.self, forKey: .sameSite)).flatMap(SameSite.init(rawValue:))
    }
}

// MARK: - Validation

extension CookieRecord {
    /// 9999-12-31T23:59:59Z. Later expiries are treated as garbage (or milliseconds, which
    /// cannot be told apart reliably) and the record is skipped.
    static let maxExpiry: TimeInterval = 253_402_300_799

    /// RFC 6265bis has browsers ignore a cookie whose name plus value exceed 4096 bytes and a
    /// path attribute over 1024 bytes, so no real cookie store holds a larger one.
    /// `WKHTTPCookieStore.setCookie` does not apply Set-Cookie parsing limits, so without this
    /// check an imported file could plant multi-megabyte cookies that every request then carries.
    static let maxNameValueBytes = 4096
    static let maxPathBytes = 1024

    /// The canonical form, or `nil` if the record is unusable. Parsers and exporters both
    /// pass every record through here, so a file this module writes always re-imports.
    func normalized() -> CookieRecord? {
        var record = self
        record.domain = domain.lowercased()
        if record.path.isEmpty { record.path = "/" }
        if let expires {
            let seconds = expires.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds <= Self.maxExpiry else { return nil }
            // Whole seconds: Netscape files cannot hold more, and integral values convert
            // between Date's 2001 epoch and the Unix epoch exactly, so round trips compare equal.
            // At least 1: both file formats read 0 as "session cookie", so an expiry within the
            // first second of 1970 would come back as a live session cookie, not an expired one.
            record.expires = Date(timeIntervalSince1970: max(seconds.rounded(.down), 1))
        }
        return record.isWellFormed ? record : nil
    }

    private var isWellFormed: Bool {
        let bare = bareDomain
        guard !bare.isEmpty, !bare.hasPrefix("."), !bare.contains(".."), domain.utf8.count <= 255,
              !bare.unicodeScalars.contains(where: Self.isForbiddenInDomain) else { return false }
        guard name.utf8.count + value.utf8.count <= Self.maxNameValueBytes,
              path.utf8.count <= Self.maxPathBytes else { return false }
        // Tabs and line breaks would also corrupt a Netscape file; ';' would split the
        // cookie when WebKit serializes the Cookie header.
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { Self.isControl($0) || $0 == ";" }) else { return false }
        guard !name.isEmpty,
              !name.unicodeScalars.contains(where: { Self.isControl($0) || $0 == ";" || $0 == "=" }) else { return false }
        // RFC 6265bis allows HTAB inside a value; the Netscape parser keeps it (7th field = rest).
        guard !value.unicodeScalars.contains(where: { ($0 != "\t" && Self.isControl($0)) || $0 == ";" }) else {
            return false
        }
        return true
    }

    /// C0 controls (including TAB), DEL and C1 controls.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    private static func isForbiddenInDomain(_ scalar: Unicode.Scalar) -> Bool {
        isControl(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
            || "/\\;,@?#=\"'<>".unicodeScalars.contains(scalar)
    }
}

// MARK: - HTTPCookie bridge

extension CookieRecord {
    /// Converts a Foundation cookie (as returned by `WKHTTPCookieStore.getAllCookies`).
    /// Returns `nil` for cookies this type cannot represent faithfully (see `isValid`).
    /// An expiry later than year 9999 is clamped rather than rejected: it came from a real
    /// cookie store, not from a file of unknown origin.
    ///
    /// SameSite is read only on Apple platforms; swift-corelibs-foundation has no
    /// `sameSitePolicy`, so on Linux it is always `nil`. Apple's policy has no "None" value
    /// (WebKit reports SameSite=None as no policy), so it reads back as `nil` too.
    public init?(_ cookie: HTTPCookie) {
        var expires: Date?
        // Read the date, not only `isSessionOnly`: corelibs reports a cookie without
        // `expires` as non-session unless `discard` was set explicitly.
        if !cookie.isSessionOnly, let date = cookie.expiresDate {
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite else { return nil }
            // Cookie expiry is whole-second (RFC 6265); Apple's HTTPCookie round-trips expiresDate
            // through its own representation and can come back with sub-second drift that
            // swift-corelibs-foundation doesn't have. Floor to the second so the value is
            // deterministic across platforms.
            let clamped = min(seconds, Self.maxExpiry).rounded()
            expires = Date(timeIntervalSince1970: clamped)
        }
        var sameSite: SameSite?
        #if canImport(Darwin)
        sameSite = cookie.sameSitePolicy.flatMap { SameSite(rawValue: $0.rawValue.lowercased()) }
        #endif
        let record = CookieRecord(domain: cookie.domain, path: cookie.path, name: cookie.name,
                                  value: cookie.value, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
                                  expires: expires, sameSite: sameSite)
        guard let normalized = record.normalized() else { return nil }
        self = normalized
    }

    /// A Foundation cookie for `WKHTTPCookieStore.setCookie`, or `nil` if the record is
    /// invalid or Foundation refuses it.
    ///
    /// Platform notes: the `HttpOnly` property key is not a public constant but is the one
    /// WebKit itself uses when it builds `NSHTTPCookie`s; swift-corelibs-foundation recognises
    /// the same key. Corelibs only accepts the string "TRUE" for boolean properties, Apple's
    /// Foundation documents both strings and booleans. `.sameSite == .none` sets no policy,
    /// which is how Apple's Foundation represents SameSite=None.
    public var httpCookie: HTTPCookie? {
        guard let record = normalized() else { return nil }
        #if canImport(Darwin)
        let yes: Any = true
        #else
        let yes: Any = "TRUE"
        #endif
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: record.domain,
            .path: record.path,
            .name: record.name,
            .value: record.value,
        ]
        if record.secure { properties[.secure] = yes }
        if record.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = yes }
        if let expires = record.expires {
            properties[.expires] = expires
        } else {
            properties[.discard] = "TRUE"
        }
        #if canImport(Darwin)
        switch record.sameSite {
        // The plain string, as WebKit passes it; Foundation reads the property as NSString.
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case .some(.none), nil: break
        }
        #endif
        return HTTPCookie(properties: properties)
    }
}

// MARK: - Files

public enum CookieFormat: String, CaseIterable, Sendable {
    /// `cookies.txt` as written by curl, wget, yt-dlp and "cookies.txt" browser extensions.
    case netscape
    /// JSON as exported by Cookie-Editor / EditThisCookie (also reads Puppeteer, Playwright
    /// and Selenium cookie dumps).
    case json

    public var fileExtension: String {
        switch self {
        case .netscape: return "txt"
        case .json: return "json"
        }
    }
}

public struct CookieParseResult: Equatable, Sendable {
    /// Valid, de-duplicated cookies in file order. For a repeated (domain, path, name) the
    /// last occurrence wins, as it would when setting them one by one.
    public var cookies: [CookieRecord]
    /// Records that were present but unusable (malformed line, invalid field, absurd expiry,
    /// over the cookie cap). Blank lines and comments are not counted.
    public var skipped: Int

    public init(cookies: [CookieRecord], skipped: Int) {
        self.cookies = cookies
        self.skipped = skipped
    }
}

/// Reads and writes cookie files so a profile's login sessions can be moved in and out.
///
/// The files are plaintext by nature: an exported cookie file is as good as the logins it
/// contains. The app layer should say so when saving one; nothing here encrypts it.
///
/// Robustness rules for imported data (files come from anywhere):
///   * Input larger than `maxInputBytes` is rejected before parsing.
///   * At most `maxCookies` cookies are returned; the rest are counted as skipped.
///   * Invalid records are skipped and counted, never fatal; only an unreadable JSON
///     document as a whole throws.
///   * Numeric fields are range-checked before conversion, so no input can trap.
///
/// Expiry rules for numbers in files (Unix seconds): `0` and `-1` mean a session cookie (the
/// Netscape and Puppeteer/Playwright conventions); other negative values, non-finite values
/// and values after year 9999 (for example millisecond timestamps) skip the record. Fractions
/// are truncated to whole seconds, and an expiry inside the first second of 1970 is kept as
/// `1` so that no export writes an expired cookie as the session marker `0`.
///
/// Size rules (RFC 6265bis): a record whose name plus value exceed 4096 bytes, or whose path
/// exceeds 1024 bytes, is skipped.
public enum CookieTransfer {
    public static let maxInputBytes = 10 * 1024 * 1024
    public static let maxCookies = 20_000

    private static let netscapeHeader = "# Netscape HTTP Cookie File"
    private static let httpOnlyPrefix = "#HttpOnly_"

    /// JSON if the first significant byte (after an optional UTF-8 BOM and whitespace) is
    /// `[` or `{`, otherwise Netscape.
    public static func detectFormat(_ data: Data) -> CookieFormat {
        for byte in stripBOM(data) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            case UInt8(ascii: "["), UInt8(ascii: "{"): return .json
            default: return .netscape
            }
        }
        return .netscape
    }

    /// Detects the format and parses. Throws `CoreError.invalidConfiguration` for input over
    /// `maxInputBytes` and `CoreError.unsupportedFormat` for a JSON document that is not a
    /// cookie list. A text file with no recognizable cookie lines returns an empty result.
    public static func parse(_ data: Data) throws -> CookieParseResult {
        try checkSize(data)
        switch detectFormat(data) {
        case .json:
            return try parseJSON(data)
        case .netscape:
            let body = stripBOM(data)
            // Cookie files are ASCII in practice; Latin-1 keeps a non-UTF-8 file readable
            // instead of mangling it. Both steps are done by hand: Foundation's `.isoLatin1`
            // decoding on Linux returns nil for data containing tabs, which every cookie line has.
            let utf8 = String(decoding: body, as: UTF8.self)
            if utf8.utf8.elementsEqual(body) { return parseNetscape(utf8) }
            var latin1 = String.UnicodeScalarView()
            latin1.append(contentsOf: body.map { Unicode.Scalar($0) })
            return parseNetscape(String(latin1))
        }
    }

    // MARK: Netscape

    /// Parses `cookies.txt`: one cookie per line, 7 tab-separated fields
    /// `domain  includeSubdomains  path  secure  expiry  name  value`.
    ///
    ///   * `includeSubdomains` (TRUE/FALSE) decides the leading dot on the domain, as in curl.
    ///   * A `#HttpOnly_` prefix on the domain marks an HttpOnly cookie (curl's convention);
    ///     every other line starting with `#` is a comment.
    ///   * A line with only 6 fields has an empty value (curl writes and accepts that).
    ///   * An empty expiry field is a session cookie, like `0` (Python's http.cookiejar, yt-dlp).
    ///   * Extra tabs belong to the value: the 7th field is the rest of the line.
    ///   * LF, CRLF and CR line endings are accepted. A line without any tab is split on runs
    ///     of spaces instead, which recovers files whose tabs were lost in copy and paste.
    ///   * SameSite cannot be expressed in this format and is always `nil`.
    ///
    /// Does not enforce `maxInputBytes`; `parse(_:)` does.
    public static func parseNetscape(_ text: String) -> CookieParseResult {
        var accumulator = Accumulator()
        let body = text.hasPrefix("\u{FEFF}") ? Substring(text.dropFirst()) : Substring(text)
        // "\r\n" is a single Character in Swift, so splitting on "\n" alone would miss it.
        for line in body.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            switch netscapeLine(line) {
            case .ignored: continue
            case .malformed: accumulator.skip()
            case .cookie(let record): accumulator.add(record)
            }
        }
        return accumulator.result
    }

    private enum LineResult {
        case ignored
        case malformed
        case cookie(CookieRecord)
    }

    private static func netscapeLine(_ rawLine: Substring) -> LineResult {
        var line = rawLine
        if line.allSatisfy({ $0 == " " || $0 == "\t" }) { return .ignored }
        var httpOnly = false
        if line.hasPrefix(httpOnlyPrefix) {
            httpOnly = true
            line = line.dropFirst(httpOnlyPrefix.count)
        } else if line.hasPrefix("#") {
            return .ignored
        }

        // At most 7 fields, the 7th keeping any further tabs: a hostile line of millions of
        // tabs must not become millions of substrings.
        var fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
        if fields.count == 1 {
            fields = splitOnSpaces(line, maxFields: 7)
        }
        guard fields.count >= 6 else { return .malformed }

        guard let includeSubdomains = netscapeBool(fields[1]),
              let secure = netscapeBool(fields[3]) else { return .malformed }
        let expires: Date?
        // An empty expiry is a session cookie: Python's http.cookiejar (MozillaCookieJar) and
        // yt-dlp write session cookies that way, and those are often the login cookies.
        switch fields[4].allSatisfy({ $0 == " " }) ? .session : expiry(fromText: fields[4]) {
        case .invalid: return .malformed
        case .session: expires = nil
        case .at(let date): expires = date
        }
        let value = fields.count > 6 ? String(fields[6]) : ""
        let record = CookieRecord(domain: domain(String(fields[0]), hostOnly: !includeSubdomains),
                                  path: String(fields[2]), name: String(fields[5]), value: value,
                                  secure: secure, httpOnly: httpOnly, expires: expires)
        guard let normalized = record.normalized() else { return .malformed }
        return .cookie(normalized)
    }

    private static func netscapeBool(_ field: Substring) -> Bool? {
        switch field.uppercased() {
        case "TRUE": return true
        case "FALSE": return false
        default: return nil
        }
    }

    /// Splits on runs of spaces into at most `maxFields` fields; the last one keeps the rest.
    private static func splitOnSpaces(_ line: Substring, maxFields: Int) -> [Substring] {
        var fields: [Substring] = []
        var rest = line.drop(while: { $0 == " " })
        while !rest.isEmpty {
            if fields.count == maxFields - 1 {
                fields.append(rest)
                break
            }
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            fields.append(rest[..<end])
            rest = rest[end...].drop(while: { $0 == " " })
        }
        return fields
    }

    /// Writes `cookies.txt` with the standard header, `#HttpOnly_` lines for HttpOnly cookies
    /// and `0` as the expiry of session cookies. SameSite is not representable and is lost.
    /// Records that fail validation are left out.
    public static func exportNetscape(_ cookies: [CookieRecord]) -> String {
        var lines = [
            netscapeHeader,
            "# https://curl.se/docs/http-cookies.html",
            "# This file contains login sessions. Anyone who has it can use them; keep it private.",
            "",
        ]
        for cookie in cookies {
            guard let record = cookie.normalized() else { continue }
            let expiry = record.expires.map(netscapeSeconds) ?? 0
            let fields = [
                (record.httpOnly ? httpOnlyPrefix : "") + record.domain,
                record.hostOnly ? "FALSE" : "TRUE",
                record.path,
                record.secure ? "TRUE" : "FALSE",
                String(expiry),
                record.name,
                record.value,
            ]
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whole Unix seconds, at least 1 so an expiring cookie is never written as `0` (session).
    private static func netscapeSeconds(_ date: Date) -> Int {
        let seconds = min(max(date.timeIntervalSince1970.rounded(.down), 1), CookieRecord.maxExpiry)
        return Int(exactly: seconds) ?? 1
    }

    // MARK: JSON

    /// Parses a JSON cookie list: a bare array, or an object with a `cookies` array
    /// (Playwright `storageState`). Recognised fields per cookie:
    ///
    ///   * `domain`, `path` (default "/"), `name`, `value` (default "")
    ///   * `secure`, `httpOnly`: booleans (also "true"/"false" strings and 0/1)
    ///   * `hostOnly`: when present it decides the leading dot (false adds it, true removes it);
    ///     when absent the dot in `domain` is taken as is
    ///   * `session: true` → session cookie regardless of any expiry field
    ///   * expiry: `expirationDate` (Cookie-Editor, EditThisCookie; may be fractional),
    ///     `expires` (Puppeteer, Playwright; -1 = session) or `expiry` (Selenium), as Unix
    ///     seconds, a numeric string or an ISO 8601 date string. None → session cookie.
    ///   * `sameSite`: lax / strict / no_restriction / none / unspecified, case-insensitive;
    ///     anything else → not specified.
    ///
    /// Other fields (`storeId`, `id`, `priority`, `partitionKey`, ...) are ignored.
    public static func parseJSON(_ data: Data) throws -> CookieParseResult {
        try checkSize(data)
        let body = stripBOM(data)
        guard nestingDepth(of: body, limit: maxJSONNesting) <= maxJSONNesting else {
            throw CoreError.unsupportedFormat("JSON is nested too deeply to be a cookie list")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } catch {
            throw CoreError.unsupportedFormat("the file is not valid JSON")
        }
        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let object = root as? [String: Any], let array = object["cookies"] as? [Any] {
            items = array
        } else {
            throw CoreError.unsupportedFormat("JSON must be a list of cookies or an object with a \"cookies\" list")
        }
        var accumulator = Accumulator()
        for item in items {
            if let object = item as? [String: Any], let record = cookie(fromJSON: object) {
                accumulator.add(record)
            } else {
                accumulator.skip()
            }
        }
        return accumulator.result
    }

    /// Cookie files nest 2–5 levels (Playwright's storageState is the deepest). The limit is
    /// checked before JSONSerialization runs, so a hostile file cannot rely on how deep a
    /// given Foundation version lets its recursive parser go.
    private static let maxJSONNesting = 32

    /// Maximum `[`/`{` depth outside string literals, counting stops just past `limit`.
    private static func nestingDepth(of data: Data, limit: Int) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
                if deepest > limit { return deepest }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
            default:
                break
            }
        }
        return deepest
    }

    private static func cookie(fromJSON object: [String: Any]) -> CookieRecord? {
        guard let name = object["name"] as? String,
              var domain = object["domain"] as? String else { return nil }
        let value: String
        switch object["value"] {
        case nil, is NSNull: value = ""
        case let string as String: value = string
        default: return nil
        }
        let path: String
        switch object["path"] {
        case nil, is NSNull: path = "/"
        case let string as String: path = string
        default: return nil
        }
        if let hostOnly = jsonBool(object["hostOnly"]) {
            domain = self.domain(domain, hostOnly: hostOnly)
        }

        var expires: Date?
        if jsonBool(object["session"]) != true,
           let raw = ["expirationDate", "expires", "expiry"].lazy.compactMap({ object[$0] }).first(where: { !($0 is NSNull) }) {
            switch jsonExpiry(raw) {
            case .invalid: return nil
            case .session: expires = nil
            case .at(let date): expires = date
            }
        }

        let sameSite: CookieRecord.SameSite?
        switch (object["sameSite"] as? String)?.lowercased() {
        case "lax": sameSite = .lax
        case "strict": sameSite = .strict
        case "no_restriction", "none": sameSite = CookieRecord.SameSite.none
        default: sameSite = nil
        }

        let record = CookieRecord(domain: domain, path: path, name: name, value: value,
                                  secure: jsonBool(object["secure"]) ?? false,
                                  httpOnly: jsonBool(object["httpOnly"]) ?? false,
                                  expires: expires, sameSite: sameSite)
        return record.normalized()
    }

    /// JSONSerialization yields NSNumber for both booleans and numbers (Apple and corelibs);
    /// accept those, Swift Bool, and the usual strings.
    private static func jsonBool(_ raw: Any?) -> Bool? {
        switch raw {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.doubleValue != 0
        case let string as String:
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func jsonExpiry(_ raw: Any) -> Expiry {
        switch raw {
        case let number as NSNumber:
            return expiry(fromUnixSeconds: number.doubleValue)
        case let string as String:
            let numeric = expiry(fromText: Substring(string))
            if numeric != .invalid { return numeric }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return expiry(fromUnixSeconds: date.timeIntervalSince1970) }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: string) { return expiry(fromUnixSeconds: date.timeIntervalSince1970) }
            return .invalid
        default:
            return .invalid
        }
    }

    /// Writes a Cookie-Editor-compatible JSON array (sorted keys, pretty-printed), which
    /// Cookie-Editor, EditThisCookie and this app all import:
    /// `domain`, `expirationDate` (omitted for session cookies), `hostOnly`, `httpOnly`,
    /// `name`, `path`, `sameSite` (lax / strict / no_restriction / unspecified), `secure`,
    /// `session`, `value`. `storeId` is deliberately omitted: a browser-specific store ID
    /// makes some importers fail. Records that fail validation are left out.
    public static func exportJSON(_ cookies: [CookieRecord]) throws -> Data {
        let exported = cookies.compactMap { $0.normalized() }.map(ExportedCookie.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(exported)
        } catch {
            throw CoreError.invalidConfiguration("cannot encode cookies: \(error)")
        }
    }

    private struct ExportedCookie: Encodable {
        var domain: String
        var expirationDate: Double?
        var hostOnly: Bool
        var httpOnly: Bool
        var name: String
        var path: String
        var sameSite: String
        var secure: Bool
        var session: Bool
        var value: String

        init(_ record: CookieRecord) {
            domain = record.domain
            expirationDate = record.expires?.timeIntervalSince1970
            hostOnly = record.hostOnly
            httpOnly = record.httpOnly
            name = record.name
            path = record.path
            switch record.sameSite {
            case .lax: sameSite = "lax"
            case .strict: sameSite = "strict"
            case .some(.none): sameSite = "no_restriction"
            case nil: sameSite = "unspecified"
            }
            secure = record.secure
            session = record.expires == nil
            value = record.value
        }
    }

    // MARK: Shared helpers

    private static func checkSize(_ data: Data) throws {
        guard data.count <= maxInputBytes else {
            throw CoreError.invalidConfiguration("cookie file is larger than \(maxInputBytes / 1_048_576) MB")
        }
    }

    private static func stripBOM(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    }

    /// Applies the leading-dot convention for an explicit host-only flag.
    private static func domain(_ domain: String, hostOnly: Bool) -> String {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return hostOnly || bare.isEmpty ? bare : "." + bare
    }

    private enum Expiry: Equatable {
        case session
        case at(Date)
        case invalid
    }

    private static func expiry(fromText text: Substring) -> Expiry {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Plain decimal only: Double(_:) would also accept "nan", "inf" and hex floats.
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "+" }),
              let seconds = Double(trimmed) else { return .invalid }
        return expiry(fromUnixSeconds: seconds)
    }

    private static func expiry(fromUnixSeconds seconds: Double) -> Expiry {
        guard seconds.isFinite else { return .invalid }
        if seconds == 0 || seconds == -1 { return .session }
        guard seconds > 0, seconds <= CookieRecord.maxExpiry else { return .invalid }
        return .at(Date(timeIntervalSince1970: seconds.rounded(.down)))
    }

    /// De-duplicates and caps. Callers pass records that are already normalized.
    private struct Accumulator {
        private struct Key: Hashable {
            var domain: String
            var path: String
            var name: String
        }

        private var cookies: [CookieRecord] = []
        private var positions: [Key: Int] = [:]
        private var skipped = 0

        mutating func skip() { skipped += 1 }

        mutating func add(_ record: CookieRecord) {
            let key = Key(domain: record.domain, path: record.path, name: record.name)
            if let position = positions[key] {
                cookies[position] = record
                return
            }
            guard cookies.count < CookieTransfer.maxCookies else {
                skipped += 1
                return
            }
            positions[key] = cookies.count
            cookies.append(record)
        }

        var result: CookieParseResult { CookieParseResult(cookies: cookies, skipped: skipped) }
    }
}
