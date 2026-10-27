import Foundation

/// A cookie read from an export file and checked, ready to be handed to WebKit.
public struct ImportedCookie: Codable, Equatable, Sendable {
    public enum SameSite: String, Codable, Sendable {
        case none, lax, strict
    }

    public var name: String
    public var value: String
    /// Lower case, without a leading dot.
    public var domain: String
    /// Sent to `domain` only; otherwise to its subdomains too (a `Domain=` cookie, written with a
    /// leading dot).
    public var hostOnly: Bool
    public var path: String
    /// Nil: a session cookie (kept until the profile stops).
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool
    /// Nil: not specified (WebKit's default).
    public var sameSite: SameSite?

    public init(name: String, value: String, domain: String, hostOnly: Bool, path: String = "/", expires: Date? = nil,
                secure: Bool = false, httpOnly: Bool = false, sameSite: SameSite? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.hostOnly = hostOnly
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }

    /// The domain as a cookie store writes it: a leading dot for a cookie its subdomains get too.
    public var storedDomain: String { hostOnly ? domain : "." + domain }

    /// A browser keeps one cookie per name, domain (host-only or not) and path.
    public var identity: String { [name, storedDomain, path].joined(separator: "\u{0}") }
}

/// Where in the file a problem is.
public enum CookieImportLocation: Equatable, Sendable {
    /// The file as a whole.
    case file
    /// A line of a Netscape file.
    case line(Int)
    /// The `index`th cookie of a JSON file (1-based), which starts on `line`.
    case entry(Int, line: Int)
}

/// Why a cookie (or part of the file) was not imported.
public enum CookieImportReason: Equatable, Sendable {
    /// Neither JSON nor Netscape cookies.txt.
    case unrecognizedFormat
    /// The file is larger than `CookieImporter.maximumFileSize`.
    case fileTooLarge(Int)
    /// The file could not be read at all (detail from the system).
    case unreadableFile(String)
    /// A file of another kind (a browser's cookie database, a web page, an archive…), named.
    case unsupportedFile(String)
    /// The JSON is damaged at `line`: what could be read around the damage was imported.
    case damagedJSON(line: Int)
    /// The file ends inside this entry.
    case cutOff
    /// Not valid JSON (detail from the parser).
    case unreadableEntry(String)
    /// A JSON value that is not a cookie object.
    case notACookie
    /// A Netscape line without its seven tab-separated fields.
    case wrongFieldCount(Int)
    case missingName
    case invalidName
    case invalidValue
    /// Bytes that are not valid text (a damaged or wrongly encoded file).
    case damagedText
    /// A row of Chrome's cookie database whose value is encrypted (only Chrome can read it).
    case encryptedValue
    /// A partitioned (CHIPS) cookie: WebKit has no public way to set one, and unpartitioned it
    /// would be sent more widely than the site allowed.
    case partitioned
    /// Name and value longer than 4096 bytes together.
    case tooLarge
    case missingDomain
    case invalidDomain(String)
    /// A cookie for every site under a public suffix (`.com`, `.co.uk`, `.github.io`): browsers refuse it.
    case publicSuffixDomain(String)
    case invalidPath(String)
    case invalidExpiry(String)
    case expired(Date)
    /// `__Secure-` / `__Host-` cookies must be Secure (and `__Host-` host-only with path `/`).
    case prefixRequirements(String)
    /// The same cookie (name, domain, path) again later in the file: the later one is imported.
    case replacedByLaterEntry(CookieImportLocation)
}

public struct CookieImportProblem: Error, Equatable, Sendable {
    public var location: CookieImportLocation
    /// The cookie's name, when it could be read.
    public var name: String?
    public var reason: CookieImportReason

    public init(location: CookieImportLocation, name: String?, reason: CookieImportReason) {
        self.location = location
        self.name = name
        self.reason = reason
    }
}

/// What reading a cookie file found: the cookies to import and, for everything left out, where it
/// is in the file and why.
public struct CookieImportReport: Equatable, Sendable {
    public enum Format: String, Equatable, Sendable {
        case json, netscape
    }

    public var format: Format?
    /// How the bytes were read: "UTF-8", "UTF-8 (BOM)", "UTF-16LE", "UTF-16BE".
    public var encoding: String
    /// Byte sequences that were not valid text (replaced; a cookie containing one is left out).
    public var damagedByteSequences: Int
    /// Entries (JSON cookie objects, Netscape cookie lines) the file holds, readable or not.
    public var entriesFound: Int
    public var cookies: [ImportedCookie]
    public var problems: [CookieImportProblem]

    /// Problems that left a cookie (or part of the file) out, not counting replaced duplicates.
    public var failures: [CookieImportProblem] {
        problems.filter { if case .replacedByLaterEntry = $0.reason { return false } else { return true } }
    }
}

