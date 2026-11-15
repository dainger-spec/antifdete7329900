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
    public var hosts: [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#) else { return [] }
        let text = source as NSString
        var seen = Set<String>(), found: [String] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let host = text.substring(with: match.range(at: 1)).lowercased()
            if host.contains("."), seen.insert(host).inserted { found.append(host) }
        }
        return found
    }
}
