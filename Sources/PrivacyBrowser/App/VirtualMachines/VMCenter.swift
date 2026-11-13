import BrowserCore
import Combine
import Foundation
import os

/// The virtual machines of the unlocked vault (docs/VM.md): the profiles that are whole Macs, the
/// one-time setup that brings their macOS to this Mac — asked of Apple, fetched from Apple, installed
/// and set up once as the base every profile's machine is a clone of — and the machines running now.
///
/// Made at unlock and dropped at lock (`AppModel.virtualMachines`), with the vault it holds. Every
/// machine runs in a helper process of its own (`VMHelperProcess`); at most
/// `VMRequirements.runningLimit` at once, Apple's limit for macOS guests. Lock and Quit shut the
/// machines down first (`stopAll`).
@MainActor
final class VMCenter: ObservableObject {
    // MARK: Whether this Mac and this build can

    enum Availability: Equatable {
        case available
        /// macOS runs as a guest only on Apple silicon.
        case notAppleSilicon
        /// The build carries no helper (`VM=1 scripts/build-app.sh` puts it in).
        case notInThisBuild
        /// A sandboxed build's helper could not reach the library.
        case sandboxed
    }

    static var availability: Availability {
        #if arch(arm64)
        if AppEnvironment.isSandboxed { return .sandboxed }
        return VMHelperProcess.executableURL == nil ? .notInThisBuild : .available
        #else
        return VMHelperProcess.executableURL == nil ? .notInThisBuild : .notAppleSilicon
        #endif
    }

    /// The Profiles window has the section at all: the build carries the machines' helper.
    static var isOffered: Bool { availability != .notInThisBuild }

    // MARK: State

    /// What the one-time setup is doing now.
    enum SetupActivity: Equatable {
        /// Asking Apple which macOS this Mac can run as a guest.
        case asking
        case downloading(VMImageDownloader.Progress)
        case installing(Double)
        /// The base is running in its window, for the person to finish macOS's first-run setup and
        /// the tools in it.
        case guestSetup
    }

    struct Running: Equatable {
        enum Phase: Equatable { case checkingProxy, starting, running, stopping }
        var phase: Phase
        var startedAt = Date()
        var bytesUp: UInt64 = 0
        var bytesDown: UInt64 = 0
        var connections = 0
    }

    @Published private(set) var list: VMProfiles
    /// Why the stored list could not be read. It is then shown empty and never written.
    let loadError: String?
    /// How far the setup got, from what is on disk.
    @Published private(set) var setup: VMSetupState
    @Published private(set) var activity: SetupActivity?
    @Published private(set) var setupError: String?
    /// The macOS Apple offered when it was last asked.
    @Published private(set) var offeredImage: VMRestoreImage?
    @Published private(set) var running: [UUID: Running] = [:]
    /// Why a profile's machine did not start, or ended, the last time; cleared by its next start.
    @Published private(set) var problems: [UUID: String] = [:]
    /// Where each profile's proxy came out at its last start (since unlock).
    @Published private(set) var exits: [UUID: ProxyCheckResult] = [:]
    /// What each machine's macOS said of itself the last time it ran (its version, Safari's).
    @Published private(set) var guests: [UUID: VMGuestStatus] = [:]
    /// What each machine's files take on disk; the base's under `VMCenter.baseID`.
    @Published private(set) var diskUsage: [UUID: Int64] = [:]

    /// The base's place in `diskUsage`, and the place of what was fetched for it (Apple's restore
    /// image, whole or in part).
    static let baseID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BA")!
    static let downloadsID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D0")!
    /// What the setup is assumed to fetch before Apple's server has said the image's length
    /// (macOS 26's restore image is 25.6 GB).
    static let assumedDownloadBytes: Int64 = 26 * VMRequirements.gibibyte

    /// The plan has virtual machines (`LicenseModel.allowsVirtualMachines`, set by `AppModel`).
    /// Without it the setup does not go on and no machine starts; what is on disk stays, and can
    /// be deleted.
    var isAllowed: () -> Bool = { true }

    let library: VMLibrary
    private let vault: UnlockedVault
    private let onError: (String) -> Void
    private var helpers: [UUID: VMHelperProcess] = [:]
    private var setupHelper: VMHelperProcess?
    private var downloader: VMImageDownloader?
    /// The current run of the setup: what an earlier one still says is not listened to.
    private var setupRun: UUID?
    private var awake: NSObjectProtocol?
    /// When the disk was last measured (`measureDisk`).
    private var lastMeasure = Date.distantPast
    private let log = Logger(subsystem: "PrivacyBrowser", category: "VirtualMachines")

