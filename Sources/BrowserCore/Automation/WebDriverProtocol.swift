import Foundation

/// An error as the W3C WebDriver protocol says it: its code ("no such element"), the HTTP status
/// that goes with it, and a message for the person reading the client's exception.
public struct WebDriverError: Error, Equatable, Sendable, Codable {
    public var code: String
    public var status: Int
    public var message: String

    public init(_ code: String, _ status: Int, _ message: String) {
        self.code = code
        self.status = status
        self.message = message
    }

    public static func invalidArgument(_ message: String) -> WebDriverError { .init("invalid argument", 400, message) }
    public static func invalidSelector(_ message: String) -> WebDriverError { .init("invalid selector", 400, message) }
    public static func noSuchElement(_ message: String) -> WebDriverError { .init("no such element", 404, message) }
    public static func staleElement(_ message: String) -> WebDriverError { .init("stale element reference", 404, message) }
    public static func notInteractable(_ message: String) -> WebDriverError { .init("element not interactable", 400, message) }
    public static func clickIntercepted(_ message: String) -> WebDriverError { .init("element click intercepted", 400, message) }
    public static func noSuchSession(_ message: String) -> WebDriverError { .init("invalid session id", 404, message) }
    public static func noSuchCookie(_ message: String) -> WebDriverError { .init("no such cookie", 404, message) }
    public static func noSuchAlert(_ message: String) -> WebDriverError { .init("no such alert", 404, message) }
    public static func noSuchWindow(_ message: String) -> WebDriverError { .init("no such window", 404, message) }
    public static func unknownCommand(_ message: String) -> WebDriverError { .init("unknown command", 404, message) }
    public static func unknownMethod(_ message: String) -> WebDriverError { .init("unknown method", 405, message) }
    public static func unsupported(_ message: String) -> WebDriverError { .init("unsupported operation", 500, message) }
    public static func javascript(_ message: String) -> WebDriverError { .init("javascript error", 500, message) }
    public static func timeout(_ message: String) -> WebDriverError { .init("timeout", 500, message) }
    public static func scriptTimeout(_ message: String) -> WebDriverError { .init("script timeout", 500, message) }
    public static func sessionNotCreated(_ message: String) -> WebDriverError { .init("session not created", 500, message) }
    public static func unknown(_ message: String) -> WebDriverError { .init("unknown error", 500, message) }

