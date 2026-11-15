import AppKit
import BrowserCore
import os
import WebKit

/// A WebDriver command to a profile, as it crosses to the process that has the profile's window.
struct WebDriverCall: Codable, Equatable {
    var id: UUID
    var command: String
    var element: String?
    var name: String?
    /// The request's JSON body, as text ("{}" for none).
    var body: String
}

/// Its answer: the protocol's value as JSON text, or the protocol's error.
struct WebDriverAnswer: Codable, Equatable {
    var id: UUID
    var value: String?
    var error: WebDriverError?
}

/// The WebDriver's commands done to one page of a profile (docs/AUTOMATION.md, "WebDriver"), in
/// the process that has the profile's window: what is asked of the page goes through the page's
/// driver — the pointer and the keys a page takes for a person's (`PageDriver`, `PageInput`) —
/// and the scripts of `WebDriverScripts`, in the driver's own world.
@MainActor
final class WebDriverExecutor {
    let driver: PageDriver
    /// Which window the page is in ("Safari's", "the app's own"): said in the session's capabilities.
    let windowKind: String
    /// Closes the window the session opened, when the session ends.
    private let closeWindow: () -> Void
    private var implicitWait: TimeInterval = 0
    private var scriptTimeout: TimeInterval = 30
    private let log = Logger(subsystem: "PrivacyBrowser", category: "WebDriver")

    init(driver: PageDriver, windowKind: String, closeWindow: @escaping () -> Void) {
        self.driver = driver
        self.windowKind = windowKind
        self.closeWindow = closeWindow
        driver.timeout = 300
    }

    func close() {
        driver.finish()
        closeWindow()
    }

    /// The command done; its value as JSON text.
    func perform(_ call: WebDriverCall) async throws -> String {
        let body = ((try? JSONSerialization.jsonObject(with: Data(call.body.utf8))) as? [String: Any]) ?? [:]
        do {
            return try await perform(call.command, element: call.element, name: call.name, body: body)
        } catch let error as WebDriverError {
            throw error
        } catch let failure as PageDriver.Failure {
            throw Self.error(for: failure)
        } catch {
            throw WebDriverError.unknown(String(describing: error))
        }
    }

