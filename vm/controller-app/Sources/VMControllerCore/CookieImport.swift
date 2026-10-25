import Foundation

/// A cookie, normalized across the import formats. This is the shape the agent
/// receives (as a JSON array) and applies in the VM's Safari.
public struct Cookie: Codable, Equatable, Sendable {
    public var domain: String
    public var path: String
    public var name: String
    public var value: String
    public var secure: Bool
    public var httpOnly: Bool
    /// Unix seconds; nil = session cookie.
    public var expires: Int?

    public init(domain: String, path: String = "/", name: String, value: String,
                secure: Bool = false, httpOnly: Bool = false, expires: Int? = nil) {
        self.domain = domain
        self.path = path
        self.name = name
        self.value = value
        self.secure = secure
        self.httpOnly = httpOnly
        self.expires = expires
    }
}

/// Imports cookies from the two formats people actually have: the Netscape
/// `cookies.txt` that curl/wget/extensions emit, and the JSON arrays that
/// browser extensions (EditThisCookie, Cookie-Editor) export.
public enum CookieImport {
    public enum Format { case netscape, json }

    public static func detectFormat(_ text: String) -> Format {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") || trimmed.hasPrefix("{") ? .json : .netscape
    }

    /// Parse either format (auto-detected). Throws on malformed JSON; skips
    /// malformed Netscape lines rather than failing the whole file.
    public static func parse(_ text: String) throws -> [Cookie] {
        switch detectFormat(text) {
        case .json: try parseJSON(text)
        case .netscape: parseNetscape(text)
        }
    }

    // MARK: Netscape cookies.txt

    /// Tab-separated: domain, includeSubdomains, path, secure, expiry, name, value.
    /// A leading "#HttpOnly_" on the domain marks an http-only cookie (curl's
    /// convention). "# " lines are comments.
    public static func parseNetscape(_ text: String) -> [Cookie] {
        var cookies: [Cookie] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var domainField = line
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                domainField = String(line.dropFirst("#HttpOnly_".count))
            } else if line.hasPrefix("#") {
                continue // comment
            }
            // Rebuild the line without the HttpOnly prefix, then split on tabs.
            let fields = (httpOnly ? domainField : line).split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 7 else { continue }
            let expiry = Int(fields[4])
            cookies.append(Cookie(
                domain: fields[0],
                path: fields[2].isEmpty ? "/" : fields[2],
                name: fields[5],
                value: fields[6],
                secure: fields[3].uppercased() == "TRUE",
                httpOnly: httpOnly,
                expires: (expiry ?? 0) > 0 ? expiry : nil))
        }
        return cookies
    }

    // MARK: JSON (extension exports)

    private struct RawCookie: Decodable {
        let domain: String?
        let path: String?
        let name: String?
        let value: String?
        let secure: Bool?
        let httpOnly: Bool?
        let hostOnly: Bool?
        // expirationDate is seconds (often fractional); some tools use expires/expiry.
        let expirationDate: Double?
        let expires: Double?
        let expiry: Double?
    }

    public static func parseJSON(_ text: String) throws -> [Cookie] {
        guard let data = text.data(using: .utf8) else { throw CookieError.badEncoding }
        let raws: [RawCookie]
        do {
            // Accept either a bare array or an object with a "cookies" array.
            if let array = try? JSONDecoder().decode([RawCookie].self, from: data) {
                raws = array
            } else {
                struct Wrapper: Decodable { let cookies: [RawCookie] }
                raws = try JSONDecoder().decode(Wrapper.self, from: data).cookies
            }
        } catch {
            throw CookieError.badJSON
        }
        return raws.compactMap { raw in
            guard let domain = raw.domain, !domain.isEmpty,
                  let name = raw.name, let value = raw.value else { return nil }
            let seconds = raw.expirationDate ?? raw.expires ?? raw.expiry
            return Cookie(
                domain: domain,
                path: raw.path?.isEmpty == false ? raw.path! : "/",
                name: name,
                value: value,
                secure: raw.secure ?? false,
                httpOnly: raw.httpOnly ?? false,
                expires: seconds.map { Int($0) }.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// The JSON the agent consumes: a stable, pretty array of normalized cookies.
    public static func serialize(_ cookies: [Cookie]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(cookies)
    }
}

public enum CookieError: Error, Equatable, CustomStringConvertible {
    case badEncoding, badJSON

    public var description: String {
        switch self {
        case .badEncoding: "cookie file is not valid UTF-8"
        case .badJSON: "cookie file is not a recognized JSON cookie export"
        }
    }
}