    init(vault: UnlockedVault, library: VMLibrary, onError: @escaping (String) -> Void) {
        self.vault = vault
        self.library = library
        self.onError = onError
        setup = library.setupState()
        do {
            list = try VMProfiles.load(from: vault)
            loadError = nil
        } catch {
            list = VMProfiles()
            loadError = errorText(error)
            log.error("The virtual machines' list could not be read: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
        for profile in list.profiles { readGuestStatus(of: profile.id) }
        measureDisk()
    }

    var profiles: [VMProfile] { list.profiles }

    /// Machines that count against Apple's limit now: the profiles', and the base while it is
    /// being installed or set up.
    var runningCount: Int {
        var count = helpers.count
        switch activity {
        case .installing?, .guestSetup?: count += 1
        default: break
        }
        return count
    }

    var hasRunning: Bool { !helpers.isEmpty || setupHelper != nil }
    var isReady: Bool { if case .ready = setup { return true } else { return false } }

    /// What the machines take on disk in all: the base, what was fetched for it, every machine.
    var totalDiskUsage: Int64 { diskUsage.values.reduce(0, +) }

    /// What the setup still needs free on disk, as far as is known now — for the section to say
    /// before anything is fetched.
    var setupNeedsBytes: Int64 {
        VMRequirements.setupBytes(downloadBytes: offeredDownloadBytes ?? Self.assumedDownloadBytes)
    }

    /// The restore image's length, once Apple's server has said it.
    private var offeredDownloadBytes: Int64? {
        if case .downloading(let progress)? = activity, let total = progress.total { return total }
        if case .downloading(_, let total) = setup { return total }
        return nil
    }

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    /// What stands in the way of the setup on this Mac now (`VMRequirements`).
    var requirements: [VMRequirements.Problem] {
        var download = Self.assumedDownloadBytes
        switch setup {
        case .downloading(let have, let total): download = max(0, (total ?? Self.assumedDownloadBytes) - have)
        case .downloaded, .needsGuestSetup, .ready: download = 0
        case .none: break
        }
        if case .downloading(let progress)? = activity, let total = progress.total { download = max(0, total - progress.have) }
        var problems = VMRequirements.problems(appleSilicon: Self.availability != .notAppleSilicon, helperAvailable: true,
                                               freeDisk: freeDisk, downloadBytes: download,
                                               hostMemory: Int64(clamping: ProcessInfo.processInfo.physicalMemory))
        // Once macOS is installed, the room it needed is taken already.
        if case .needsGuestSetup = setup { problems.removeAll { if case .notEnoughDisk = $0 { return true } else { return false } } }
        if case .ready = setup { problems.removeAll { if case .notEnoughDisk = $0 { return true } else { return false } } }
        return problems
    }

    /// Free room on the volume the library is on.
    var freeDisk: Int64 {
        var url = library.root
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: The setup

    /// Starts the setup, or goes on with it from where it stopped: what Apple offers is asked and
    /// fetched, macOS installed from it, and the base opened for its first-run setup.
    func continueSetup() {
        guard activity == nil, Self.availability == .available else { return }
        guard isAllowed() else {
            setupError = L("vm.error.notInPlan")
            return
        }
        setupError = nil
        setup = library.setupState()
        switch setup {
        case .ready:
            return
        case .needsGuestSetup:
            openBase()
        case .downloaded:
            install()
        case .none, .downloading:
            guard !requirements.contains(where: VMRequirements.stops) else { return }
            askCatalog()
        }
    }

    private func beginRun() -> UUID {
        let run = UUID()
        setupRun = run
        return run
    }

    private func askCatalog() {
        let run = beginRun()
        activity = .asking
        var image: VMRestoreImage?
        let helper = VMHelperProcess(onEvent: { event in
            if event.kind == .catalog { image = event.image }
        }, onEnd: { [weak self] failure in
            guard let self, self.setupRun == run else { return }
            self.setupHelper = nil
            guard let image, failure == nil else {
                return self.setupFailed(failure ?? L("vm.error.unknown"))
            }
            self.offeredImage = image
            self.download(image)
        })
        start(helper, VMHelperRequest(mode: .catalog))
    }

    private func download(_ image: VMRestoreImage) {
        let run = beginRun()
        holdAwake(true)
        excludeFromBackups()
        activity = .downloading(VMImageDownloader.Progress(have: VMLibrary.fileSize(library.partialRestoreImageURL),
                                                           total: library.downloadState().flatMap { $0.image == image ? $0.expectedLength : nil },
                                                           speed: nil))
        let downloader = VMImageDownloader(library: library, image: image, onProgress: { [weak self] progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.setupRun == run else { return }
                    self.activity = .downloading(progress)
                    // What is fetched so far is on disk, and the section says how much the
                    // machines take: counted again now and then, not at every step.
                    if Date().timeIntervalSince(self.lastMeasure) > 8 { self.measureDisk() }
                }
            }
        }, onFinish: { [weak self] result in
            let failure: String?
            if case .failure(let error) = result { failure = errorText(error) } else { failure = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.setupRun == run else { return }
                    self.downloader = nil
                    if let failure { return self.setupFailed(failure) }
                    self.install()
                }
            }
        })
        self.downloader = downloader
        downloader.start()
    }

