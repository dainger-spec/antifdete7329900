import Foundation

/// The local automation API: profiles started, stopped, opened on an address and their cookies
/// read and written by a script on this Mac — curl, Python, `scripts/pbctl` — as the app's own
/// buttons do. docs/AUTOMATION_API.md describes it for its users.
///
/// Off unless turned on. It listens on the loopback address only, one request per connection,
/// and answers only a request that
///   * carries the token (`Authorization: Bearer <token>`), compared in constant time: other
///     programs of this user cannot drive the profiles without it;
///   * names this listener in `Host` (127.0.0.1, localhost or [::1] with its port): a web page
///     that points a name of its own at 127.0.0.1 (DNS rebinding) is refused;
///   * comes from no web page: a browser sends `Origin` (and `Sec-Fetch-*`) with every
///     cross-origin request, so one that has any is refused before the token is looked at, and
///     no answer carries a CORS header for a page to read.
/// Nothing it answers holds a secret: a profile's proxy is its kind, host and port, never its
/// credentials; cookies, which are a session's secret, only when asked for by name.
public enum AutomationHTTP {
    public static let maximumHeaderBytes = 16 * 1024
    /// A cookie file being imported is the largest body there is.
    public static let maximumBodyBytes = 8 * 1024 * 1024

    public struct Request: Equatable, Sendable {
        public var method: String
        /// The path, percent-decoded segment by segment by the router, without the query.
        public var path: String
        public var query: [String: String]
        /// Header names in lower case.
        public var headers: [String: String]
        public var body: Data

        public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
            self.body = body
        }
    }

    public enum Parsed: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        case request(Request)
        /// Not a request this API takes: answer `response` and close.
        case invalid(Response)
    }

    public struct Response: Equatable, Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data

        public init(status: Int, contentType: String = "application/json", body: Data) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        /// `{"error": code, "message": message}`.
        public static func error(_ status: Int, _ code: String, _ message: String) -> Response {
            json(status, ["error": code, "message": message])
        }

        public static func json<T: Encodable>(_ status: Int, _ value: T) -> Response {
            let encoder = JSONEncoder()
            // An address reads as one (`http://…`, not `http:\/\/…`): scripts compare it as text.
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
            return Response(status: status, body: body + Data("\n".utf8))
        }

        /// The bytes on the wire. No CORS header, nothing cached, and the connection closes.
        public func serialized() -> Data {
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Cache-Control: no-store\r\n"
            head += "X-Content-Type-Options: nosniff\r\n"
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + body
        }

        static func reason(_ status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 409: return "Conflict"
            case 411: return "Length Required"
            case 413: return "Payload Too Large"
            case 431: return "Request Header Fields Too Large"
            case 500: return "Internal Server Error"
            case 503: return "Service Unavailable"
            default: return "Status"
            }
        }
    }

    /// Reads one request from the bytes received so far.
    public static func parse(_ data: Data) -> Parsed {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maximumHeaderBytes
                ? .invalid(.error(431, "headers_too_large", "The request's headers are too large."))
                : .incomplete
        }
        guard end.lowerBound <= maximumHeaderBytes else {
            return .invalid(.error(431, "headers_too_large", "The request's headers are too large."))
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(.error(400, "bad_request", "The request is not text."))
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), !requestLine[0].isEmpty,
              requestLine[1].hasPrefix("/") else {
            return .invalid(.error(400, "bad_request", "Not an HTTP/1.1 request."))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(.error(400, "bad_request", "A header line has no name."))
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else {
                return .invalid(.error(400, "bad_request", "A header name is not valid."))
            }
            // Two of these would leave which one counts to whoever reads it.
            if headers[name] != nil, ["host", "authorization", "content-length", "origin"].contains(name) {
                return .invalid(.error(400, "bad_request", "The \(name) header is given twice."))
            }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(.error(411, "length_required", "Send the body with a Content-Length."))
        }
        var length = 0
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else {
                return .invalid(.error(400, "bad_request", "Content-Length is not a number."))
            }
            length = value
        }
        guard length <= maximumBodyBytes else {
            return .invalid(.error(413, "payload_too_large", "The body is larger than \(maximumBodyBytes) bytes."))
        }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = String(requestLine[1])
        let path: String, queryText: String
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            queryText = String(target[target.index(after: mark)...])
        } else {
            path = target
            queryText = ""
        }
        var query: [String: String] = [:]
        for pair in queryText.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
            query[name] = value
        }
        return .request(Request(method: String(requestLine[0]).uppercased(), path: path, query: query,
                                headers: headers, body: Data(body)))
    }
}

