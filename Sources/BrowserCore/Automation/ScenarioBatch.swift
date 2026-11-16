import Foundation

/// A scenario run on many profiles (docs/AUTOMATION.md, "On many profiles"): which wait, which
/// are at work — so many at once — and how each ended. Pure bookkeeping: the app starts and
/// watches the runs (`ScenarioBatchCoordinator`) and tells this what happened.
public struct ScenarioBatch: Codable, Equatable, Sendable, Identifiable {
    public enum State: Codable, Equatable, Sendable {
        case waiting
        /// Its profile is starting, or the run has begun.
        case running(since: Date)
        case finished
        /// `reason`: the error's first line; `line`: the scenario's line it names, if any.
        case failed(reason: String, line: Int?)
        case stopped
        /// Not run: the profile has no text for these values, or is gone, or did not start.
        case skipped(reason: String)

        public var hasEnded: Bool {
            switch self {
            case .waiting, .running: return false
            default: return true
            }
        }
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var profileID: UUID
        /// The profile's name when the run was made: a profile deleted later still has a row.
        public var name: String
        public var state: State
        public var endedAt: Date?
        /// How long its run took, in seconds.
        public var duration: TimeInterval?
        /// What the scenario returned, as JSON text.
        public var result: String?
        /// The last lines of its log, kept for one that failed.
        public var log: [String]?
        /// The run started the profile, and stops it again when the scenario has ended.
        public var startedProfile: Bool?
        public var id: UUID { profileID }

        public init(profileID: UUID, name: String, state: State = .waiting) {
            self.profileID = profileID
            self.name = name
            self.state = state
        }
    }

    public enum Origin: String, Codable, Sendable { case manual, schedule, check }

    public static let limits = [1, 3, 5, 10]
    public static let defaultLimit = 3
    /// The log lines kept with a profile whose run failed.
    public static let keptLogLines = 300

    public var id: UUID
    public var scenarioID: UUID
    public var scenarioName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var origin: Origin
    /// How many profiles work at a time.
    public var limit: Int
    /// The pause before the next profile starts, in seconds: a random one within it.
    public var pause: ClosedRange<Double>?
    public var stopsProfiles: Bool
    public var entries: [Entry]
    /// Stop was asked: nothing more is started.
    public var isStopping: Bool

    public init(id: UUID = UUID(), scenarioID: UUID, scenarioName: String, entries: [Entry], startedAt: Date = Date(), origin: Origin = .manual,
                limit: Int = ScenarioBatch.defaultLimit, pause: ClosedRange<Double>? = nil, stopsProfiles: Bool = true) {
        self.id = id
        self.scenarioID = scenarioID
        self.scenarioName = scenarioName
        self.entries = entries
        self.startedAt = startedAt
        self.origin = origin
        self.limit = min(max(limit, 1), 10)
        self.pause = pause
        self.stopsProfiles = stopsProfiles
        isStopping = false
    }

    public var isRunning: Bool { endedAt == nil }
    public func count(_ matches: (State) -> Bool) -> Int { entries.filter { matches($0.state) }.count }
    public var finished: Int { count { $0 == .finished } }
    public var failed: Int { count { if case .failed = $0 { return true } else { return false } } }
    public var skipped: Int { count { if case .skipped = $0 { return true } else { return false } } }
    public var stopped: Int { count { $0 == .stopped } }
    public var working: Int { count { if case .running = $0 { return true } else { return false } } }
    public var waiting: Int { count { $0 == .waiting } }
    public var ended: Int { count(\.hasEnded) }
    /// The profiles whose run failed or was stopped: what "run the failed again" takes.
    public var unsuccessful: [UUID] {
        entries.filter { if case .failed = $0.state { return true } else { return $0.state == .stopped } }.map(\.profileID)
    }

    /// The profiles to start now: the first of those waiting, as many as the limit leaves room
    /// for; none once Stop was asked.
    public func next() -> [UUID] {
        guard !isStopping, endedAt == nil else { return [] }
        let room = max(0, limit - working)
        return entries.filter { $0.state == .waiting }.prefix(room).map(\.profileID)
    }

    public mutating func began(_ profile: UUID, at date: Date = Date(), startedProfile: Bool = false) {
        guard let index = entries.firstIndex(where: { $0.profileID == profile }), entries[index].state == .waiting else { return }
        entries[index].state = .running(since: date)
        entries[index].startedProfile = startedProfile ? true : nil
    }

    /// The run on `profile` has ended as `state` (an ended one). The whole run ends with its last.
    public mutating func ended(_ profile: UUID, _ state: State, at date: Date = Date(), result: String? = nil, log: [String]? = nil) {
        guard state.hasEnded, let index = entries.firstIndex(where: { $0.profileID == profile }), !entries[index].state.hasEnded else { return }
        if case .running(let since) = entries[index].state { entries[index].duration = max(0, date.timeIntervalSince(since)) }
        entries[index].state = state
        entries[index].endedAt = date
        entries[index].result = result.map { String($0.prefix(4000)) }
        if case .failed = state { entries[index].log = log.map { Array($0.suffix(Self.keptLogLines)) } }
        closeIfDone(at: date)
    }

