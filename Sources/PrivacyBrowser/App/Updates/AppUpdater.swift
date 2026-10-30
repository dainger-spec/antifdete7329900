import AppKit
import BrowserCore
import Foundation
import os

/// Updating, behind one boundary (docs/UPDATES.md §1): today our own mechanics (`AppUpdater`);
/// whatever replaces them keeps the quit path, the settings and the screen as they are.
@MainActor
protocol Updater: AnyObject {
    var state: UpdateState { get }
    var automaticChecks: Bool { get set }
    var installPolicy: UpdateInstallPolicy { get set }
    /// Asks the feed now; downloads by the policy.
    func checkNow() async
    /// Downloads the release offered (the "only tell me" policy waits for this).
    func download() async
    /// At the end of a quit, after every profile was sealed: hands the downloaded release to the
    /// installer if `gate` passed.
    func installAtQuit(gate: UpdateGate.Verdict) async -> UpdateHandOver
    /// Why a quit did not install the release, told at the next launch.
    func rememberNotInstalled(_ reason: String)
}

/// What came of handing a release to the installer at a quit.
enum UpdateHandOver: Equatable {
    case started
    /// The gate did not pass: what failed.
    case refused([String])
    case blocked(UpdateBlock)
    /// The installer could not be started.
    case failed(String)
    /// No release is downloaded and checked.
    case nothingReady
}

/// What to do with a release once it is known.
enum UpdateInstallPolicy: String, CaseIterable {
    /// Download in the background, install at the next quit that seals every profile.
    case atQuit
    /// Say there is one; download and install only when asked.
    case notifyOnly
}

/// Why a release cannot be installed where this app is.
enum UpdateBlock: Equatable {
    /// macOS runs the app from a random read-only place (App Translocation): it has to be moved
    /// to Applications first.
    case translocated
    /// The folder the app is in cannot be written by this user.
    case notWritable
}

enum UpdateState: Equatable {
    /// Never asked yet (automatic checks off, or the first check is still to come).
    case idle
    case upToDate(checkedAt: Date)
    case checking
    /// Newer, not downloaded (the "only tell me" policy).
    case available(AppcastItem)
    case downloading(AppcastItem)
    /// Downloaded and checked: installed at the next quit that seals every profile.
    case ready(AppcastItem)
    case blocked(AppcastItem, UpdateBlock)
    /// The last check or download failed, in the log's words.
    case failed(String)

    /// The release this state is about, if any.
    var item: AppcastItem? {
        switch self {
        case .available(let item), .downloading(let item), .ready(let item), .blocked(let item, _): return item
        default: return nil
        }
    }
}

/// The app's updater: in the manager process only — a profile's process never makes one — with a
/// session of its own that nothing else uses (docs/UPDATES.md §5).
@MainActor
final class AppUpdater: ObservableObject, Updater {
    /// What the running app's own Info.plist says about updates.
    struct Configuration {
        let feed: URL
        let keys: [String: Data]
        let version: String
        let build: BuildVersion
        let bundleIdentifier: String
        let app: URL
        let staging: URL

        var helper: URL { app.appendingPathComponent("Contents/Helpers/PrivacyBrowser Updater.app", isDirectory: true) }

        /// Nil for a build without a feed URL or keys (every development build), and in a
        /// profile's own process: then there is no updater, and nothing is ever asked.
        static func main() -> Configuration? {
            guard !CommandLine.arguments.contains("--profile-session") else { return nil }
            let info = Bundle.main.infoDictionary ?? [:]
            guard let text = info["PBUpdateFeedURL"] as? String, let feed = URL(string: text), feed.scheme == "https",
                  let version = info["CFBundleShortVersionString"] as? String,
                  let build = (info["CFBundleVersion"] as? String).flatMap(BuildVersion.init),
                  let identifier = Bundle.main.bundleIdentifier else { return nil }
            let keys = UpdateKeys.fromInfoPlist(info["PBUpdatePublicKeys"])
            guard !keys.isEmpty else { return nil }
            return Configuration(feed: feed, keys: keys, version: version, build: build, bundleIdentifier: identifier,
                                 app: Bundle.main.bundleURL.standardizedFileURL,
                                 staging: UpdateStaging.folder(bundleIdentifier: identifier, home: AppUpdater.realHome))
        }
    }

    /// A downloaded release: its item and the archive's name in the staging folder.
    private struct Staged: Codable, Equatable {
        var item: AppcastItem
        var archive: String
    }

    private enum Key {
        static let automatic = "PBUpdateAutomaticChecks"
        static let policy = "PBUpdateInstallPolicy"
        static let newestAppcast = "PBUpdateNewestAppcast"
        static let lastCheck = "PBUpdateLastCheck"
        static let staged = "PBUpdateStaged"
        static let deferred = "PBUpdateDeferred"
    }

