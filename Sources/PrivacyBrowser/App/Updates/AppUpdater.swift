import AppKit
import BrowserCore
import CryptoKit
import Foundation
import os
import UpdateProgress

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
    /// Why a quit did not install the release, told at the next launch (`reasons`: the log's).
    func rememberNotInstalled(_ why: UpdateDeferral, reasons: String)
}

/// Why a quit did not hand the release to its installer, as the next launch says it.
enum UpdateDeferral: String {
    /// The quit's gate did not pass: a profile still ran or was not encrypted.
    case gate
    /// The installer could not be started.
    case installer
}

/// A download under way: what has come, of how much, since when.
struct UpdateDownloadProgress: Equatable {
    var received: Int64
    var total: Int64
    var startedAt: Date

    /// 0…1; nil while nothing has come (or the size is not known).
    var fraction: Double? {
        guard total > 0, received > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    /// Seconds left at the pace so far; nil for the first second, or before anything came.
    func remaining(at now: Date = Date()) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 1, received > 0, total > received else { return total > 0 && received >= total ? 0 : nil }
        return Double(total - received) / (Double(received) / elapsed)
    }
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

        var helper: URL { app.appendingPathComponent("Contents/Helpers/Lumen Updater.app", isDirectory: true) }

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

    /// How often automatic checks ask, and how long after a launch the first one waits (the
    /// update scenarios of `UpdateSelfTest` shorten the wait). Every hour: it was six, and a Lumen
    /// left open found a release up to six hours after it was out (the owner, 14 November, after
    /// publishing 0.1.13). The appcast is a few kilobytes.
    static let interval: TimeInterval = 3600
    /// The first check comes a few seconds after a launch: it was a minute, and a person who quit
    /// and opened Lumen to get a release looked before the minute was out (the owner, 16 November).
    static var firstCheckDelay: TimeInterval = 3
    /// The person comes back to Lumen — brings it to the front, or the Mac wakes — and the last
    /// check is older than this: the feed is asked again then, a few seconds on, rather than at
    /// the next hour. Zero: never (the update scenarios, which count the feed's requests).
    static var checkWhenBackAfter: TimeInterval = 15 * 60
    static let checkWhenBackDelay: TimeInterval = 5
    /// The appcast is small; anything larger is not one.
    static let feedLimit = 1 << 20

    @Published private(set) var state: UpdateState = .idle
    /// The error behind the last `.failed` state, as thrown. The state says it in the interface's
    /// language; the update scenarios (`UpdateSelfTest`) check which refusal it was by this.
    private(set) var lastFailure: Error?
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
    /// The download under way, for the update's window; nil when none is.
    @Published private(set) var downloadProgress: UpdateDownloadProgress?
    /// The release this build is, as it was downloaded before its install: its notes are "What's
    /// new" at the first launch after it. Nil when this launch is no update's.
    private(set) var installedItem: AppcastItem?
    /// The release whose download failed last: Try Again downloads it again. Nil after a check
    /// failed, or a download went through.
    private(set) var failedRelease: AppcastItem?
    private var downloadTask: URLSessionDataTask?
    private var progressTimer: Timer?

    let configuration: Configuration
    private let defaults: UserDefaults
    private let isPreview: Bool
    private var timer: Timer?
    /// Coming back to the app, and the Mac waking (`start`): kept for the app's life.
    private var backObservers: [NSObjectProtocol] = []
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

    /// Starts the automatic checks — when they are on. Off means off: no timer, no request. Every
    /// launch asks the feed once, `firstCheckDelay` after it, however recently the last one did: a
    /// release that came out meanwhile is found when the person starts the app, not hours later
    /// (0.1.2 → 0.1.3 and 0.1.3 → 0.1.4 were never offered: the app had asked less than the
    /// interval before it was started again, and waited out the rest). Then every `interval`.
    ///
    /// And when the person comes back to Lumen — it is brought to the front, or the Mac wakes —
    /// with the last check older than `checkWhenBackAfter`, it asks a few seconds on: a release
    /// out while the app sat in the background is offered when the person looks, not at the next
    /// hour.
    func start() {
        scheduleChecks(launching: true)
        guard backObservers.isEmpty, !isPreview, Self.checkWhenBackAfter > 0 else { return }
        backObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
        backObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
    }

