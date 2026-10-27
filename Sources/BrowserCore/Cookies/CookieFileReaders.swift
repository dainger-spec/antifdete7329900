import Foundation

/// Netscape `cookies.txt`: one cookie per line, seven tab-separated fields — domain, include
/// subdomains (TRUE/FALSE), path, secure (TRUE/FALSE), expiry (Unix seconds, 0 for a session
/// cookie), name, value. `#HttpOnly_` before the domain marks an HttpOnly cookie (curl); other
/// lines starting with `#` are comments. Read line by line, so a damaged line costs that line.
/// Tolerated: CRLF, an empty value without its tab, fields separated by spaces instead of tabs.
enum NetscapeReader {
    struct Result {
        var candidates: [Candidate] = []
        var problems: [CookieImportProblem] = []
        /// Lines that looked like a cookie (readable or not): tells this format from another.
        var cookieLikeLines = 0
    }

    static func read(_ text: String) -> Result {
        var result = Result()
        // Any line break: "\r\n" is one Character in Swift, so splitting on "\n" alone would miss it.
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            var line = Substring(raw)
            // Files joined together keep each one's byte order mark.
            while line.first == "\u{FEFF}" { line = line.dropFirst() }
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) { continue }
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line = line.dropFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") {
                continue
            }
            var fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.count < 6 {
                // A copy that turned tabs into spaces: the first six fields hold no spaces, and the
                // two flags say it is a cookie line (not a sentence).
                let spaced = splitOnWhitespace(line, fields: 7)
                let isFlag: (String) -> Bool = { ["TRUE", "FALSE"].contains($0.uppercased()) }
                if spaced.count >= 6, isFlag(spaced[1]), isFlag(spaced[3]) { fields = spaced }
            }
            // A tab in the value would break the line apart: a line with more than seven fields is refused.
            guard (6...7).contains(fields.count) else {
                if fields.count >= 3 { result.cookieLikeLines += 1 }
                if fields.count >= 3 || result.cookieLikeLines > 0 {
                    result.problems.append(CookieImportProblem(location: .line(lineNumber), name: nil,
                                                               reason: .wrongFieldCount(fields.count)))
                }
                continue
            }
            result.cookieLikeLines += 1
            // An empty value loses its tab in some exports.
            let value = fields.count == 7 ? fields[6] : ""
            let flag = fields[1].uppercased()
            let expiry: Candidate.Expiry
            let expiryText = fields[4].trimmingCharacters(in: .whitespaces)
            if let seconds = Double(expiryText), seconds.isFinite {
                expiry = seconds <= 0 ? .session : .at(Date(timeIntervalSince1970: CookieTime.seconds(fromUnixNumber: seconds)))
            } else {
                expiry = .unreadable(expiryText)
            }
            result.candidates.append(Candidate(
                location: .line(lineNumber), name: fields[5], value: value, domain: fields[0],
                hostOnly: flag == "TRUE" ? false : flag == "FALSE" ? (fields[0].hasPrefix(".") ? nil : true) : nil,
                path: fields[2], expiry: expiry, secure: fields[3].uppercased() == "TRUE", httpOnly: httpOnly, sameSite: nil))
        }
        // Lines that are neither comments nor cookies before any cookie line: not this format.
        if result.cookieLikeLines == 0 { result.problems.removeAll() }
        return result
    }

    /// The first `fields - 1` whitespace-separated fields, then the rest of the line as the last.
    private static func splitOnWhitespace(_ line: Substring, fields count: Int) -> [String] {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }
        var fields: [String] = []
        var rest = line.drop(while: isBlank)
        while fields.count < count - 1, !rest.isEmpty {
            let end = rest.firstIndex(where: isBlank) ?? rest.endIndex
            fields.append(String(rest[..<end]))
            rest = rest[end...].drop(while: isBlank)
        }
        if !rest.isEmpty { fields.append(String(rest)) }
        return fields
    }
}

/// Expiry times as exports write them.
enum CookieTime {
    /// Seconds since 1970 from a number that may be in milliseconds or microseconds instead, or
    /// Chrome's microseconds since 1601 (yt-dlp writes those into cookies.txt): any date after
    /// 1970 in Chrome's time is above 1.16e16, Unix microseconds reach 1e16 only in 2286.
    static func seconds(fromUnixNumber value: Double) -> Double {
        if value >= 1e16 { return seconds(fromChromeTime: value) }
        if value > 1e14 { return value / 1e6 } // microseconds
        if value > 1e11 { return value / 1e3 } // milliseconds
        return value
    }