    /// Stops the download where it is; `continueSetup` goes on from there.
    func pauseDownload() {
        guard case .downloading? = activity else { return }
        downloader?.pause()
        downloader = nil
        setupRun = nil
        activity = nil
        holdAwake(false)
        setup = library.setupState()
        measureDisk()
    }

    private func install() {
        let run = beginRun()
        holdAwake(true)
        excludeFromBackups()
        activity = .installing(0)
        var installed: VMRestoreImage?
        let helper = VMHelperProcess(onEvent: { [weak self] event in
            guard let self, self.setupRun == run else { return }
            switch event.kind {
            case .progress: self.activity = .installing(min(1, max(0, event.fraction ?? 0)))
            case .installed: installed = event.image
            default: break
            }
        }, onEnd: { [weak self] failure in
            guard let self, self.setupRun == run else { return }
            self.setupHelper = nil
            guard failure == nil else { return self.setupFailed(failure ?? L("vm.error.unknown")) }
            do {
                try self.library.saveBaseInfo(VMBaseInfo(stage: .installed, version: installed?.version ?? "",
                                                         build: installed?.build ?? ""))
            } catch {
                return self.setupFailed(errorText(error))
            }
            // The restore image stays until the base is set up: starting the setup over is then
            // an installation, not another download of its gigabytes.
            self.activity = nil
            self.holdAwake(false)
            self.setup = self.library.setupState()
            self.measureDisk()
            self.openBase()
        })
        start(helper, VMHelperRequest(mode: .install, restoreImagePath: library.restoreImageURL.path,
                                      machineDirectory: library.baseDirectory.path,
                                      cores: VMRequirements.cores(hostCores: ProcessInfo.processInfo.activeProcessorCount),
                                      memoryBytes: Int64(VMRequirements.standardMemoryGB) * VMRequirements.gibibyte))
    }

    /// Stops an installation under way. What it wrote is not a system: the next one starts over.
    func cancelInstallation() {
        guard case .installing? = activity else { return }
        setupRun = nil
        setupHelper?.terminate()
        setupHelper = nil
        activity = nil
        holdAwake(false)
        setup = library.setupState()
    }

    /// The memory the base gets while it is set up: macOS's first run is the heaviest thing a
    /// machine does, and the setup is the one time the person waits on it.
    static var setupMemoryGB: Int {
        let host = Int(ProcessInfo.processInfo.physicalMemory / UInt64(VMRequirements.gibibyte))
        return host >= 16 ? 8 : (host >= 12 ? 6 : VMRequirements.standardMemoryGB)
    }