/// Reads cookie exports: Netscape `cookies.txt` (curl, wget, yt-dlp, browser extensions) and JSON
/// (EditThisCookie / Cookie-Editor, Puppeteer and the DevTools protocol, Playwright `cookies` and
/// `storageState`, Selenium, exports of Chrome's and Firefox's cookie databases, JSON Lines).
///
/// Built to import whatever is importable from a damaged file: bytes that are not text spoil only
/// the cookies they are in; a Netscape file is read line by line; a JSON file that does not parse
/// is searched for the cookie objects it still holds (one damaged or cut-off entry costs that
/// entry). Every cookie is checked as a browser would check it (name and value characters, size,
/// domain — never a public suffix —, path, expiry, `__Secure-`/`__Host-` rules); the report says
/// where each left-out one is and why.
public enum CookieImporter {
    /// Larger files are refused (an export of a whole browser is a few megabytes).
    public static let maximumFileSize = 32 * 1024 * 1024
    /// Name and value together, as browsers limit them.
    public static let maximumCookieSize = 4096

    /// A report for a file that could not be read (`.fileTooLarge`, `.unreadableFile`).
    public static func failedFile(_ reason: CookieImportReason) -> CookieImportReport {
        CookieImportReport(format: nil, encoding: "", damagedByteSequences: 0, entriesFound: 0, cookies: [],
                           problems: [CookieImportProblem(location: .file, name: nil, reason: reason)])
    }

    /// Reads a file from disk: refused before reading when larger than `maximumFileSize`.
    public static func read(contentsOf url: URL, now: Date = Date()) -> CookieImportReport {
        do {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            guard size <= maximumFileSize else { return failedFile(.fileTooLarge(size)) }
            return read(try Data(contentsOf: url), now: now)
        } catch {
            return failedFile(.unreadableFile(error.localizedDescription))
        }
    }

    public static func read(_ data: Data, now: Date = Date()) -> CookieImportReport {
        guard data.count <= maximumFileSize else { return failedFile(.fileTooLarge(data.count)) }
        if let kind = otherFileKind(data) { return failedFile(.unsupportedFile(kind)) }
        let decoded = decodeText(data)
        var report = CookieImportReport(format: nil, encoding: decoded.encoding, damagedByteSequences: decoded.damaged,
                                        entriesFound: 0, cookies: [], problems: [])
        let text = decoded.text
        let trimmed = text.drop { $0.isWhitespace }
        var candidates: [Candidate] = []
        if trimmed.first == "[" || trimmed.first == "{" {
            report.format = .json
            candidates = JSONReader.read(text, problems: &report.problems)
        } else {
            let netscape = NetscapeReader.read(text)
            if netscape.candidates.isEmpty, netscape.cookieLikeLines == 0 {
                // Neither: maybe JSON after some junk (a log line, a stray character).
                var jsonProblems: [CookieImportProblem] = []
                let json = JSONReader.read(text, problems: &jsonProblems)
                if json.isEmpty {
                    report.problems.append(CookieImportProblem(location: .file, name: nil, reason: .unrecognizedFormat))
                    return report
                }
                report.format = .json
                report.problems += jsonProblems
                candidates = json
            } else {
                report.format = .netscape
                report.problems += netscape.problems
                candidates = netscape.candidates
            }
        }
        report.entriesFound = candidates.count + report.problems.filter(\.isEntryProblem).count
        var accepted: [(cookie: ImportedCookie, location: CookieImportLocation)] = []
        for candidate in candidates {
            switch candidate.validated(now: now) {
            case let .success(cookie): accepted.append((cookie, candidate.location))
            case let .failure(problem): report.problems.append(problem)
            }
        }
        // One cookie per name, domain and path: the later entry wins, as a browser would keep it.
        var latest: [String: Int] = [:]
        for (index, item) in accepted.enumerated() { latest[item.cookie.identity] = index }
        for (index, item) in accepted.enumerated() {
            if let later = latest[item.cookie.identity], later != index {
                report.problems.append(CookieImportProblem(location: item.location, name: item.cookie.name,
                                                           reason: .replacedByLaterEntry(accepted[later].location)))
            } else {
                report.cookies.append(item.cookie)
            }
        }
        report.problems.sort { $0.location.sortKey < $1.location.sortKey }
        return report
    }