    /// The response's body: `{"value": {"error", "message", "stacktrace"}}`.
    public var body: Data {
        let value: [String: Any] = ["error": code, "message": message, "stacktrace": ""]
        return (try? JSONSerialization.data(withJSONObject: ["value": value], options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// A WebDriver request, read from its method and path (docs/AUTOMATION.md, "WebDriver"):
/// `/wd/<token>/<profile>/session/<id>/element/<element>/attribute/<name>`. The token and the
/// profile are part of the address a client is given; the rest is the protocol's own.
public struct WebDriverRequest: Equatable, Sendable {
    public var token: String
    /// The profile the address names: its id, or its exact name.
    public var profile: String
    /// The protocol's command, by the name it has here ("navigate", "findElement"…).
    public var command: String
    public var session: String?
    public var element: String?
    /// An attribute's, property's, CSS property's or cookie's name, from the path.
    public var name: String?

    public init(token: String, profile: String, command: String, session: String? = nil, element: String? = nil, name: String? = nil) {
        self.token = token
        self.profile = profile
        self.command = command
        self.session = session
        self.element = element
        self.name = name
    }
}

public enum WebDriverRoute {
    public static let prefix = "/wd/"
    /// The key a protocol's JSON names an element by.
    public static let elementKey = "element-6066-11e4-a52e-4f735466cecf"

    /// Whether `path` is the WebDriver's (the automation API's other routes are under `/v1/`).
    public static func handles(_ path: String) -> Bool { path.hasPrefix(prefix) }

    /// The address a client is given for a profile: `http://127.0.0.1:<port>/wd/<token>/<profile id>`.
    public static func address(port: Int, token: String, profile: UUID) -> String {
        "http://127.0.0.1:\(port)\(prefix)\(token)/\(profile.uuidString)"
    }

    public static func parse(method: String, path: String) -> Result<WebDriverRequest, WebDriverError> {
        guard handles(path) else { return .failure(.unknownCommand("not a WebDriver address")) }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2 else { return .failure(.unknownCommand("the address names no profile: /wd/<token>/<profile>/…")) }
        let token = parts[0], profile = parts[1]
        let rest = Array(parts.dropFirst(2))
        let method = method.uppercased()
        func request(_ command: String, session: String? = nil, element: String? = nil, name: String? = nil) -> Result<WebDriverRequest, WebDriverError> {
            .success(WebDriverRequest(token: token, profile: profile, command: command, session: session, element: element, name: name))
        }
        func choose(_ byMethod: [String: String], session: String? = nil, element: String? = nil, name: String? = nil) -> Result<WebDriverRequest, WebDriverError> {
            guard let command = byMethod[method] else {
                return .failure(.unknownMethod("\(method) is not a method of /\(rest.joined(separator: "/"))"))
            }
            return request(command, session: session, element: element, name: name)
        }
        if rest == ["status"] { return choose(["GET": "status"]) }
        guard rest.first == "session" else { return .failure(.unknownCommand("/\(rest.joined(separator: "/")) is not a WebDriver command")) }
        if rest.count == 1 { return choose(["POST": "newSession"]) }
        let session = rest[1]
        let tail = Array(rest.dropFirst(2))
        if tail.isEmpty { return choose(["DELETE": "deleteSession"], session: session) }
        if tail.first == "element", tail.count >= 2, tail[1] != "active" {
            let element = tail[1]
            let about = Array(tail.dropFirst(2))
            switch about.count {
            case 1:
                let simple: [String: [String: String]] = [
                    "element": ["POST": "findElement"], "elements": ["POST": "findElements"],
                    "click": ["POST": "click"], "clear": ["POST": "clear"], "value": ["POST": "sendKeys"],
                    "text": ["GET": "elementText"], "name": ["GET": "elementTagName"], "rect": ["GET": "elementRect"],
                    "enabled": ["GET": "elementEnabled"], "selected": ["GET": "elementSelected"],
                    "displayed": ["GET": "elementDisplayed"], "screenshot": ["GET": "elementScreenshot"],
                ]
                if let byMethod = simple[about[0]] { return choose(byMethod, session: session, element: element) }
            case 2:
                let named = ["attribute": "elementAttribute", "property": "elementProperty", "css": "elementCSS"]
                if let command = named[about[0]] { return choose(["GET": command], session: session, element: element, name: about[1]) }
            default: break
            }
            return .failure(.unknownCommand("/\(rest.joined(separator: "/")) is not a WebDriver command"))
        }
        if tail.first == "cookie", tail.count == 2 {
            return choose(["GET": "getCookie", "DELETE": "deleteCookie"], session: session, name: tail[1])
        }
        let table: [String: [String: String]] = [
            "url": ["POST": "navigate", "GET": "currentURL"],
            "back": ["POST": "back"], "forward": ["POST": "forward"], "refresh": ["POST": "refresh"],
            "title": ["GET": "title"], "source": ["GET": "pageSource"],
            "timeouts": ["GET": "getTimeouts", "POST": "setTimeouts"],
            "window": ["GET": "windowHandle", "DELETE": "closeWindow", "POST": "switchWindow"],
            "window/handles": ["GET": "windowHandles"],
            "window/rect": ["GET": "getWindowRect", "POST": "setWindowRect"],
            "window/maximize": ["POST": "maximizeWindow"],
            "element": ["POST": "findElement"], "elements": ["POST": "findElements"],
            "element/active": ["GET": "activeElement"],
            "execute/sync": ["POST": "executeSync"], "execute/async": ["POST": "executeAsync"],
            "cookie": ["GET": "getCookies", "POST": "addCookie", "DELETE": "deleteCookies"],
            "screenshot": ["GET": "screenshot"],
            "actions": ["POST": "performActions", "DELETE": "releaseActions"],
            "alert/text": ["GET": "alert", "POST": "alert"], "alert/accept": ["POST": "alert"], "alert/dismiss": ["POST": "alert"],
            "frame": ["POST": "frame"], "frame/parent": ["POST": "frame"],
            "window/minimize": ["POST": "windowState"], "window/fullscreen": ["POST": "windowState"], "window/new": ["POST": "newWindow"],
            "print": ["POST": "print"],
        ]
        guard let byMethod = table[tail.joined(separator: "/")] else {
            return .failure(.unknownCommand("/\(rest.joined(separator: "/")) is not a WebDriver command"))
        }
        return choose(byMethod, session: session)
    }
}

/// What "send keys" types: a client's text with the protocol's own code points for keys that are
/// not characters (U+E000…), as strokes the page's driver can make.
public enum WebDriverKeys {
    public enum Stroke: Equatable, Sendable {
        /// Characters, typed one by one.
        case type(String)
        /// A key or a combination, as the driver names them: "Enter", "Shift+Tab", "Meta+a".
        case press(String)
    }

    private static let named: [UInt32: String] = [
        0xE003: "Backspace", 0xE004: "Tab", 0xE006: "Enter", 0xE007: "Enter", 0xE00C: "Escape", 0xE00D: "Space",
        0xE012: "ArrowLeft", 0xE013: "ArrowUp", 0xE014: "ArrowRight", 0xE015: "ArrowDown",
    ]
    private static let modifiers: [UInt32: String] = [0xE008: "Shift", 0xE009: "Control", 0xE00A: "Alt", 0xE03D: "Meta"]

    /// The strokes `text` asks for. A modifier holds until the protocol's NULL (U+E000) or the
    /// text's end; a key this cannot press is refused by its code point.
    public static func strokes(_ text: String) throws -> [Stroke] {
        var strokes: [Stroke] = []
        var held: [String] = []
        var run = ""
        func flush() {
            if !run.isEmpty { strokes.append(.type(run)) }
            run = ""
        }
        for character in text {
            let scalars = Array(character.unicodeScalars)
            guard scalars.count == 1, (0xE000...0xE05D).contains(scalars[0].value) else {
                if held.isEmpty {
                    run.append(character)
                } else {
                    strokes.append(.press((held + [String(character)]).joined(separator: "+")))
                }
                continue
            }
            flush()
            let code = scalars[0].value
            if code == 0xE000 {
                held = []
            } else if let modifier = modifiers[code] {
                if !held.contains(modifier) { held.append(modifier) }
            } else if let key = named[code] {
                strokes.append(.press((held + [key]).joined(separator: "+")))
            } else {
                throw WebDriverError.unsupported(String(format: "the key U+%04X is not one this can press", code))
            }
        }
        flush()
        return strokes
    }
}
