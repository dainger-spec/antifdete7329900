import Foundation

/// A scenario (docs/AUTOMATION.md): JavaScript that acts on a profile's pages through the core
/// commands (`page.goto`, `page.click`…), written in the app's editor.
public struct Scenario: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The folder it is listed in; nil: none. Written by a later version than the first
    /// scenarios: an older file has none, and an older version leaves it out.
    public var folder: String?
    /// A line about it, in the person's words.
    public var note: String?
    /// The template it was made from (`ScenarioTemplate.id`).
    public var templateID: String?

    public init(id: UUID = UUID(), name: String, source: String, createdAt: Date = Date(), updatedAt: Date? = nil,
                folder: String? = nil, note: String? = nil, templateID: String? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.folder = folder
        self.note = note
        self.templateID = templateID
    }
}

/// The vault's scenarios — `scenarios.bin` at the vault's root, sealed under the vault's own key for
/// it. This Mac's: not synced in this version (a scenario may name this Mac's files and profiles).
public struct ScenarioLibrary: Codable, Equatable, Sendable {
    /// The newest format of `scenarios.bin` this version reads and writes (docs/UPDATES.md §4).
    public static let supportedFormat = 1

    public var format: Int
    public var scenarios: [Scenario]

    public init(format: Int = 1, scenarios: [Scenario] = []) {
        self.format = format
        self.scenarios = scenarios
    }

    /// By name, as a person looks for one (case and accents aside), then by when it was made.
    public var sorted: [Scenario] {
        scenarios.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
        }
    }

    public func scenario(_ id: UUID) -> Scenario? { scenarios.first { $0.id == id } }

    /// The folders in use, by name.
    public var folders: [String] {
        Array(Set(scenarios.compactMap { $0.folder?.isEmpty == false ? $0.folder : nil })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A copy of `scenario` under a free name ("name 2"), made now.
    public func copy(of scenario: Scenario, at date: Date = Date()) -> Scenario {
        Scenario(name: freeName(scenario.name), source: scenario.source, createdAt: date, folder: scenario.folder, note: scenario.note, templateID: scenario.templateID)
    }

    /// Adds `scenario`, or replaces the one with its id (its time of change moved on).
    public mutating func put(_ scenario: Scenario, at date: Date = Date()) {
        var changed = scenario
        changed.updatedAt = date
        if let index = scenarios.firstIndex(where: { $0.id == scenario.id }) {
            scenarios[index] = changed
        } else {
            scenarios.append(changed)
        }
    }

    public mutating func remove(_ id: UUID) {
        scenarios.removeAll { $0.id == id }
    }

    /// A name not yet taken: `base`, else "base 2", "base 3"…
    public func freeName(_ base: String) -> String {
        let taken = Set(scenarios.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

extension ScenarioLibrary {
    /// `scenarios.bin`, sealed under the vault's own key for it. A copy that does not open is never
    /// written over: a save moves it aside first (`EncryptedDocumentFile.makeWay`).
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<ScenarioLibrary> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("scenarios.bin"), key: try vault.scenariosKey,
                              aad: "scenarios:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
    }

    /// The vault's scenarios; none before the first. Throws for a copy that does not open, and for a
    /// newer version's (`CoreError.newerFormat`).
    public static func load(from vault: UnlockedVault) throws -> ScenarioLibrary {
        try file(for: vault).load() ?? ScenarioLibrary()
    }

    /// Writes them — never over a newer version's copy, nor over one that does not open (moved aside
    /// as `scenarios.bin.unreadable` first).
    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}

/// A scenario's waits as the clock takes them. A script's number can be anything JavaScript has —
/// `Infinity`, `NaN`, `1e300` — and the system's sleep takes whole nanoseconds below 2^64 (some
/// 584 years): a number past that stopped the profile's process. A script that waits longer than
/// `longest` (or for ever) waits until it is stopped, which is what `sleep(Infinity)` means.
public enum ScenarioWait {
    /// A year: no run waits longer on purpose.
    public static let longest: TimeInterval = 365 * 24 * 3600

    /// What `sleep(ms)` and `page.pause(ms)` wait, in nanoseconds: none for zero, a negative number
    /// or NaN; nil — until the run is stopped — for `Infinity` or anything longer than `longest`.
    public static func nanoseconds(milliseconds: Double) -> UInt64? {
        guard !milliseconds.isNaN, milliseconds > 0 else { return 0 }
        let seconds = milliseconds / 1000
        guard seconds <= longest else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }

    /// The seconds a key's pause is drawn from for `page.type(…, {delay: ms})`: the delay asked,
    /// give or take 40 %, at most `longest` (`Infinity` too: in effect until Stop); a person's
    /// 0.06…0.18 s when none, or NaN, is asked.
    public static func keyDelay(milliseconds: Double?) -> ClosedRange<Double> {
        guard let milliseconds, !milliseconds.isNaN else { return 0.06...0.18 }
        let seconds = min(max(0, milliseconds / 1000), longest)
        return (seconds * 0.6)...max(0.01, seconds * 1.4)
    }
}

/// What `page.waitForURL(…)` waits for (docs/AUTOMATION.md): an address written out, with `*`
/// for any run of characters within one part of a path and `**` for any run at all
/// (`**/account`, `https://shop.example/orders/*`), or a regular expression (`/\/order\/\d+/`).
/// The whole address must match a written one; a regular expression is looked for in it.
public enum ScenarioURLPattern: Equatable, Sendable {
    case glob(String)
    case regex(String, caseInsensitive: Bool)

    /// What the script gave: text, or `{regex, flags}` for a regular expression of its own.
    public init?(_ value: Any?) {
        if let text = value as? String, !text.isEmpty {
            self = .glob(text)
        } else if let object = value as? [String: Any], let source = object["regex"] as? String, !source.isEmpty {
            self = .regex(source, caseInsensitive: (object["flags"] as? String ?? "").contains("i"))
        } else {
            return nil
        }
    }

    /// As the run's log names it.
    public var shown: String {
        switch self {
        case .glob(let text): return text
        case .regex(let source, _): return "/\(source)/"
        }
    }

    /// The regular expression a written address is: every character itself, but `**` any run and
    /// `*` a run without `/`.
    static func expression(forGlob glob: String) -> String {
        var out = "^"
        var rest = Substring(glob)
        while let character = rest.first {
            if rest.hasPrefix("**") {
                out += ".*"
                rest = rest.dropFirst(2)
            } else if character == "*" {
                out += "[^/]*"
                rest = rest.dropFirst()
            } else {
                out += NSRegularExpression.escapedPattern(for: String(character))
                rest = rest.dropFirst()
            }
        }
        return out + "$"
    }

    /// Whether the page's address `url` is one this means. A written address is the same with and
    /// without the `/` at its end (`https://shop.example` is where `https://shop.example/` is).
    /// A regular expression that cannot be read matches nothing.
    public func matches(_ url: String) -> Bool {
        let pattern: String
        var options: NSRegularExpression.Options = []
        switch self {
        case .glob(let text):
            pattern = Self.expression(forGlob: text)
            options = [.dotMatchesLineSeparators]
        case .regex(let source, let caseInsensitive):
            pattern = source
            if caseInsensitive { options = [.caseInsensitive] }
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        func found(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
        if found(url) { return true }
        guard case .glob = self else { return false }
        return url.hasSuffix("/") ? found(String(url.dropLast())) : found(url + "/")
    }

    /// Whether this can be read at all: a regular expression's text may not be one.
    public var isReadable: Bool {
        switch self {
        case .glob: return true
        case .regex(let source, _): return (try? NSRegularExpression(pattern: source)) != nil
        }
    }
}