    /// Chrome's database time: microseconds since 1601-01-01.
    static func seconds(fromChromeTime value: Double) -> Double {
        value / 1e6 - 11_644_473_600
    }

    private static let formatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
         "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            return formatter
        }
    }()

    /// A date written as text: a number, an HTTP date, or ISO 8601.
    static func date(fromText text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let number = Double(trimmed), number.isFinite { return Date(timeIntervalSince1970: seconds(fromUnixNumber: number)) }
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// JSON exports: an array of cookie objects, an object holding one under `cookies` (Playwright's
/// `storageState`, the DevTools protocol), a single cookie object, or one object per line. Field
/// names are matched without regard to case, `_` or `-`, so the variants of the different tools
/// map onto the same fields.
///
/// A file that does not parse as a whole is searched for the objects it still holds: every
/// balanced `{…}` outside strings that names a cookie is read on its own (after dropping trailing
/// commas), so a damaged entry, a cut-off end or junk around the data costs only what it touches.
enum JSONReader {
    static func read(_ text: String, problems: inout [CookieImportProblem]) -> [Candidate] {
        let data = Data(text.utf8)
        var errorLine: Int?
        do {
            var whole = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            // JSON inside a string (AdsPower's `cookie` field, Multilogin's API): read it once more.
            if let inner = whole as? String, let first = inner.drop(while: \.isWhitespace).first, first == "[" || first == "{",
               let parsed = try? JSONSerialization.jsonObject(with: Data(inner.utf8), options: [.fragmentsAllowed]) {
                whole = parsed
            }
            let objects = elements(of: whole)
            if !objects.isEmpty || whole is [Any] {
                let lines = objectStartLines(in: text, topIsArray: whole is [Any])
                return objects.enumerated().compactMap { index, object in
                    let line = index < lines.count ? lines[index] : 1
                    return candidate(from: object, location: .entry(index + 1, line: line), problems: &problems)
                }
            }
        } catch {
            // Apple's parser says where it stopped (a byte offset).
            if let offset = (error as NSError).userInfo["NSJSONSerializationErrorIndex"] as? Int, offset <= data.count {
                errorLine = data.prefix(offset).filter { $0 == 0x0A }.count + 1
            }
        }
        // JSON Lines: one object per line, each valid on its own.
        let lines = text.split(whereSeparator: \.isNewline).enumerated()
            .filter { !$0.element.allSatisfy(\.isWhitespace) }
        if lines.count > 1 {
            let parsed = lines.map { (line: $0.offset + 1, object: try? JSONSerialization.jsonObject(with: Data($0.element.utf8))) }
            if parsed.allSatisfy({ $0.object is [String: Any] }) {
                return parsed.enumerated().compactMap { index, item in
                    candidate(from: item.object!, location: .entry(index + 1, line: item.line), problems: &problems)
                }
            }
        }
        return recover(text, errorLine: errorLine, problems: &problems)
    }

    /// The cookie objects a parsed JSON value holds: an array, `cookies` (or another array of
    /// cookie objects) in an object up to three levels down (`{"result": {"cookies": [...]}}`,
    /// `{"data": [...]}`), or a single cookie object.
    private static func elements(of value: Any, depth: Int = 0) -> [Any] {
        if let array = value as? [Any] { return array }
        guard let object = value as? [String: Any] else { return [] }
        let keys = normalizedKeys(object)
        if keys["name"] != nil, depth == 0 { return [object] }
        if let cookies = keys["cookies"] as? [Any] { return cookies }
        if let list = object.values.first(where: { ($0 as? [Any])?.contains { normalizedKeys(($0 as? [String: Any]) ?? [:])["name"] != nil } == true }) as? [Any] {
            return list
        }
        guard depth < 3 else { return [] }
        for (_, inner) in object.sorted(by: { $0.key < $1.key }) where inner is [String: Any] {
            let found = elements(of: inner, depth: depth + 1)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// The line each cookie object starts on: the objects of the top-level array, or of the first
    /// array inside the top-level object (`{"cookies": [...]}`).
    private static func objectStartLines(in text: String, topIsArray: Bool) -> [Int] {
        var lines: [Int] = []
        var line = 1, objectDepth = 0, arrayDepth = 0, inString = false, escaped = false
        var listDepth: (objects: Int, arrays: Int)?
        for character in text {
            if character.isNewline { line += 1 }
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "[":
                arrayDepth += 1
                if listDepth == nil, objectDepth == (topIsArray ? 0 : 1) { listDepth = (objectDepth, arrayDepth) }
            case "]":
                if let list = listDepth, list.arrays == arrayDepth, list.objects == objectDepth, !lines.isEmpty || !topIsArray {
                    listDepth = (-1, -1) // that list ended; later arrays are something else
                }
                arrayDepth -= 1
            case "{":
                if let list = listDepth, list.objects == objectDepth, list.arrays == arrayDepth { lines.append(line) }
                objectDepth += 1
            case "}": objectDepth -= 1
            default: break
            }
        }
        return lines
    }

    /// Reads the cookie objects of a file that is not valid JSON as a whole.
    private static func recover(_ text: String, errorLine: Int?, problems: inout [CookieImportProblem]) -> [Candidate] {
        var candidates: [Candidate] = []
        var damageLine = errorLine
        var stack: [(start: String.Index, line: Int)] = []
        var line = 1, inString = false, escaped = false, entry = 0
        var claimedUntil: String.Index?
        // Objects are read innermost first; a cookie object holding another object (a partition
        // key) is read whole, so only top-most cookie objects count.
        var found: [(range: Range<String.Index>, line: Int)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline { line += 1 }
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" || character.isNewline {
                    // A string cannot span lines in JSON: a newline ends a broken one.
                    inString = false
                    if character.isNewline { damageLine = damageLine ?? line - 1 }
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                stack.append((index, line))
            } else if character == "}", let open = stack.popLast() {
                found.append((open.start..<text.index(after: index), open.line))
            }
            index = text.index(after: index)
        }
        // Outermost first, by position.
        found.sort { $0.range.lowerBound < $1.range.lowerBound || ($0.range.lowerBound == $1.range.lowerBound && $0.range.upperBound > $1.range.upperBound) }
        for object in found {
            if let claimed = claimedUntil, object.range.lowerBound < claimed { continue }
            let body = String(text[object.range])
            // A wrapper ({"cookies": [...]}) is not claimed: the cookie objects inside it are read one by one.
            guard looksLikeCookie(body) else { continue }
            entry += 1
            claimedUntil = object.range.upperBound
            if let parsed = parseObject(body) {
                if let candidate = candidate(from: parsed, location: .entry(entry, line: object.line), problems: &problems) {
                    candidates.append(candidate)
                }
            } else {
                damageLine = damageLine ?? object.line
                problems.append(CookieImportProblem(location: .entry(entry, line: object.line), name: nameIn(body),
                                                    reason: .unreadableEntry("not valid JSON")))
                // Its braces may be off (a quote missing): the objects after its start are read on their own.
                claimedUntil = text.index(after: object.range.lowerBound)
            }
        }
        // Objects left open at the end: the file was cut off inside them.
        for open in stack {
            let body = String(text[open.start...])
            guard looksLikeCookie(body), claimedUntil.map({ open.start >= $0 }) ?? true else { continue }
            entry += 1
            damageLine = damageLine ?? open.line
            problems.append(CookieImportProblem(location: .entry(entry, line: open.line), name: nameIn(body), reason: .cutOff))
            claimedUntil = text.endIndex
        }
        if !candidates.isEmpty || entry > 0 {
            problems.append(CookieImportProblem(location: .file, name: nil, reason: .damagedJSON(line: damageLine ?? 1)))
        }
        return candidates
    }

    /// An object that names a cookie at its own level (before any object or array inside it).
    private static func looksLikeCookie(_ body: String) -> Bool {
        var own = Substring(body.dropFirst())
        var inString = false, escaped = false
        for (offset, character) in own.enumerated() {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                own = own.prefix(offset)
                break
            }
        }
        return own.range(of: #""name"\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func nameIn(_ body: String) -> String? {
        guard let range = body.range(of: #""name"\s*:\s*"([^"\\]{1,200})""#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = body[range]
        guard let colon = match.firstIndex(of: ":") else { return nil }
        return match[match.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
    }

    /// One object's text, also with trailing commas (`{"a": 1,}`), which JSON does not allow.
    private static func parseObject(_ body: String) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] { return object }
        let repaired = body.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        return try? JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
    }

    // MARK: Fields

    /// Keys lower-cased without `_` and `-`: `expirationDate`, `expires_utc`, `is_httponly`, `sameSite`, `same_site`…
    private static func normalizedKeys(_ object: [String: Any]) -> [String: Any] {
        var keys: [String: Any] = [:]
        for (key, value) in object {
            keys[key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")] = value
        }
        return keys
    }

    private static func candidate(from value: Any, location: CookieImportLocation,
                                  problems: inout [CookieImportProblem]) -> Candidate? {
        guard let object = value as? [String: Any] else {
            problems.append(CookieImportProblem(location: location, name: nil, reason: .notACookie))
            return nil
        }
        let fields = normalizedKeys(object)
        guard fields["name"] != nil || fields["value"] != nil else {
            problems.append(CookieImportProblem(location: location, name: nil, reason: .notACookie))
            return nil
        }
        var domain = string(fields["domain"]) ?? string(fields["host"]) ?? string(fields["hostkey"]) ?? ""
        let value = string(fields["value"]) ?? ""
        var refusal: CookieImportReason?
        if value.isEmpty, let encrypted = fields["encryptedvalue"], !(encrypted is NSNull), !(string(encrypted) ?? "x").isEmpty {
            refusal = .encryptedValue
        }
        let partitionKey = fields["partitionkey"]
        if (partitionKey != nil && !(partitionKey is NSNull) && string(partitionKey) != "")
            || !(string(fields["topframesitekey"]) ?? "").isEmpty
            || (string(fields["originattributes"]) ?? "").contains("partitionKey=") {
            refusal = refusal ?? .partitioned
        }
        var hostOnly = bool(fields["hostonly"])
        if domain.isEmpty, let url = string(fields["url"]).flatMap(URL.init(string:)), let host = url.host {
            domain = host
            hostOnly = true
        }
        let expiry: Candidate.Expiry
        if bool(fields["session"]) == true {
            expiry = .session
        } else if let chrome = fields["expiresutc"] {
            if let number = double(chrome) {
                expiry = number <= 0 ? .session : .at(Date(timeIntervalSince1970: CookieTime.seconds(fromChromeTime: number)))
            } else {
                expiry = .unreadable(string(chrome) ?? "?")
            }
        } else if let raw = fields["expirationdate"] ?? fields["expires"] ?? fields["expiry"] ?? fields["expirationtime"] {
            if raw is NSNull {
                // The DevTools protocol writes null for "never" (with session false).
                expiry = bool(fields["session"]) == false ? .unlimited : .session
            } else if let number = double(raw) {
                expiry = number <= 0 ? .session : .at(Date(timeIntervalSince1970: CookieTime.seconds(fromUnixNumber: number)))
            } else if let text = string(raw), let date = CookieTime.date(fromText: text) {
                expiry = .at(date)
            } else if let text = string(raw), text.isEmpty || text.lowercased() == "session" {
                expiry = .session
            } else {
                expiry = .unreadable(string(raw) ?? "\(raw)")
            }
        } else {
            expiry = .session
        }
        return Candidate(location: location, name: string(fields["name"]) ?? "", value: value,
                         domain: domain, hostOnly: hostOnly, path: string(fields["path"]) ?? "/", expiry: expiry,
                         secure: bool(fields["secure"]) ?? bool(fields["issecure"]) ?? false,
                         httpOnly: bool(fields["httponly"]) ?? bool(fields["ishttponly"]) ?? false,
                         sameSite: sameSite(fields["samesite"]), refusal: refusal)
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        if let number = value as? NSNumber, !isBoolean(number) { return number.doubleValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: return number.intValue != 0
        case let text as String:
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        return false
        #endif
    }

    /// `no_restriction`/`none` (0), `lax` (1), `strict` (2); `unspecified` (-1) and anything else: nil.
    private static func sameSite(_ value: Any?) -> ImportedCookie.SameSite? {
        if let number = value as? NSNumber, !isBoolean(number) {
            switch number.intValue {
            case 0: return ImportedCookie.SameSite.none
            case 1: return .lax
            case 2: return .strict
            default: return nil
            }
        }
        switch string(value)?.lowercased().replacingOccurrences(of: "_", with: "") {
        case "none", "norestriction": return ImportedCookie.SameSite.none
        case "lax": return .lax
        case "strict": return .strict
        default: return nil
        }
    }
}