    /// Files people pick instead of an export: browser databases, archives, a saved web page.
    static func otherFileKind(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        let signatures: [([UInt8], String)] = [
            (Array("SQLite format 3".utf8) + [0], "SQLite database (a browser's cookie database: export it with an extension)"),
            (Array("cook".utf8), "Safari binary cookies"),
            (Array("mozLz40".utf8) + [0], "Firefox compressed session file"),
            ([0x50, 0x4B, 0x03, 0x04], "ZIP archive"),
            ([0x1F, 0x8B], "gzip archive"),
            (Array("%PDF".utf8), "PDF document"),
        ]
        if let match = signatures.first(where: { bytes.starts(with: $0.0) }) { return match.1 }
        if bytes.count >= 2, bytes[0] == 0x80, (2...5).contains(bytes[1]) { return "Python pickle (Selenium)" }
        let head = String(decoding: data.prefix(256), as: UTF8.self).lowercased().drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return "web page (HTML)" }
        return nil
    }

    // MARK: Text

    /// The file's text: UTF-8 (with or without BOM) or UTF-16 (BOM, or the zero bytes of ASCII
    /// text in UTF-16). Bytes that are not valid become U+FFFD and are counted.
    static func decodeText(_ data: Data) -> (text: String, encoding: String, damaged: Int) {
        let bytes = [UInt8](data)
        // UTF-32 before UTF-16: its little-endian BOM starts like UTF-16's.
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return decodeUTF32(bytes.dropFirst(4), littleEndian: true) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return decodeUTF32(bytes.dropFirst(4), littleEndian: false) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            let (text, damaged) = decodeUTF8(bytes.dropFirst(3))
            return (text, "UTF-8 (BOM)", damaged)
        }
        if bytes.starts(with: [0xFF, 0xFE]) { return decodeUTF16(bytes.dropFirst(2), littleEndian: true) }
        if bytes.starts(with: [0xFE, 0xFF]) { return decodeUTF16(bytes.dropFirst(2), littleEndian: false) }
        // No BOM: ASCII text in UTF-16 has a zero byte in every pair.
        let sample = bytes.prefix(512)
        if sample.count >= 4 {
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let pairs = sample.count / 2
            if oddZeros * 10 >= pairs * 8 && evenZeros * 10 < pairs { return decodeUTF16(bytes[...], littleEndian: true) }
            if evenZeros * 10 >= pairs * 8 && oddZeros * 10 < pairs { return decodeUTF16(bytes[...], littleEndian: false) }
        }
        let (text, damaged) = decodeUTF8(bytes[...])
        return (text, "UTF-8", damaged)
    }

    private static func decodeUTF8(_ bytes: ArraySlice<UInt8>) -> (String, Int) {
        var damaged = 0
        var scalars = String.UnicodeScalarView()
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        loop: while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): scalars.append(scalar)
            case .emptyInput: break loop
            case .error:
                damaged += 1
                scalars.append(Unicode.Scalar(0xFFFD)!)
            }
        }
        return (String(scalars), damaged)
    }

    private static func decodeUTF32(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> (String, String, Int) {
        var scalars = String.UnicodeScalarView()
        var damaged = bytes.count % 4 == 0 ? 0 : 1
        var index = bytes.startIndex
        while index + 3 < bytes.endIndex {
            let b = (0..<4).map { UInt32(bytes[index + $0]) }
            let value = littleEndian ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[3] | b[2] << 8 | b[1] << 16 | b[0] << 24
            if let scalar = Unicode.Scalar(value) {
                scalars.append(scalar)
            } else {
                damaged += 1
                scalars.append(Unicode.Scalar(0xFFFD)!)
            }
            index += 4
        }
        return (String(scalars), littleEndian ? "UTF-32LE" : "UTF-32BE", damaged)
    }

    private static func decodeUTF16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> (String, String, Int) {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
            units.append(littleEndian ? a | b << 8 : a << 8 | b)
            index += 2
        }
        var damaged = index < bytes.endIndex ? 1 : 0 // an odd trailing byte
        var scalars = String.UnicodeScalarView()
        var decoder = UTF16()
        var iterator = units.makeIterator()
        loop: while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): scalars.append(scalar)
            case .emptyInput: break loop
            case .error:
                damaged += 1
                scalars.append(Unicode.Scalar(0xFFFD)!)
            }
        }
        return (String(scalars), littleEndian ? "UTF-16LE" : "UTF-16BE", damaged)
    }
}

// MARK: - Candidates and checks

/// A cookie as an export file states it, before the checks.
struct Candidate {
    var location: CookieImportLocation
    var name: String
    var value: String
    var domain: String
    /// From the file: true host-only, false domain cookie, nil: decided by a leading dot.
    var hostOnly: Bool?
    var path: String
    var expiry: Expiry
    var secure: Bool
    var httpOnly: Bool
    var sameSite: ImportedCookie.SameSite?
    /// A reason the reader already knows the cookie cannot be imported (encrypted, partitioned).
    var refusal: CookieImportReason?