/// Whether the API is on, where it listens and the token it asks for. This Mac's, kept in the
/// vault's device settings (`DeviceSettings.automation`), never synced.
public struct AutomationSettings: Codable, Equatable, Sendable {
    public static let defaultPort = 50_777
    public static let ports = 1024...65535

    public var isEnabled: Bool
    public var port: Int
    public var token: String

    public init(isEnabled: Bool = false, port: Int = AutomationSettings.defaultPort, token: String = AutomationSettings.newToken()) {
        self.isEnabled = isEnabled
        self.port = port
        self.token = token
    }

    /// 32 random bytes, base64url without padding: 43 characters.
    public static func newToken() -> String {
        secureRandomBytes(32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What a request must be before the API acts on it (`AutomationHTTP`).
public enum AutomationGate {
    /// The refusal to send instead of acting on `request`, or nil when it may be acted on.
    public static func refusal(of request: AutomationHTTP.Request, token: String, port: Int) -> AutomationHTTP.Response? {
        // A web page's request, whatever else it carries.
        if request.headers["origin"] != nil || request.headers.keys.contains(where: { $0.hasPrefix("sec-fetch-") }) {
            return .error(403, "forbidden", "Requests from web pages are refused.")
        }
        let host = request.headers["host"]?.lowercased() ?? ""
        guard ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host) else {
            return .error(403, "forbidden", "The Host header must name this listener (127.0.0.1:\(port)).")
        }
        let given = request.headers["authorization"] ?? ""
        guard given.hasPrefix("Bearer "), sameSecret(String(given.dropFirst("Bearer ".count)), token), !token.isEmpty else {
            return .error(401, "unauthorized", "The token is missing or wrong (Authorization: Bearer <token>).")
        }
        return nil
    }

    /// Equal, in a time that does not depend on where they differ.
    static func sameSecret(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for index in 0..<max(x.count, y.count) {
            difference |= (index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0)
        }
        return difference == 0
    }
}

/// What a request asks for. A profile is named by its id or by its exact name.
public enum AutomationRoute: Equatable, Sendable {
    case listProfiles
    case profile(String)
    /// `window`: false starts it out of sight, as a warm-up does.
    case start(String, window: Bool)
    case stop(String)
    /// Another window of a running profile, on `url` (http or https).
    case open(String, url: URL)
    case exportCookies(String, CookieExport.Format)
    /// The body: any cookie file the app imports (`CookieImporter`).
    case importCookies(String, Data)

    /// The route of `request`, or the answer for one that names none.
    public static func of(_ request: AutomationHTTP.Request) -> Result<AutomationRoute, AutomationRefusal> {
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
            String($0).removingPercentEncoding ?? String($0)
        }
        guard segments.first == "v1", segments.count >= 2, segments[1] == "profiles" else {
            return .failure(AutomationRefusal(.error(404, "not_found", "No such endpoint; see docs/AUTOMATION_API.md.")))
        }
        var rest = Array(segments.dropFirst(2))
        if rest.last == "" { rest.removeLast() }
        func only(_ method: String, _ route: () -> Result<AutomationRoute, AutomationRefusal>) -> Result<AutomationRoute, AutomationRefusal> {
            request.method == method ? route()
                : .failure(AutomationRefusal(.error(405, "method_not_allowed", "Use \(method) here.")))
        }
        switch rest.count {
        case 0:
            return only("GET") { .success(.listProfiles) }
        case 1 where !rest[0].isEmpty:
            return only("GET") { .success(.profile(rest[0])) }
        case 2 where !rest[0].isEmpty:
            let profile = rest[0]
            switch rest[1] {
            case "start":
                return only("POST") {
                    guard let body = object(request.body) else { return .failure(badJSON) }
                    return .success(.start(profile, window: body["window"] as? Bool ?? true))
                }
            case "stop":
                return only("POST") { .success(.stop(profile)) }
            case "open":
                return only("POST") {
                    guard let body = object(request.body), let text = body["url"] as? String,
                          let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !(url.host ?? "").isEmpty else {
                        return .failure(AutomationRefusal(.error(400, "bad_request", "Give {\"url\": \"https://…\"}: an http or https address.")))
                    }
                    return .success(.open(profile, url: url))
                }
            case "cookies":
                if request.method == "GET" {
                    guard let format = cookieFormat(request.query["format"]) else {
                        return .failure(AutomationRefusal(.error(400, "bad_request", "format is netscape, extension or playwright.")))
                    }
                    return .success(.exportCookies(profile, format))
                }
                return only("POST") {
                    request.body.isEmpty
                        ? .failure(AutomationRefusal(.error(400, "bad_request", "Send the cookie file as the body.")))
                        : .success(.importCookies(profile, request.body))
                }
            default:
                break
            }
        default:
            break
        }
        return .failure(AutomationRefusal(.error(404, "not_found", "No such endpoint; see docs/AUTOMATION_API.md.")))
    }

    /// The default is Playwright's, which Puppeteer takes as well.
    static func cookieFormat(_ name: String?) -> CookieExport.Format? {
        switch name?.lowercased() {
        case nil, "", "playwright": return .playwright
        case "netscape", "txt": return .netscape
        case "extension", "json": return .extensionJSON
        default: return nil
        }
    }

    /// An empty body reads as `{}`.
    private static func object(_ body: Data) -> [String: Any]? {
        if body.isEmpty || body.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static let badJSON = AutomationRefusal(.error(400, "bad_request", "The body is not a JSON object."))
}

/// A request the API answers without acting on it.
public struct AutomationRefusal: Error, Equatable, Sendable {
    public let response: AutomationHTTP.Response
    public init(_ response: AutomationHTTP.Response) { self.response = response }
}

/// Profiles as the API shows them.
public enum AutomationProfiles {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var running: Bool
        /// Starting, stopping or sealing: wait and ask again.
        public var busy: Bool
        public var lastLaunchedAt: Date?
        /// `socks5://host:port` or `http://host:port`; never the credentials.
        public var proxy: String?

        public init(_ summary: ProfileSummary, running: Bool, busy: Bool, proxy: ProxySettings?) {
            id = summary.id
            name = summary.name
            self.running = running
            self.busy = busy
            lastLaunchedAt = summary.lastLaunchedAt
            self.proxy = proxy.map { "\($0.kind == .socks5 ? "socks5" : "http")://\($0.host):\($0.port)" }
        }
    }

    /// The profile `reference` names: its id, or else its exact name, which must be one profile's.
    public static func find(_ reference: String, in profiles: [ProfileSummary]) -> Result<ProfileSummary, AutomationRefusal> {
        if let id = UUID(uuidString: reference), let profile = profiles.first(where: { $0.id == id }) {
            return .success(profile)
        }
        let named = profiles.filter { $0.name == reference }
        switch named.count {
        case 1: return .success(named[0])
        case 0: return .failure(AutomationRefusal(.error(404, "not_found", "No profile has this id or name.")))
        default: return .failure(AutomationRefusal(.error(409, "ambiguous", "\(named.count) profiles have this name; use the id.")))
        }
    }
}
