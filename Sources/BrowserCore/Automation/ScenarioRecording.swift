import Foundation

/// One thing a person did in a profile's window while a scenario was being recorded, as the page
/// reported it (docs/AUTOMATION.md, "Recording").
public struct RecordedStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// An address opened: typed into the window's address field, or the page the recording began on.
        case goto
        /// A page loaded because of the step before (a link clicked, a form sent).
        case load
        case click
        /// Text a field ended up with after typing.
        case fill
        /// A key that does something by itself: Enter in a field.
        case press
        /// Something that was done and cannot be replayed, said as a comment.
        case note
    }

    public var kind: Kind
    public var selector: String?
    /// The address (`goto`), the text (`fill`), the key (`press`), the words (`note`).
    public var value: String?
    /// A password's field: its text is never part of a step.
    public var secret: Bool?
    /// The field held text before the typing: a replay selects it all first, so that what is
    /// typed takes its place as it did.
    public var replaces: Bool?

    public init(_ kind: Kind, selector: String? = nil, value: String? = nil, secret: Bool? = nil, replaces: Bool? = nil) {
        self.kind = kind
        self.selector = selector
        self.value = value
        self.secret = secret
        self.replaces = replaces
    }
}

/// A recording as it goes: which page loads are steps of their own, and each step as a line of a
/// scenario (`ScenarioRunner`'s commands).
public struct ScenarioRecording: Equatable, Sendable {
    /// A page that loads this soon after a click or Enter loaded because of it.
    public static let followsWithin: TimeInterval = 5

    public private(set) var steps: [RecordedStep] = []
    private var lastActionAt: Date?
    private var lastAddress: String?

    public init() {}

    /// What a person did on the page. Returns the steps to add (none for one that says nothing new).
    public mutating func acted(_ step: RecordedStep, at date: Date = Date()) -> [RecordedStep] {
        var step = step
        if step.kind == .fill {
            if step.secret == true { step.value = nil }
            // The same field typed into again before anything else: its last text is what counts.
            if let last = steps.last, last.kind == .fill, last.selector == step.selector {
                // What it held "before" was this recording's own typing, unless the first said otherwise.
                step.replaces = last.replaces
                steps[steps.count - 1] = step
                return [step]
            }
        }
        if step.kind == .click || step.kind == .press { lastActionAt = date }
        steps.append(step)
        return [step]
    }

    /// The window's page loaded `address`. The first page, and one opened by its address, is a
    /// `goto`; one that follows a click or Enter is waited for (`load`), once.
    public mutating func loaded(_ address: String, at date: Date = Date()) -> [RecordedStep] {
        guard address.lowercased().hasPrefix("http://") || address.lowercased().hasPrefix("https://") else { return [] }
        defer { lastAddress = address }
        let follows = lastActionAt.map { date.timeIntervalSince($0) <= Self.followsWithin } ?? false
        if !steps.isEmpty, follows {
            // A redirect after the same click is the same load.
            guard steps.last?.kind != .load else { return [] }
            let step = RecordedStep(.load)
            steps.append(step)
            return [step]
        }
        guard address != lastAddress else { return [] }
        let step = RecordedStep(.goto, value: address)
        steps.append(step)
        return [step]
    }

    /// The step as a line of a scenario. `passwordNote`: the comment a password's line carries, in
    /// the interface's language.
    public static func line(for step: RecordedStep, passwordNote: String) -> String {
        let selector = quoted(step.selector ?? "")
        switch step.kind {
        case .goto: return "await page.goto(\(quoted(step.value ?? "")));"
        case .load: return "await page.waitForLoadState();"
        case .click: return "await page.click(\(selector));"
        case .fill:
            let select = step.replaces == true ? "await page.click(\(selector)); await page.press('Meta+a'); " : ""
            if step.secret == true { return select + "await page.type(\(selector), params.password || ''); // \(oneLine(passwordNote))" }
            return select + "await page.type(\(selector), \(quoted(step.value ?? "")));"
        case .press: return "await page.press(\(quoted(step.value ?? "Enter")));"
        case .note: return "// \(oneLine(step.value ?? ""))"
        }
    }

    /// `text` as a JavaScript string in single quotes.
    public static func quoted(_ text: String) -> String {
        var out = "'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 { out += String(format: "\\x%02x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "'"
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