    /// How often automatic checks ask, and how long after a launch the first one waits.
    static let interval: TimeInterval = 6 * 3600
    static let firstCheckDelay: TimeInterval = 60
    /// The appcast is small; anything larger is not one.
    static let feedLimit = 1 << 20

    @Published private(set) var state: UpdateState = .idle
    @Published var automaticChecks: Bool {
        didSet {
            guard automaticChecks != oldValue, !isPreview else { return }
            defaults.set(automaticChecks, forKey: Key.automatic)
            scheduleChecks()
        }
    }
    @Published var installPolicy: UpdateInstallPolicy {
        didSet {
            guard installPolicy != oldValue, !isPreview else { return }
            defaults.set(installPolicy.rawValue, forKey: Key.policy)
            if installPolicy == .atQuit, case .available = state { Task { await download() } }
        }
    }
    /// What became of the last update, read at this launch (the app says a failure once; the
    /// Updates sheet says an installed one).
    private(set) var notice: UpdateNotice?

    let configuration: Configuration
    private let defaults: UserDefaults
    private let isPreview: Bool
    private var timer: Timer?
    private var helperStarted = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "Updates")

    init(configuration: Configuration, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaults = defaults
        isPreview = false
        automaticChecks = defaults.object(forKey: Key.automatic) as? Bool ?? true
        installPolicy = (defaults.string(forKey: Key.policy)).flatMap(UpdateInstallPolicy.init) ?? .atQuit
        if let checked = defaults.object(forKey: Key.lastCheck) as? Date { state = .upToDate(checkedAt: checked) }
        notice = Self.collectNotice(configuration: configuration, defaults: defaults)
        restoreStaged()
    }

    /// A fixed state for the UI snapshots: nothing is fetched, stored or scheduled.
    init(preview state: UpdateState, configuration: Configuration, automaticChecks: Bool = true,
         installPolicy: UpdateInstallPolicy = .atQuit) {
        self.configuration = configuration
        defaults = .standard // never read or written by a preview
        isPreview = true
        self.automaticChecks = automaticChecks
        self.installPolicy = installPolicy
        self.state = state
    }

    // MARK: Checks

    /// Starts the automatic checks — when they are on. Off means off: no timer, no request.
    func start() {
        scheduleChecks()
    }

    private func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard automaticChecks, !isPreview else { return }
        let last = defaults.object(forKey: Key.lastCheck) as? Date ?? .distantPast
        let due = max(Self.firstCheckDelay, Self.interval - Date().timeIntervalSince(last))
        timer = Timer.scheduledTimer(withTimeInterval: due, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automaticChecks else { return }
                await self.checkNow()
                self.scheduleChecks()
            }
        }
    }

    func checkNow() async {
        guard !isPreview else { return }
        switch state {
        case .checking, .downloading: return
        default: break
        }
        let previous = state
        state = .checking
        do {
            let data = try await Self.fetch(configuration.feed, limit: Self.feedLimit)
            let appcast = try UpdateVerifier.appcast(from: data, keys: configuration.keys)
            let newest = defaults.object(forKey: Key.newestAppcast) as? Date
            try UpdateVerifier.checkFreshness(appcast, newestAccepted: newest)
            defaults.set(max(appcast.generatedAt, newest ?? appcast.generatedAt), forKey: Key.newestAppcast)
            let now = Date()
            defaults.set(now, forKey: Key.lastCheck)
            guard let item = UpdateVerifier.update(in: appcast, running: configuration.build, system: Self.system,
                                                    keys: configuration.keys) else {
                discardStaged()
                state = .upToDate(checkedAt: now)
                return
            }
            if let staged = loadStaged(), staged.item == item, archiveExists(staged) {
                state = .ready(item)
                return
            }
            if let block = installBlock() {
                state = .blocked(item, block)
                return
            }
            state = .available(item)
            if installPolicy == .atQuit { await download() }
        } catch {
            log.error("Update check failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            state = .failed(Self.describe(error))
            if case .ready = previous { state = previous }
        }
    }

    func download() async {
        guard !isPreview, case .available(let item) = state else { return }
        state = .downloading(item)
        let name = "PrivacyBrowser-\(item.build).zip"
        do {
            try FileManager.default.createDirectory(at: configuration.staging, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let archive = configuration.staging.appendingPathComponent(name)
            let downloaded = try await Self.download(item.url, expected: item.length)
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: downloaded, to: archive)
            try UpdateVerifier.checkArchive(at: archive, item: item, keys: configuration.keys)
            saveStaged(Staged(item: item, archive: name))
            state = .ready(item)
            log.notice("Update downloaded and checked; it installs at the next quit that seals every profile")
        } catch {
            try? FileManager.default.removeItem(at: configuration.staging.appendingPathComponent(name))
            log.error("Update download failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            state = .failed(Self.describe(error))
        }
    }

    // MARK: Installing

    /// A release is downloaded and checked: the quit hands it over (`installAtQuit`).
    var isReady: Bool {
        if case .ready = state { return !helperStarted }
        return false
    }

    func installAtQuit(gate: UpdateGate.Verdict) async -> UpdateHandOver {
        guard !isPreview, !helperStarted, case .ready(let item) = state, let staged = loadStaged(), staged.item == item else {
            return .nothingReady
        }
        guard gate.passed else {
            log.notice("Update not installed: \(gate.reasons.count, privacy: .public) check(s) of the quit failed")
            return .refused(gate.reasons)
        }
        if let block = installBlock() {
            state = .blocked(item, block)
            return .blocked(block)
        }
        do {
            try UpdateRequest(appPath: configuration.app.path, archive: staged.archive, item: item, requestedAt: Date())
                .write(to: configuration.staging)
            let open = NSWorkspace.OpenConfiguration()
            open.activates = false
            open.addsToRecentItems = false
            _ = try await NSWorkspace.shared.openApplication(at: configuration.helper, configuration: open)
            helperStarted = true
            log.notice("Update handed to the installer; the app quits now")
            return .started
        } catch {
            log.error("The update's installer did not start: \(error.logKind, privacy: .public)")
            try? FileManager.default.removeItem(at: configuration.staging.appendingPathComponent(UpdateStaging.requestName))
            return .failed(error.localizedDescription)
        }
    }

    func rememberNotInstalled(_ reason: String) {
        guard !isPreview else { return }
        defaults.set(reason, forKey: Key.deferred)
    }

    /// Where the app is decides whether it can be replaced at all.
    func installBlock() -> UpdateBlock? {
        let path = configuration.app.path
        if path.contains("/AppTranslocation/") { return .translocated }
        guard FileManager.default.isWritableFile(atPath: configuration.app.deletingLastPathComponent().path) else {
            return .notWritable
        }
        return nil
    }

    // MARK: Staged release

    private func loadStaged() -> Staged? {
        guard let data = defaults.data(forKey: Key.staged) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Staged.self, from: data)
    }

    private func saveStaged(_ staged: Staged) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(staged) { defaults.set(data, forKey: Key.staged) }
    }

    private func archiveExists(_ staged: Staged) -> Bool {
        FileManager.default.fileExists(atPath: configuration.staging.appendingPathComponent(staged.archive).path)
    }

    private func discardStaged() {
        if let staged = loadStaged() {
            try? FileManager.default.removeItem(at: configuration.staging.appendingPathComponent(staged.archive))
        }
        defaults.removeObject(forKey: Key.staged)
    }

    /// At launch: a staged release still newer than this build, with its archive, is ready again;
    /// anything else staged (installed meanwhile, or gone) is removed.
    private func restoreStaged() {
        guard let staged = loadStaged() else { return }
        if let build = BuildVersion(staged.item.build), build > configuration.build, archiveExists(staged) {
            state = .ready(staged.item)
        } else {
            discardStaged()
        }
    }

    /// The installer's outcome, or the reason the last quit did not install, as a notice; both are
    /// used up.
    private static func collectNotice(configuration: Configuration, defaults: UserDefaults) -> UpdateNotice? {
        var notice: UpdateNotice?
        if let outcome = UpdateOutcome.read(from: configuration.staging) {
            notice = .outcome(outcome)
            try? FileManager.default.removeItem(at: configuration.staging.appendingPathComponent(UpdateStaging.outcomeName))
        }
        if let reason = defaults.string(forKey: Key.deferred) {
            defaults.removeObject(forKey: Key.deferred)
            notice = notice ?? .deferred(reason)
        }
        return notice
    }

    // MARK: Network

    /// The updater's own session: ephemeral, no cookies, no cache, no credentials, and the same
    /// headers from every Mac — a User-Agent without a version, one fixed language.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "PrivacyBrowser", "Accept-Language": "en"]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateFetchError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= limit else { throw UpdateError.notAnAppcast }
        return data
    }

    /// The archive, into a temporary file of the session's; its length is checked against the release.
    private static func download(_ url: URL, expected length: Int) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (file, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateFetchError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        guard size == length else { throw UpdateError.archiveLength(expected: length, found: size) }
        return file
    }

    private enum UpdateFetchError: Error, CustomStringConvertible {
        case status(Int)
        var description: String {
            switch self {
            case .status(let code): return "the server answered \(code)"
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? UpdateError { return error.description }
        if let error = error as? UpdateFetchError { return error.description }
        return error.localizedDescription
    }

    private static var system: BuildVersion { BuildVersion(ProcessInfo.processInfo.operatingSystemVersion) }

    /// The user's own home: the staging folder is outside every container.
    static var realHome: URL {
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// What became of the last update, told once at the next launch.
enum UpdateNotice: Equatable {
    case outcome(UpdateOutcome)
    /// The last quit did not hand the update over, and why.
    case deferred(String)
}