    enum Expiry {
        case session
        case at(Date)
        /// Persistent without an end (the DevTools protocol writes null): kept 400 days, the most
        /// a browser keeps a cookie (RFC 6265bis).
        case unlimited
        case unreadable(String)
    }

    func validated(now: Date) -> Result<ImportedCookie, CookieImportProblem> {
        let readableName = self.name.isEmpty || self.name.contains("\u{FFFD}") ? nil : self.name
        func fail(_ reason: CookieImportReason) -> Result<ImportedCookie, CookieImportProblem> {
            .failure(CookieImportProblem(location: location, name: readableName, reason: reason))
        }
        if name.contains("\u{FFFD}") || value.contains("\u{FFFD}") || domain.contains("\u{FFFD}") { return fail(.damagedText) }
        if let refusal { return fail(refusal) }
        // RFC 6265bis: spaces and tabs around name and value are not part of them; inside, control
        // characters (a tab aside, in a value), ";" and, in a name, "=" are not allowed.
        let blanks = CharacterSet(charactersIn: " \t")
        let name = self.name.trimmingCharacters(in: blanks)
        let value = self.value.trimmingCharacters(in: blanks)
        guard !name.isEmpty else { return fail(.missingName) }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == ";" || $0 == "=" }) else {
            return fail(.invalidName)
        }
        guard !value.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F || $0 == ";" }) else {
            return fail(.invalidValue)
        }
        guard name.utf8.count + value.utf8.count <= CookieImporter.maximumCookieSize else { return fail(.tooLarge) }

        // Domain: lower case; a leading dot means a domain cookie; a URL or a port is tolerated.
        var domain = self.domain.trimmingCharacters(in: .whitespaces).lowercased()
        if domain.contains("://"), let host = URL(string: domain)?.host { domain = host }
        var leadingDot = false
        while domain.hasPrefix(".") {
            leadingDot = true
            domain.removeFirst()
        }
        if domain.hasSuffix(".") { domain.removeLast() }
        if !domain.hasPrefix("["), let colon = domain.lastIndex(of: ":"), domain[domain.index(after: colon)...].allSatisfy(\.isNumber),
           domain.filter({ $0 == ":" }).count == 1 {
            domain = String(domain[..<colon])
        }
        guard !domain.isEmpty else { return fail(.missingDomain) }
        guard domain.unicodeScalars.allSatisfy({ $0.isASCII }) else { return fail(.invalidDomain(domain)) }
        let isIP = Self.isIPAddress(domain)
        if !isIP {
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            let validLabel: (Substring) -> Bool = { label in
                !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            }
            guard domain.count <= 253, labels.allSatisfy(validLabel) else { return fail(.invalidDomain(domain)) }
        }
        // An IP address only ever matches itself.
        let hostOnly = isIP ? true : hostOnly ?? !leadingDot
        if !hostOnly, PublicSuffixList.registrableDomain(of: domain) == nil, domain != "localhost" {
            return fail(.publicSuffixDomain(domain))
        }

        // A missing or relative path is "/", as a browser without the page's own path would take it.
        let path = self.path.hasPrefix("/") ? self.path : "/"
        guard path.utf8.count <= 1024, !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == ";" }) else {
            return fail(.invalidPath(path))
        }

        var expires: Date?
        switch expiry {
        case .session: expires = nil
        case let .at(date):
            guard date > now else { return fail(.expired(date)) }
            expires = date
        case .unlimited: expires = now.addingTimeInterval(400 * 86_400)
        case let .unreadable(text): return fail(.invalidExpiry(text))
        }

        // Cookie prefixes (RFC 6265bis), compared without regard to case as browsers now do.
        let lowered = name.lowercased()
        if lowered.hasPrefix("__secure-"), !secure { return fail(.prefixRequirements("__Secure-")) }
        if lowered.hasPrefix("__host-"), !secure || !hostOnly || path != "/" { return fail(.prefixRequirements("__Host-")) }

        return .success(ImportedCookie(name: name, value: value, domain: domain, hostOnly: hostOnly, path: path,
                                       expires: expires, secure: secure, httpOnly: httpOnly, sameSite: sameSite))
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && Int($0)! <= 255 }
    }
}

extension CookieImportProblem {
    /// A problem with one entry of the file (it counts towards the entries found).
    var isEntryProblem: Bool {
        switch reason {
        case .unrecognizedFormat, .fileTooLarge, .unreadableFile, .unsupportedFile, .damagedJSON: return false
        default: return true
        }
    }
}

extension CookieImportLocation {
    var sortKey: Int {
        switch self {
        case .file: return -1
        case let .line(line): return line
        case let .entry(_, line): return line
        }
    }
}