    /// Stop: those waiting are stopped at once; those at work end when the app has stopped them.
    public mutating func stop(at date: Date = Date()) {
        guard endedAt == nil else { return }
        isStopping = true
        for index in entries.indices where entries[index].state == .waiting {
            entries[index].state = .stopped
            entries[index].endedAt = date
        }
        closeIfDone(at: date)
    }

    private mutating func closeIfDone(at date: Date) {
        if endedAt == nil, entries.allSatisfy(\.state.hasEnded) { endedAt = date }
    }

    /// The table as text with tabs, a row a profile — to paste into a spreadsheet; `words`: a
    /// state in the interface's language.
    public func table(header: [String], words: (State) -> String) -> String {
        let clean: (String) -> String = { $0.replacingOccurrences(of: "\t", with: " ").split(whereSeparator: \.isNewline).joined(separator: " ") }
        var rows = [header.map(clean).joined(separator: "\t")]
        for entry in entries {
            let seconds = entry.duration.map { String(Int($0.rounded())) } ?? ""
            rows.append([entry.name, words(entry.state), seconds, entry.result ?? ""].map(clean).joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// The same as CSV (RFC 4180): fields in quotes, a quote doubled.
    public func csv(header: [String], words: (State) -> String) -> String {
        let field: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = [header.map(field).joined(separator: ",")]
        for entry in entries {
            let seconds = entry.duration.map { String(Int($0.rounded())) } ?? ""
            rows.append([entry.name, words(entry.state), seconds, entry.result ?? ""].map(field).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}

/// The runs kept (`scenario-runs.bin` at the vault's root, sealed under the scenarios' key): the
/// last `kept`, newest first — what ran, when, on which profiles and how each ended; a failed
/// profile's last log lines with it. This Mac's; not synced.
public struct ScenarioRunHistory: Codable, Equatable, Sendable {
    public static let supportedFormat = 1
    public static let kept = 100

    public var format: Int
    public var runs: [ScenarioBatch]

    public init(format: Int = 1, runs: [ScenarioBatch] = []) {
        self.format = format
        self.runs = runs
    }

    /// Adds the run, or puts it in place of the one with its id; the oldest past `kept` go.
    public mutating func put(_ run: ScenarioBatch) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
        }
        if runs.count > Self.kept { runs.removeLast(runs.count - Self.kept) }
    }

    /// A run the app did not see the end of (it quit meanwhile) is one that was stopped.
    public mutating func closeUnfinished(at date: Date = Date()) {
        for index in runs.indices where runs[index].endedAt == nil {
            for entry in runs[index].entries.indices where !runs[index].entries[entry].state.hasEnded {
                runs[index].entries[entry].state = .stopped
                runs[index].entries[entry].endedAt = date
            }
            runs[index].isStopping = true
            runs[index].endedAt = date
        }
    }

    public func last(of scenario: UUID) -> ScenarioBatch? { runs.first { $0.scenarioID == scenario } }
}

extension ScenarioRunHistory {
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<ScenarioRunHistory> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("scenario-runs.bin"), key: try vault.scenariosKey,
                              aad: "scenario-runs:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
    }

    public static func load(from vault: UnlockedVault) throws -> ScenarioRunHistory {
        try file(for: vault).load() ?? ScenarioRunHistory()
    }

    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}

/// A scenario as a file to hand to someone (`.lumenscenario`): its name, its note and its text —
/// never a profile's values, a schedule or a run.
public struct ScenarioFile: Codable, Equatable, Sendable {
    public static let fileExtension = "lumenscenario"
    public static let kind = "lumen.scenario"
    public static let supportedFormat = 1
    /// A file larger than this is not a scenario a person wrote.
    public static let maximumBytes = 2 * 1024 * 1024

    public var kind: String
    public var format: Int
    public var name: String
    public var note: String?
    public var source: String

    public init(_ scenario: Scenario) {
        kind = Self.kind
        format = Self.supportedFormat
        name = scenario.name
        note = scenario.note
        source = scenario.source
    }

    public enum Refusal: Error, Equatable { case tooLarge, notAScenario, newer }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The file's scenario, or why it is not taken.
    public static func read(_ data: Data) -> Result<ScenarioFile, Refusal> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        guard let file = try? JSONDecoder().decode(ScenarioFile.self, from: data), file.kind == kind else { return .failure(.notAScenario) }
        guard file.format <= supportedFormat else { return .failure(.newer) }
        return .success(file)
    }

    /// What a person is shown before a file's scenario is added: the sites it opens by name (the
    /// addresses written out in it) and the profile's values it reads.
    public var hosts: [String] { Self.hosts(in: source) }

    /// Whether the text can open an address it does not write out (`buildsAddresses(_:)`): the
    /// review says so beside the sites it names.
    public var buildsAddresses: Bool { Self.buildsAddresses(source) }

    /// The hosts of the http and https addresses written out in `text`, each once, in lower case
    /// (`HTTPS://` too; a name and password before `@` are not the host).
    public static func hosts(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://(?:[^/?#\s'"`@\\]*@)?([A-Za-z0-9.-]+)"#, options: [.caseInsensitive]) else { return [] }
        let whole = text as NSString
        var seen = Set<String>(), found: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            let host = whole.substring(with: match.range(at: 1)).lowercased()
            if host.contains("."), seen.insert(host).inserted { found.append(host) }
        }
        return found
    }

    /// Whether `source` can open an address that is not written out in it: a `goto` given anything
    /// but an address in quotes, or a text setting of its head (`ScenarioSettings`) that nothing
    /// names again, whose sites are among those it names; `goto` or `page` taken otherwise than
    /// called by name; or code that reaches past the commands — run in the page
    /// (`page.evaluate`, which can fetch any address), `eval`, `with`, `Function`, the runner's
    /// own `__…` functions. A reading of the text, not a proof: the sites it names are listed, and
    /// the review says when there may be others. Comments are not read.
    public static func buildsAddresses(_ source: String) -> Bool {
        // Without comments, and without the insides of quoted texts: what the code itself names.
        let code = ScenarioSteps.withoutComments(source, blankingTexts: true)
        let reaching = #"(?<![A-Za-z0-9_$])(?:evaluate|eval|Function|globalThis|this|Reflect|__[A-Za-z0-9_$]+)(?![A-Za-z0-9_$])"#
            + #"|(?<![A-Za-z0-9_$])with\s*\("#
            + #"|(?<![A-Za-z0-9_$])page(?![A-Za-z0-9_$])(?!\s*\.\s*[A-Za-z_$])"#
            + #"|(?<![A-Za-z0-9_$])goto(?![A-Za-z0-9_$])(?!\s*\()"#
        if ScenarioSteps.firstMatch(reaching, code) != nil { return true }
        guard let calls = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_$])goto\s*\("#) else { return true }
        let named = Set(hosts(in: source))
        // The same text with its quoted texts: what each `goto` is given (an offset is the same place in both).
        let texts = Array(ScenarioSteps.withoutComments(source).utf16)
        let settings = ScenarioSettings(source).settings
        let whole = code as NSString
        for match in calls.matches(in: code, range: NSRange(location: 0, length: whole.length)) {
            guard let given = firstArgument(texts, from: match.range.location + match.range.length) else { return true }
            let argument = given.trimmingCharacters(in: .whitespacesAndNewlines)
            let address: String
            if let text = ScenarioSettings.unquoted(argument) {
                address = text
            } else if argument.count >= 2, argument.hasPrefix("\""), argument.hasSuffix("\""),
                      !argument.dropFirst().dropLast().contains(where: { $0 == "\"" || $0 == "\\" }) {
                address = String(argument.dropFirst().dropLast())
            } else if let setting = settings.first(where: { $0.name == argument }), case .text(let text) = setting.value,
                      !isNamedAgain(argument, in: code) {
                address = text
            } else {
                return true
            }
            // `'ht\x74ps://…'` is an address too, though its host is not written out as one.
            if !hosts(in: address).allSatisfy({ named.contains($0) }) { return true }
        }
        return false
    }