    /// Opens the base in its window — for macOS's first-run setup and the tools, or later to change
    /// something every new profile's machine should have.
    ///
    /// `online` nil: a base not set up yet has **no network card** — macOS's setup asks nothing of
    /// Apple's servers then, is shorter by the screens that need them, and cannot hang waiting for
    /// them (the owner's Mac, 13 November: the setup stood on a screen with its buttons off); a
    /// base that is ready has this Mac's own connection, for what the person wants to add to it.
    func openBase(online: Bool? = nil) {
        guard activity == nil, Self.availability == .available, library.base.isComplete, let info = library.baseInfo() else { return }
        let network: VMHelperRequest.Network = (online ?? (info.stage == .ready)) ? .direct : .absent
        guard isAllowed() else {
            setupError = L("vm.error.notInPlan")
            return
        }
        guard runningCount < VMRequirements.runningLimit else {
            setupError = L("vm.error.limit")
            return
        }
        setupError = nil
        do {
            try placeGuestTools()
        } catch {
            setupError = errorText(error)
            return
        }
        let run = beginRun()
        activity = .guestSetup
        let helper = VMHelperProcess(onEvent: { _ in }, onEnd: { [weak self] failure in
            guard let self, self.setupRun == run else { return }
            self.setupHelper = nil
            self.activity = nil
            if let failure { self.setupError = failure }
            // The tools' installer says in the shared folder that it has done its work.
            let status = (try? String(contentsOf: self.library.base.status, encoding: .utf8)).map(VMGuestStatus.init(text:))
            if let status, status.setupDone {
                // The base is set up: the restore image has done its work, and its gigabytes go
                // back to the disk.
                self.removeDownloads()
                var ready = info
                ready.stage = .ready
                ready.toolsVersion = status.toolsVersion ?? VMGuestTools.version
                if let version = status.systemVersion, !version.isEmpty { ready.version = version }
                if let build = status.systemBuild, !build.isEmpty { ready.build = build }
                do {
                    try self.library.saveBaseInfo(ready)
                } catch {
                    self.setupError = errorText(error)
                }
            }
            self.setup = self.library.setupState()
            self.measureDisk()
        })
        start(helper, VMHelperRequest(mode: .run, machineDirectory: library.baseDirectory.path,
                                      cores: VMRequirements.cores(hostCores: ProcessInfo.processInfo.activeProcessorCount),
                                      memoryBytes: Int64(Self.setupMemoryGB) * VMRequirements.gibibyte,
                                      macAddress: VMProfile.randomMACAddress(), network: network,
                                      windowTitle: L("vm.base.window"), texts: Self.helperTexts))
    }

    /// Shuts the base down (its window's own close button does the same).
    func closeBase() {
        guard case .guestSetup? = activity else { return }
        setupHelper?.stop()
    }

    /// Removes the base system — to set the machines up anew. A restore image still there (the
    /// base was not set up yet) stays, so the setup starts over from the installation, not from
    /// the download. The profiles' machines stay: each has a disk of its own.
    func removeBase() {
        guard activity == nil else { return }
        try? FileManager.default.removeItem(at: library.baseDirectory)
        try? FileManager.default.removeItem(at: library.baseInfoURL)
        setupError = nil
        setup = library.setupState()
        measureDisk()
    }

    private func start(_ helper: VMHelperProcess, _ request: VMHelperRequest) {
        do {
            try helper.start(request)
            setupHelper = helper
        } catch {
            setupFailed(errorText(error))
        }
    }

    private func setupFailed(_ text: String) {
        setupRun = nil
        setupHelper = nil
        downloader = nil
        activity = nil
        holdAwake(false)
        setupError = text
        setup = library.setupState()
        log.error("The virtual machines' setup stopped: \(text, privacy: .private)")
    }