    private func perform(_ command: String, element: String?, name: String?, body: [String: Any]) async throws -> String {
        switch command {
        case "open":
            return Self.json(["window": windowKind])
        case "navigate":
            guard let text = body["url"] as? String, let url = WebDriverRoute.navigableURL(text) else {
                throw WebDriverError.invalidArgument("url must be an http or https address, or about:blank")
            }
            try await driver.goto(url)
            return "null"
        case "currentURL": return Self.json(driver.url?.absoluteString ?? "about:blank")
        case "title": return Self.json(driver.title ?? "")
        case "back": try await driver.back(); return "null"
        case "forward": try await driver.forward(); return "null"
        case "refresh": try await driver.reload(); return "null"
        case "pageSource": return try await script(WebDriverScripts.source)

        case "findElement", "findElements":
            guard let using = body["using"] as? String, let value = body["value"] as? String else {
                throw WebDriverError.invalidArgument("using and value are needed")
            }
            let deadline = Date().addingTimeInterval(implicitWait)
            while true {
                let found = try await script(WebDriverScripts.find, ["using": using, "value": value, "root_": element ?? ""])
                if found != "[]" || Date() >= deadline {
                    if command == "findElements" { return found }
                    guard let first = (try? JSONSerialization.jsonObject(with: Data(found.utf8)) as? [Any])?.first else {
                        throw WebDriverError.noSuchElement("nothing in the page matches \(using) \"\(value)\"")
                    }
                    return Self.json(first)
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        case "activeElement": return try await script(WebDriverScripts.active)

        case "click":
            let target = try await script(WebDriverScripts.clickTarget, ["id": try need(element)])
            guard let point = (try? JSONSerialization.jsonObject(with: Data(target.utf8))) as? [String: Any] else {
                throw WebDriverError.unknown("the element gave no place to click")
            }
            if point["option"] as? Bool == true { return "null" }
            guard let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue else {
                throw WebDriverError.unknown("the element gave no place to click")
            }
            try await driver.click(at: CGPoint(x: x, y: y))
            return "null"
        case "clear":
            return try await script(WebDriverScripts.clear, ["id": try need(element)])
        case "sendKeys":
            guard let text = body["text"] as? String else { throw WebDriverError.invalidArgument("text is needed") }
            // Keys may come before any click: the web view is made its window's first responder, as
            // a click makes it (a new window may have something else there, its address field).
            // The page then has focus when the element takes it, and its keys come to a focused
            // page, as a person's do.
            await driver.input.takeFirstResponder()
            _ = try await script(WebDriverScripts.focus, ["id": try need(element)])
            for stroke in try WebDriverKeys.strokes(text) { try await perform(stroke) }
            return "null"

        case "elementText": return try await read("text", element)
        case "elementTagName": return try await read("tagName", element)
        case "elementRect": return try await read("rect", element)
        case "elementEnabled": return try await read("enabled", element)
        case "elementSelected": return try await read("selected", element)
        case "elementDisplayed": return try await read("displayed", element)
        case "elementAttribute": return try await read("attribute", element, name)
        case "elementProperty": return try await read("property", element, name)
        case "elementCSS": return try await read("css", element, name)

        case "executeSync", "executeAsync":
            guard let source = body["script"] as? String else { throw WebDriverError.invalidArgument("script is needed") }
            let arguments = (try? JSONSerialization.data(withJSONObject: body["args"] as? [Any] ?? [])) ?? Data("[]".utf8)
            let code = WebDriverScripts.execute(source, async: command == "executeAsync")
            return try await withTimeout(scriptTimeout) {
                try await self.script(code, ["args": String(decoding: arguments, as: UTF8.self)])
            }

        case "getCookies": return Self.json(try await cookies().map { Self.describe($0) })
        case "getCookie":
            guard let cookie = try await cookies().first(where: { $0.name == name }) else {
                throw WebDriverError.noSuchCookie("the page has no cookie named \(name ?? "")")
            }
            return Self.json(Self.describe(cookie))
        case "addCookie":
            guard let given = body["cookie"] as? [String: Any], let cookie = try Self.cookie(from: given, page: driver.url) else {
                throw WebDriverError.invalidArgument("cookie needs a name and a value")
            }
            await store.setCookie(cookie)
            return "null"
        case "deleteCookie":
            for cookie in try await cookies() where cookie.name == name { await store.deleteCookie(cookie) }
            return "null"
        case "deleteCookies":
            for cookie in try await cookies() { await store.deleteCookie(cookie) }
            return "null"

        case "screenshot":
            return Self.json(try await driver.screenshot().base64EncodedString())
        case "elementScreenshot":
            let rect = try await read("viewRect", element)
            guard let box = (try? JSONSerialization.jsonObject(with: Data(rect.utf8))) as? [String: Any] else {
                throw WebDriverError.unknown("the element gave no rectangle")
            }
            return Self.json(try Self.cropped(try await driver.screenshot(), to: box).base64EncodedString())

        case "getWindowRect": return Self.json(try windowRect())
        case "setWindowRect":
            let window = try needWindow()
            var frame = window.frame
            let screen = window.screen?.frame ?? NSScreen.main?.frame ?? frame
            if let width = (body["width"] as? NSNumber)?.doubleValue, let height = (body["height"] as? NSNumber)?.doubleValue {
                let top = frame.maxY
                frame.size = NSSize(width: max(width, 200), height: max(height, 200))
                frame.origin.y = top - frame.height
            }
            if let x = (body["x"] as? NSNumber)?.doubleValue, let y = (body["y"] as? NSNumber)?.doubleValue {
                frame.origin = NSPoint(x: screen.minX + x, y: screen.maxY - y - frame.height)
            }
            window.setFrame(frame, display: true)
            return Self.json(try windowRect())
        case "maximizeWindow":
            let window = try needWindow()
            if let visible = window.screen?.visibleFrame { window.setFrame(visible, display: true) }
            return Self.json(try windowRect())

        case "getTimeouts":
            return Self.json(["script": Int(scriptTimeout * 1000), "pageLoad": Int(driver.timeout * 1000), "implicit": Int(implicitWait * 1000)])
        case "setTimeouts":
            // All three read before any is set: one out of the protocol's range sets none.
            let implicit = try WebDriverRoute.timeoutSeconds(body, "implicit")
            let pageLoad = try WebDriverRoute.timeoutSeconds(body, "pageLoad")
            let script = try WebDriverRoute.timeoutSeconds(body, "script")
            if let implicit { implicitWait = implicit }
            if let pageLoad { driver.timeout = max(1, pageLoad) }
            if let script { scriptTimeout = max(1, script) }
            return "null"

        case "windowHandle": return Self.json(Self.windowHandle)
        case "windowHandles": return Self.json([Self.windowHandle])
        case "switchWindow":
            guard body["handle"] as? String == Self.windowHandle else { throw WebDriverError.noSuchWindow("a session has one window") }
            return "null"
        case "performActions":
            // What cannot be made as a person's — a drag, another button, a click with a modifier
            // held — is refused here, before any of the request is done (`WebDriverActions`).
            try await perform(try WebDriverActions.steps(body))
            return "null"
        // No request ends with a button or a key held (`WebDriverActions`): nothing is left to let go.
        case "releaseActions": return "null"
        case "alert": throw WebDriverError.noSuchAlert("the driver does not see the page's dialogs")
        case "frame": throw WebDriverError.unsupported("frames are not part of this driver: commands act on the page itself")
        case "newWindow", "windowState", "print": throw WebDriverError.unsupported("\(command) is not part of this driver")
        default: throw WebDriverError.unknownCommand(command)
        }
    }

    static let windowHandle = "lumen-window"

    // MARK: Keys and actions

    /// A stroke given to the page: a key or a combination pressed, or characters typed.
    private func perform(_ stroke: WebDriverKeys.Stroke) async throws {
        switch stroke {
        case let .press(combination): try await driver.press(combination)
        case let .type(run):
            do {
                try await driver.type(nil, run)
            } catch PageDriver.Failure.untypeable {
                // No key of this keyboard's layout makes it (another alphabet, an emoji):
                // put in as text is, at the caret.
                _ = try await script(WebDriverScripts.insertText, ["text": run])
            }
        }
    }

    /// The steps of "perform actions", one after another, with the page's driver: the pointer
    /// travels as a hand moves it, the button is held as long as a finger holds it however fast
    /// the client's actions come, keys are pressed as send keys presses them. A button this
    /// pressed is let go if a later step fails.
    private func perform(_ steps: [WebDriverActions.Step]) async throws {
        var pressedAt: Date?
        do {
            for step in steps {
                switch step {
                case let .move(origin, x, y):
                    try await driver.movePointer(to: try await point(origin, x, y))
                case .press:
                    guard driver.input.pointerViewportPoint() != nil else {
                        throw WebDriverError.invalidArgument("the pointer is nowhere yet: move it onto an element before a press")
                    }
                    driver.input.holdFocus()
                    await driver.input.takeFirstResponder()
                    driver.input.press()
                    pressedAt = Date()
                case .release:
                    let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 1
                    if held < 0.05 { try await driver.pause((0.05 - held)...(0.1 - held)) }
                    driver.input.release()
                    pressedAt = nil
                    // The next press of a double click comes a moment later, as a finger's does.
                    try await driver.pause(0.06...0.12)
                case let .key(stroke):
                    try await perform(stroke)
                case let .scroll(origin, x, y, deltaY):
                    // From the viewport's corner with no offset (Selenium's scroll_by_amount): the
                    // wheel where the pointer is, not the pointer sent to the corner.
                    if origin != .viewport || x != 0 || y != 0 { try await driver.movePointer(to: try await point(origin, x, y)) }
                    try await driver.scroll(by: min(max(deltaY, -100_000), 100_000))
                case let .pause(seconds):
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        } catch {
            if pressedAt != nil { driver.input.release() }
            throw error
        }
    }

    /// The viewport point an action names: `x`, `y` from the viewport's corner, from where the
    /// pointer is, or from the middle of an element (brought into view). One outside the viewport
    /// is the protocol's "move target out of bounds".
    private func point(_ origin: WebDriverActions.Origin, _ x: Double, _ y: Double) async throws -> CGPoint {
        var element = ""
        if case let .element(id) = origin { element = id }
        let place = try await script(WebDriverScripts.pointerOrigin, ["id": element])
        guard let answer = (try? JSONSerialization.jsonObject(with: Data(place.utf8))) as? [String: Any],
              let fromX = (answer["x"] as? NSNumber)?.doubleValue, let fromY = (answer["y"] as? NSNumber)?.doubleValue,
              let width = (answer["width"] as? NSNumber)?.doubleValue, let height = (answer["height"] as? NSNumber)?.doubleValue else {
            throw WebDriverError.unknown("the page gave no place to move to")
        }
        var point = CGPoint(x: fromX + x, y: fromY + y)
        if origin == .pointer {
            guard let pointer = driver.input.pointerViewportPoint() else {
                throw WebDriverError.invalidArgument("the pointer is nowhere yet: its first move is to an element, or from the viewport")
            }
            point = CGPoint(x: pointer.x + x, y: pointer.y + y)
        }
        guard point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else {
            // Not through Int: a client's number can be past what one holds.
            throw WebDriverError.moveOutOfBounds(String(format: "the move ends at %.0f, %.0f, outside the %.0f × %.0f of the page in view",
                                                        point.x, point.y, width, height))
        }
        return point
    }

    // MARK: The page

    /// Runs a body of `WebDriverScripts` in the driver's world; its value as JSON text.
    private func script(_ body: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let result = try await driver.evaluate(WebDriverScripts.prelude + "\n" + body, arguments, world: .isolated)
        return result as? String ?? "null"
    }

    private func read(_ what: String, _ element: String?, _ name: String? = nil) async throws -> String {
        try await script(WebDriverScripts.read, ["id": try need(element), "what": what, "name": name ?? ""])
    }

    private func need(_ element: String?) throws -> String {
        guard let element, !element.isEmpty else { throw WebDriverError.invalidArgument("the command is about an element") }
        return element
    }

    private func needWindow() throws -> NSWindow {
        guard let window = driver.webView.window else { throw WebDriverError.noSuchWindow("the session's window is closed") }
        return window
    }

    /// The window as the protocol says a rectangle: from the screen's top left.
    private func windowRect() throws -> [String: Any] {
        let window = try needWindow()
        let screen = window.screen?.frame ?? NSScreen.main?.frame ?? window.frame
        return ["x": Int(window.frame.minX - screen.minX), "y": Int(screen.maxY - window.frame.maxY),
                "width": Int(window.frame.width), "height": Int(window.frame.height)]
    }

    /// `body`'s value, or the protocol's "script timeout" when it has none after `seconds`.
    private func withTimeout(_ seconds: TimeInterval, _ body: @escaping () async throws -> String) async throws -> String {
        // Not a task group: a group returns only when every child has ended, and a script that
        // never settles never ends (the page's answer is a continuation, which cancelling does
        // not resume) — the timeout would then never be said. Whichever of the two comes first
        // answers; the other finds the answer given. Both on the main actor, one after the other.
        final class Race { var waiting: CheckedContinuation<String, Error>? }
        let race = Race()
        // No longer than the clock counts: a client's "no timeout" is the protocol's largest number.
        let nanoseconds = UInt64(min(seconds, 1_000_000_000) * 1_000_000_000)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            race.waiting = continuation
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: nanoseconds)
                race.waiting?.resume(throwing: WebDriverError.scriptTimeout("the script did not finish in \(Int(seconds)) s"))
                race.waiting = nil
            }
            Task { @MainActor in
                let result: Result<String, Error>
                do { result = .success(try await body()) } catch { result = .failure(error) }
                race.waiting?.resume(with: result)
                race.waiting = nil
                timer.cancel()
            }
        }
    }

    /// A page's failure, in the protocol's words: a script of `WebDriverScripts` names its own
    /// code (`PBWD:<code>:<message>`); anything else a client's script threw is a JavaScript error.
    static func error(for failure: PageDriver.Failure) -> WebDriverError {
        switch failure {
        case let .script(text):
            if let marker = text.range(of: "PBWD:") {
                let parts = text[marker.upperBound...].split(separator: ":", maxSplits: 1).map(String.init)
                let message = parts.count > 1 ? parts[1] : ""
                let statuses = ["invalid argument": 400, "invalid selector": 400, "element not interactable": 400,
                                "element click intercepted": 400, "invalid element state": 400, "no such element": 404,
                                "stale element reference": 404, "unknown command": 404, "unsupported operation": 500]
                if let code = parts.first, let status = statuses[code] { return WebDriverError(code, status, message) }
            }
            return .javascript(text)
        case .timeout: return .timeout(String(describing: failure))
        case .notFound: return .noSuchElement(String(describing: failure))
        case .notVisible: return .notInteractable(String(describing: failure))
        case .covered: return .clickIntercepted(String(describing: failure))
        case .noWindow: return .noSuchWindow("the session's window is closed")
        case .untypeable, .navigation, .refused: return .unknown(String(describing: failure))
        }
    }

    // MARK: Cookies

    private var store: WKHTTPCookieStore { driver.webView.configuration.websiteDataStore.httpCookieStore }

    /// The cookies the page in the window would send: of its host and path, as the protocol means.
    private func cookies() async throws -> [HTTPCookie] {
        guard let url = driver.url, let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return await store.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let hostMatches = host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare))
            let pathMatches = path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            return hostMatches && pathMatches && (!cookie.isSecure || url.scheme == "https")
        }
    }

    private static func describe(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
                                  "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly]
        if let expires = cookie.expiresDate { out["expiry"] = Int(expires.timeIntervalSince1970) }
        if let sameSite = cookie.sameSitePolicy?.rawValue { out["sameSite"] = sameSite.prefix(1).uppercased() + sameSite.dropFirst() }
        return out
    }

    private static func cookie(from given: [String: Any], page: URL?) throws -> HTTPCookie? {
        guard let name = given["name"] as? String, !name.isEmpty, let value = given["value"] as? String else { return nil }
        guard let domain = (given["domain"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? page?.host else {
            throw WebDriverError.invalidArgument("a cookie needs a domain, or a page to take it from")
        }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: given["path"] as? String ?? "/"]
        if given["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if given["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expiry = (given["expiry"] as? NSNumber)?.doubleValue { properties[.expires] = Date(timeIntervalSince1970: expiry) }
        if let sameSite = given["sameSite"] as? String, sameSite.lowercased() != "none" {
            properties[.sameSitePolicy] = sameSite.lowercased()
        }
        return HTTPCookie(properties: properties)
    }

    // MARK: Pictures and JSON

    /// The part of a viewport's PNG an element's rectangle covers.
    private static func cropped(_ png: Data, to box: [String: Any]) throws -> Data {
        func number(_ key: String) -> Double { (box[key] as? NSNumber)?.doubleValue ?? 0 }
        guard let bitmap = NSBitmapImageRep(data: png), let image = bitmap.cgImage, number("viewWidth") > 0 else {
            throw WebDriverError.unknown("no picture of the page")
        }
        let scale = Double(image.width) / number("viewWidth")
        let wanted = CGRect(x: number("x") * scale, y: number("y") * scale, width: number("width") * scale, height: number("height") * scale)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !wanted.isEmpty, let part = image.cropping(to: wanted),
              let data = NSBitmapImageRep(cgImage: part).representation(using: .png, properties: [:]) else {
            throw WebDriverError.notInteractable("the element is not in view")
        }
        return data
    }

    /// `value` as JSON text; a bare string or number too.
    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