    /// The person is back: a check now (a few seconds on, for the network after a wake) if the
    /// last one is older than `checkWhenBackAfter` and none is under way; the hourly timer then
    /// counts from it.
    private func cameBack() {
        guard automaticChecks, !isPreview, Self.checkWhenBackAfter > 0 else { return }
        let last = defaults.object(forKey: Key.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkWhenBackAfter else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkWhenBackDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automaticChecks else { return }
                await self.checkNow()
                self.scheduleChecks()
            }
        }
    }

    private func scheduleChecks(launching: Bool = false) {
        timer?.invalidate()
        timer = nil
        guard automaticChecks, !isPreview else { return }
        let last = defaults.object(forKey: Key.lastCheck) as? Date ?? .distantPast
        let due = launching ? Self.firstCheckDelay : max(Self.firstCheckDelay, Self.interval - Date().timeIntervalSince(last))
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
            lastFailure = error
            state = .failed(Self.describe(error))
            if case .ready = previous { state = previous }
        }
    }

    func download() async {
        guard !isPreview, case .available(let item) = state else { return }
        state = .downloading(item)
        failedRelease = nil
        let name = Self.archiveName(for: item.build)
        do {
            try FileManager.default.createDirectory(at: configuration.staging, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let archive = configuration.staging.appendingPathComponent(name)
            let downloaded = configuration.staging.appendingPathComponent(Self.archivePrefix + UUID().uuidString + ".zip")
            try Data().write(to: downloaded, options: .withoutOverwriting)
            defer { _ = unlink(downloaded.path) }
            try await fetchArchive(item.url, expected: item.length, to: downloaded)
            try UpdateVerifier.checkArchive(at: downloaded, item: item, keys: configuration.keys)
            try SecureFile.replace(archive, with: downloaded)
            // The release this one replaces, downloaded and never installed (a newer one came out
            // before a quit), goes: it stayed in the folder for good.
            if let previous = loadStaged(), previous.archive != name { removeArchive(named: previous.archive) }
            saveStaged(Staged(item: item, archive: name))
            state = .ready(item)
            log.notice("Update downloaded and checked; it installs at the next quit that seals every profile")
        } catch {
            if (error as? URLError)?.code == .cancelled {
                // Cancel: the release is offered again, nothing is said.
                log.notice("Update download cancelled")
                state = .available(item)
                return
            }
            log.error("Update download failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            lastFailure = error
            failedRelease = item
            state = .failed(Self.describe(error))
        }
    }

    /// Stops the download under way; the release is offered again.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Try Again after a failure: the download that failed, or the check.
    func retry() async {
        if case .failed = state, let item = failedRelease {
            failedRelease = nil
            state = .available(item)
            await download()
        } else {
            await checkNow()
        }
    }

    /// The archive, into a temporary file of this app's, with what has come said every fifth of a
    /// second (`downloadProgress`); its length is checked against the release.
    private func fetchArchive(_ url: URL, expected length: Int, to file: URL) async throws {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        downloadProgress = UpdateDownloadProgress(received: 0, total: Int64(length), startedAt: Date())
        defer {
            progressTimer?.invalidate()
            progressTimer = nil
            downloadTask = nil
            downloadProgress = nil
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = Self.session.dataTask(with: request)
            task.delegate = UpdateArchiveWriter(handle: handle, length: length, completion: continuation)
            downloadTask = task
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak task] _ in
                MainActor.assumeIsolated {
                    guard let self, let task, self.downloadProgress != nil else { return }
                    self.downloadProgress?.received = task.countOfBytesReceived
                }
            }
            task.resume()
        }
        try handle.close()
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
            try UpdateRequest(appPath: configuration.app.path, archive: staged.archive, item: item, requestedAt: Date(),
                              texts: Self.progressTexts)
                .write(to: configuration.staging)
            try await SystemOpen.startUpdateInstaller(at: configuration.helper)
            helperStarted = true
            log.notice("Update handed to the installer; the app quits now")
            return .started
        } catch {
            log.error("The update's installer did not start: \(error.logKind, privacy: .public)")
            try? FileManager.default.removeItem(at: configuration.staging.appendingPathComponent(UpdateStaging.requestName))
            return .failed(error.localizedDescription)
        }
    }

    func rememberNotInstalled(_ why: UpdateDeferral, reasons: String) {
        guard !isPreview else { return }
        log.notice("Update not handed over at this quit (\(why.rawValue, privacy: .public)): \(reasons, privacy: .private)")
        defaults.set(why.rawValue, forKey: Key.deferred)
    }

    /// The installer's window in the interface's words: it has none of its own, and reads these
    /// from the request (`UpdateProgressTexts`).
    static var progressTexts: [String: String] {
        [UpdateProgressTexts.titleKey: L("updates.progress.title"),
         UpdateProgressTexts.keepOpenKey: L("updates.progress.keepOpen"),
         UpdateProgressTexts.versionKey: L("updates.progress.version"),
         UpdateProgressTexts.downloadKey: L("updates.progress.download"),
         UpdateProgressTexts.checkingKey: L("updates.progress.checking"),
         UpdateProgressTexts.installingKey: L("updates.progress.installing"),
         UpdateProgressTexts.relaunchingKey: L("updates.progress.relaunching"),
         UpdateProgressTexts.cancelKey: L("updates.progress.cancel"),
         UpdateProgressTexts.opensItselfKey: L("updates.progress.opensItself")]
    }

    /// Where the app is decides whether it can be replaced at all.
    func installBlock() -> UpdateBlock? {
        let path = configuration.app.path
        if path.contains("/AppTranslocation/") { return .translocated }
        if (try? configuration.app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return .notWritable }
        guard Self.userCanWrite(configuration.app.deletingLastPathComponent()) else { return .notWritable }
        return nil
    }

    /// Whether this user may write `folder` — the installer replaces the app as this user, outside
    /// any sandbox. Told from the folder's owner, group and mode: `access(2)` answers for this
    /// process, and in the sandboxed build its sandbox refuses every folder outside the container.
    nonisolated static func userCanWrite(_ folder: URL) -> Bool {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return false }
        if info.st_uid == getuid() { return info.st_mode & S_IWUSR != 0 }
        let count = getgroups(0, nil)
        var groups = [gid_t](repeating: 0, count: Int(max(count, 0)))
        let found = getgroups(count, &groups)
        if info.st_gid == getgid() || (found > 0 && groups.prefix(Int(found)).contains(info.st_gid)) {
            return info.st_mode & S_IWGRP != 0
        }
        return info.st_mode & S_IWOTH != 0
    }

    // MARK: Staged release

    private func loadStaged() -> Staged? {
        guard let data = defaults.data(forKey: Key.staged) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let staged = try? decoder.decode(Staged.self, from: data),
              BuildVersion(staged.item.build) != nil,
              staged.archive == Self.archiveName(for: staged.item.build) else {
            defaults.removeObject(forKey: Key.staged)
            return nil
        }
        return staged
    }

    private func saveStaged(_ staged: Staged) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(staged) { defaults.set(data, forKey: Key.staged) }
    }

    private func archiveExists(_ staged: Staged) -> Bool {
        let url = configuration.staging.appendingPathComponent(staged.archive)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    private func discardStaged() {
        if let staged = loadStaged() {
            removeArchive(named: staged.archive)
        }
        defaults.removeObject(forKey: Key.staged)
    }

    /// What every release's archive is called in the staging folder, before its build.
    private static let archivePrefix = "PrivacyBrowser-"

    private static func archiveName(for build: String) -> String { archivePrefix + build + ".zip" }

    /// Removes a release's archive from the staging folder — never the one a request hands the
    /// installer, nor anything named as no archive of ours is.
    private func removeArchive(named name: String) {
        guard name.hasPrefix(Self.archivePrefix), UpdateStaging.isArchiveName(name) else { return }
        let identifier = String(name.dropFirst(Self.archivePrefix.count).dropLast(".zip".count))
        guard BuildVersion(identifier) != nil || UUID(uuidString: identifier) != nil else { return }
        if let request = try? UpdateRequest.read(from: configuration.staging), request.archive == name { return }
        // Only remove a directory entry for a file. Never recursively delete a folder during cleanup.
        _ = unlink(configuration.staging.appendingPathComponent(name).path)
    }

    /// At launch: the archives of releases downloaded and never installed that nothing names any
    /// more — each replaced by a newer one before a quit, by a build that did not remove it — go.
    /// The one staged stays (`restoreStaged` decides about it), and the one a request names.
    private func removeSupersededArchives() {
        let staged = loadStaged()?.archive
        for name in (try? FileManager.default.contentsOfDirectory(atPath: configuration.staging.path)) ?? [] where name != staged {
            removeArchive(named: name)
        }
    }

    /// At launch: a staged release still newer than this build, with its archive, is ready again;
    /// anything else staged (installed meanwhile, or gone) is removed, and so is every archive
    /// nothing names (`removeSupersededArchives`).
    private func restoreStaged() {
        defer { removeSupersededArchives() }
        guard let staged = loadStaged() else { return }
        if let build = BuildVersion(staged.item.build), build > configuration.build, archiveExists(staged) {
            state = .ready(staged.item)
        } else {
            // This build is that release: its notes are what is new.
            if BuildVersion(staged.item.build) == configuration.build { installedItem = staged.item }
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
            // An earlier build kept the gate's words here: that was the gate.
            notice = notice ?? .deferred(UpdateDeferral(rawValue: reason) ?? .gate)
        }
        return notice
    }

    // MARK: Network

    /// The updater's own session: ephemeral, no cookies, no cache, no credentials, and the same
    /// headers from every Mac — a User-Agent without a version, one fixed language.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Lumen", "Accept-Language": "en"]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: UpdateTestTrust(), delegateQueue: nil)
    }()

    private nonisolated static func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateFetchError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard response.expectedContentLength <= Int64(limit) else { throw UpdateError.notAnAppcast }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw UpdateError.notAnAppcast }
            data.append(byte)
        }
        return data
    }

    /// A failure in the interface's words: the system's own (`localizedDescription`) follow the
    /// Mac's language, not the interface's.
    private static func describe(_ error: Error) -> String {
        if let error = error as? UpdateError { return errorText(error) }
        if let error = error as? UpdateFetchError { return error.description }
        if let error = error as? URLError {
            switch error.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return L("updates.error.secure")
            default:
                return L("updates.error.network")
            }
        }
        return L("updates.error.other")
    }

    private static var system: BuildVersion { BuildVersion(ProcessInfo.processInfo.operatingSystemVersion) }

    /// The user's own home: the staging folder is outside every container.
    nonisolated static var realHome: URL {
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

private enum UpdateFetchError: Error, CustomStringConvertible {
    case status(Int)
    var description: String {
        switch self {
        case .status(let code): return String(format: L("error.update.status"), code)
        }
    }
}

/// URLSession serializes these callbacks. Check the signed length before each disk write,
/// including when the server omits Content-Length or sends an encoded response.
private final class UpdateArchiveWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let length: Int
    private let completion: CheckedContinuation<Void, Error>
    private var written = 0
    private var failure: Error?

    init(handle: FileHandle, length: Int, completion: CheckedContinuation<Void, Error>) {
        self.handle = handle
        self.length = length
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = UpdateFetchError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard data.count <= length - written else {
                throw UpdateError.archiveLength(expected: length, found: written + data.count)
            }
            try handle.write(contentsOf: data)
            written += data.count
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let problem = failure ?? error {
            completion.resume(throwing: problem)
        } else if written != length {
            completion.resume(throwing: UpdateError.archiveLength(expected: length, found: written))
        } else {
            completion.resume()
        }
    }
}

/// The update scenarios' local feed (`UpdateSelfTest`, scripts/update_check.py) has a certificate of
/// its own, which no system on a CI runner trusts — and a runner's trust settings cannot be changed
/// without someone at the screen. That mode alone, behind `PB_SELFTEST_UPDATES=1`, its own command
/// line and its own bundle id, names the certificate here by the SHA-256 of its DER, and a server
/// presenting exactly that certificate is accepted. The app never sets it: nil, and every server
/// gets the system's evaluation and nothing else.
final class UpdateTestTrust: NSObject, URLSessionTaskDelegate {
    nonisolated(unsafe) static var certificateSHA256: Data?

    // Foundation's streaming API can deliver server trust to the task rather than the session.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let pinned = Self.certificateSHA256,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == pinned else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// What became of the last update, told once at the next launch.
enum UpdateNotice: Equatable {
    case outcome(UpdateOutcome)
    /// The last quit did not hand the update over, and why.
    case deferred(UpdateDeferral)
}