    private func removeDownloads() {
        for url in [library.restoreImageURL, library.partialRestoreImageURL, library.downloadStateURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stops the setup where it is and removes what was fetched for it: the gigabytes of a
    /// download the person called off go back to the disk. The base, if there is one, stays.
    func removeDownloadedImage() {
        switch activity {
        case .downloading?: pauseDownload()
        case .installing?: cancelInstallation()
        case .asking?, .guestSetup?: return
        case nil: break
        }
        removeDownloads()
        setupError = nil
        setup = library.setupState()
        measureDisk()
    }

    /// Removes everything the machines have on this Mac — every profile's machine with its disk,
    /// the base system, what was fetched — and gives the disk back. Only from the person's own
    /// "Delete everything", confirmed (scripts/check_deletion_paths.py); never while a machine
    /// runs or the setup is at work.
    func deleteEverythingBecauseThePersonAsked() throws {
        guard !hasRunning, running.isEmpty, activity == nil else { throw Refusal.busy }
        // A list that did not read names no machine: their folders are then not this call's to remove.
        guard loadError == nil else { throw Refusal.listUnreadable }
        for profile in list.profiles {
            try deleteMachineBecauseThePersonAsked(profile.id)
        }
        removeDownloads()
        try? FileManager.default.removeItem(at: library.baseDirectory)
        try? FileManager.default.removeItem(at: library.baseInfoURL)
        // What is left are folders no profile names any more: nothing can start them.
        try? FileManager.default.removeItem(at: library.root)
        setupError = nil
        offeredImage = nil
        setup = library.setupState()
        measureDisk()
    }

    /// The tools' installer and the boot script, into the folder the base shares with this Mac
    /// (Resources/VMGuest): the person opens the installer from it in the guest's Finder.
    private func placeGuestTools() throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("VMGuest", isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: source.path), !names.isEmpty else {
            throw VMHelperProcess.Failure.noHelper
        }
        let share = library.base.share
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        for name in names where !name.hasPrefix(".") {
            let target = share.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: target)
            let runs = name.hasSuffix(".command") || name.hasSuffix(".sh")
            try FileManager.default.setAttributes([.posixPermissions: runs ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
        // What an earlier setup said is not this one's.
        try? FileManager.default.removeItem(at: library.base.status)
    }

    // MARK: Profiles

    enum Refusal: LocalizedError {
        /// The stored list did not read: nothing is written over it.
        case listUnreadable
        case machineRunning
        /// A machine runs, or the setup is at work: not while everything is removed.
        case busy

        var errorDescription: String? {
            switch self {
            case .listUnreadable: return L("vm.error.listUnreadable")
            case .machineRunning: return L("vm.error.deleteRunning")
            case .busy: return L("vm.error.busy")
            }
        }
    }

    /// Saves a new profile or a changed one; throws what is wrong with it (`VMProfile.validate`).
    func save(_ profile: VMProfile) throws {
        guard loadError == nil else { throw Refusal.listUnreadable }
        var updated = list
        try updated.save(profile)
        try updated.save(to: vault)
        list = updated
    }

    /// Deletes a profile's machine — its disk, with everything in its macOS — and the profile.
    /// Only from the person's Delete, confirmed (scripts/check_deletion_paths.py); never while the
    /// machine runs.
    func deleteMachineBecauseThePersonAsked(_ id: UUID) throws {
        guard running[id] == nil, helpers[id] == nil else { throw Refusal.machineRunning }
        guard loadError == nil else { throw Refusal.listUnreadable }
        var updated = list
        updated.remove(id)
        try updated.save(to: vault)
        list = updated
        try? FileManager.default.removeItem(at: library.machineDirectory(for: id))
        problems[id] = nil
        exits[id] = nil
        guests[id] = nil
        diskUsage[id] = nil
    }

    // MARK: Running

    /// Starts the profile's machine: its proxy is checked first (a machine whose proxy is down
    /// would reach nothing), its time zone and language follow where the proxy comes out when the
    /// profile says so, and the guest is told them through its shared folder.
    func start(_ id: UUID) {
        // A machine that has its disk starts without the base (the base may have been removed to
        // free the disk); one not made yet needs it, to be cloned from.
        guard running[id] == nil, helpers[id] == nil, let profile = list.profile(id) else { return }
        guard isReady || library.machine(for: id).isComplete else {
            problems[id] = L("vm.error.noBase")
            return
        }
        guard isAllowed() else {
            problems[id] = L("vm.error.notInPlan")
            return
        }
        guard runningCount < VMRequirements.runningLimit else {
            problems[id] = L("vm.error.limit")
            return
        }
        // A machine not made yet is a clone of the base's disk: not of one the base is writing now.
        if activity == .guestSetup, !library.machine(for: id).isComplete {
            problems[id] = L("vm.error.baseOpen")
            return
        }
        problems[id] = nil
        guard let proxy = profile.proxy else {
            running[id] = Running(phase: .starting)
            return launch(profile)
        }
        running[id] = Running(phase: .checkingProxy)
        Task { [weak self] in
            let check = await ProxyChecker.check(proxy)
            guard let self, self.running[id]?.phase == .checkingProxy, var profile = self.list.profile(id) else { return }
            self.exits[id] = check
            guard check.isAlive else {
                self.running[id] = nil
                self.problems[id] = L("vm.error.proxyDown")
                return
            }
            let followed = profile.followingProxy(check: check)
            if followed != profile {
                profile = followed
                try? self.save(profile)
            }
            // The limit again: another machine may have started while the proxy was asked.
            guard self.runningCount < VMRequirements.runningLimit else {
                self.running[id] = nil
                self.problems[id] = L("vm.error.limit")
                return
            }
            self.running[id]?.phase = .starting
            self.launch(profile)
        }
    }

    private func launch(_ profile: VMProfile) {
        let id = profile.id
        let files = library.machine(for: id)
        do {
            excludeFromBackups()
            try FileManager.default.createDirectory(at: files.share, withIntermediateDirectories: true)
            try Data(VMGuestSettings(profile: profile).text.utf8).write(to: files.settings, options: .atomic)
            let helper = VMHelperProcess(onEvent: { [weak self] event in self?.take(event, of: id) },
                                         onEnd: { [weak self] failure in self?.ended(id, failure: failure) })
            try helper.start(VMHelperRequest.run(profile: profile, library: library,
                                                 hostCores: ProcessInfo.processInfo.activeProcessorCount, texts: Self.helperTexts))
            helpers[id] = helper
            var updated = list
            updated.markLaunched(id)
            if (try? updated.save(to: vault)) != nil { list = updated }
        } catch {
            running[id] = nil
            problems[id] = errorText(error)
        }
    }

    private func take(_ event: VMHelperEvent, of id: UUID) {
        switch event.kind {
        case .started:
            if running[id]?.phase == .starting { running[id]?.phase = .running }
        case .traffic:
            running[id]?.bytesUp = event.bytesUp ?? 0
            running[id]?.bytesDown = event.bytesDown ?? 0
            running[id]?.connections = event.connections ?? 0
        default:
            break
        }
    }

    private func ended(_ id: UUID, failure: String?) {
        helpers[id] = nil
        running[id] = nil
        if let failure { problems[id] = failure }
        readGuestStatus(of: id)
        measureDisk()
    }

    /// Shuts the machine's macOS down as its own menu would.
    func stop(_ id: UUID) {
        guard let state = running[id] else { return }
        if state.phase == .checkingProxy {
            running[id] = nil
            return
        }
        running[id]?.phase = .stopping
        helpers[id]?.stop()
    }

    /// Ends the machine now, as pulling a Mac's plug would: for one that does not shut down.
    func forceStop(_ id: UUID) {
        helpers[id]?.kill()
    }

    /// Lock and Quit: every machine is shut down, the setup paused, and this waits until the
    /// helpers have ended — a machine that does not shut down in time is ended.
    func stopAll() async {
        switch activity {
        case .asking?:
            setupRun = nil
            setupHelper?.terminate()
            setupHelper = nil
            activity = nil
        case .downloading?: pauseDownload()
        case .installing?: cancelInstallation()
        case .guestSetup?: closeBase()
        case nil: break
        }
        for id in Array(running.keys) { stop(id) }
        // The helper itself gives a guest a minute to shut down before it ends the machine.
        let patience = Date().addingTimeInterval(75)
        while hasRunning, Date() < patience {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard hasRunning else { return }
        for helper in helpers.values { helper.kill() }
        setupHelper?.kill()
        let end = Date().addingTimeInterval(12)
        while hasRunning, Date() < end {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: What the machines say and take

    private func readGuestStatus(of id: UUID) {
        guard let text = try? String(contentsOf: library.machine(for: id).status, encoding: .utf8) else { return }
        guests[id] = VMGuestStatus(text: text)
    }

    /// What each machine, and the base, takes on disk — counted off the main thread (a sparse
    /// disk's written blocks, not its length).
    func measureDisk() {
        lastMeasure = Date()
        let library = self.library
        let ids = list.profiles.map(\.id)
        let baseID = Self.baseID
        let downloadsID = Self.downloadsID
        Task.detached(priority: .utility) { [weak self] in
            var usage: [UUID: Int64] = [:]
            // A machine's own blocks: what its macOS changed since it was cloned from the base.
            for id in ids { usage[id] = VMLibrary.allocatedSize(of: library.machineDirectory(for: id), ownOnly: true) }
            usage[baseID] = VMLibrary.allocatedSize(of: library.baseDirectory)
            usage[downloadsID] = VMLibrary.allocatedSize(of: library.downloadsDirectory)
            let counted = usage
            await MainActor.run { self?.diskUsage = counted }
        }
    }

    /// Tens of gigabytes that change all the time: not this Mac's backups' to carry.
    private func excludeFromBackups() {
        try? FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        var url = library.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// A download or an installation of hours is not for the Mac's sleep to cut.
    private func holdAwake(_ hold: Bool) {
        if hold, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                          reason: "Setting up virtual machines")
        } else if !hold, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    /// The helper's few words, in the person's language (it has no strings of its own).
    static var helperTexts: [String: String] {
        ["stop": L("vm.window.stop"), "stopQuestion": L("vm.window.stopQuestion"), "stopDetail": L("vm.window.stopDetail"),
         "stopNow": L("vm.window.stopNow"), "cancel": L("common.cancel"), "stopping": L("vm.window.stopping")]
    }
}