    /// The first argument of a call whose `(` ends just before `start` in `text` (UTF-16): up to
    /// its `,` or `)`, quoted texts and brackets passed whole. Nil past 4,096 units, or at the
    /// text's end.
    private static func firstArgument(_ text: [UInt16], from start: Int) -> String? {
        var quote: UInt16?
        var escaped = false
        var depth = 0
        var index = start
        while index < text.count, index - start <= 4096 {
            let unit = text[index]
            if let open = quote {
                if escaped { escaped = false } else if unit == 0x5C { escaped = true } else if unit == open { quote = nil }
            } else {
                switch unit {
                case 0x27, 0x22, 0x60: quote = unit // ' " `
                case 0x28, 0x5B, 0x7B: depth += 1 // ( [ {
                case 0x29, 0x5D, 0x7D: // ) ] }
                    if depth == 0 { return String(decoding: text[start..<index], as: UTF16.self) }
                    depth -= 1
                case 0x2C where depth == 0: // ,
                    return String(decoding: text[start..<index], as: UTF16.self)
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    /// Whether the setting `name` is named in `code` (comments and quoted texts blanked) anywhere
    /// but at its own line and as what a `goto(…)` or an `if (…)` is given: anything else may bind
    /// the name anew (a block's own `const`, a function's parameter, a destructuring).
    private static func isNamedAgain(_ name: String, in code: String) -> Bool {
        let word = NSRegularExpression.escapedPattern(for: name)
        guard let every = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_$])\(word)(?![A-Za-z0-9_$])"),
              let given = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_$])(?:goto|if)\\s*\\(\\s*!?\\s*\(word)\\s*[,)]") else { return true }
        let range = NSRange(location: 0, length: (code as NSString).length)
        return every.numberOfMatches(in: code, range: range) != given.numberOfMatches(in: code, range: range) + 1
    }
}
