import Foundation

/// Why a scenario's run failed, read back from the reason the runner gives (`PageDriver.Failure`,
/// `ScenarioRunner`) so that the app can say it in the interface's language.
///
/// The reason itself stays as it is, in English: it is what a script's own `catch` sees in
/// `e.message`, what the automation API answers and what the run's log keeps. Only what the run's
/// table, the editor's check and the steps show is said in words of the interface — a Russian
/// interface showed "Ошибка — no element matches #login (line 3)". A reason this does not know (a
/// script's own `throw`, JavaScript's own errors) is `other`, shown as it is.
public enum ScenarioFailureReason: Equatable, Sendable {
    /// What a run waited for and did not get in time.
    public enum Wait: Equatable, Sendable {
        /// An element to be `visible`, `hidden`, `attached` or `detached`.
        case element(selector: String, state: String)
        /// The page to finish loading.
        case load
        /// The address to match a pattern.
        case address(String)
        /// A page to open (`page.goto`).
        case opening(String)
        case back
        case forward
        case reload
        /// The profile's process to answer.
        case profile
        case other(String)
    }

    case noWindow
    case timedOut(Wait)
    case ambiguous(selector: String)
    case notFound(selector: String)
    case notVisible(selector: String)
    /// Something else is on top of the element where the pointer would press; nil: the page was
    /// still moving under the pointer.
    case covered(selector: String, by: String?)
    case disabled(selector: String)
    case typingFocus(selector: String)
    case typingChanged(selector: String)
    case readOnly(selector: String)
    case untypeable(String)
    case nothingToGoBackTo
    case nothingToGoForwardTo
    /// `page.goto` was given an address that is not http or https.
    case notWebAddress
    case navigation(String)
    case script(String)
    case couldNotStart
    /// So many page commands were called without `await`.
    case notAwaited(Int)
    case other(String)

    /// The reason as the runner gives it, and the scenario's line it names ("… (line 12)").
    public static func parse(_ reason: String) -> (reason: ScenarioFailureReason, line: Int?) {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        // JavaScript's own error as text: "Error: no element matches #login (line 3)".
        if text.hasPrefix("Error: ") { text.removeFirst("Error: ".count) }
        var line: Int?
        if text.hasSuffix(")"), let open = text.range(of: " (line ", options: .backwards),
           let number = Int(text[open.upperBound..<text.index(before: text.endIndex)]) {
            line = number
            text = String(text[..<open.lowerBound])
        }
        return (kind(of: text), line)
    }

    private static func kind(of text: String) -> ScenarioFailureReason {
        switch text {
        case "the page has no window", "no window to run in": return .noWindow
        case "the profile could not start the run": return .couldNotStart
        default: break
        }
        if let what = text.dropping(prefix: "timed out: ") { return .timedOut(wait(what)) }
        if let selector = text.dropping(prefix: "multiple controls match ") { return .ambiguous(selector: selector) }
        if let selector = text.dropping(prefix: "typing target lost focus: ") { return .typingFocus(selector: selector) }
        if let selector = text.dropping(prefix: "typing target changed: ") { return .typingChanged(selector: selector) }
        if let selector = text.dropping(suffix: " is read-only") { return .readOnly(selector: selector) }
        if let selector = text.dropping(prefix: "no element matches "), !selector.isEmpty { return .notFound(selector: selector) }
        if let message = text.dropping(prefix: "navigation failed: ") {
            switch message {
            case "nothing to go back to": return .nothingToGoBackTo
            case "nothing to go forward to": return .nothingToGoForwardTo
            case "goto takes an http or https address": return .notWebAddress
            default: return .navigation(message)
            }
        }
        if let message = text.dropping(prefix: "script error: ") { return .script(message) }
        if let character = text.dropping(prefix: "the keyboard layout has no key for \""), character.hasSuffix("\"") {
            return .untypeable(String(character.dropLast()))
        }
        if let range = text.range(of: " is covered by "), range.lowerBound > text.startIndex {
            let selector = String(text[..<range.lowerBound])
            let by = String(text[range.upperBound...])
            return .covered(selector: selector, by: by == "the page moving under the pointer" ? nil : by)
        }
        if let selector = text.dropping(suffix: " is not visible"), !selector.isEmpty { return .notVisible(selector: selector) }
        if !text.hasPrefix("the option "), let selector = text.dropping(suffix: " is disabled"), !selector.isEmpty {
            return .disabled(selector: selector)
        }
        if let count = text.dropping(suffix: " page commands are waiting to run: write await before each one, as in await page.click('#login')")
            .flatMap({ Int($0) }) {
            return .notAwaited(count)
        }
        return .other(text)
    }

    private static func wait(_ what: String) -> Wait {
        switch what {
        case "load state load", "load state domcontentloaded": return .load
        case "going back": return .back
        case "going forward": return .forward
        case "reloading": return .reload
        case "the profile's process did not answer": return .profile
        default: break
        }
        if let pattern = what.dropping(prefix: "the address to match ") { return .address(pattern) }
        if let address = what.dropping(prefix: "going to ") { return .opening(address) }
        for state in ["visible", "hidden", "attached", "detached"] {
            if let selector = what.dropping(suffix: " to be \(state)"), !selector.isEmpty { return .element(selector: selector, state: state) }
        }
        return .other(what)
    }
}

private extension String {
    func dropping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    func dropping(suffix: String) -> String? {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil
    }
}
