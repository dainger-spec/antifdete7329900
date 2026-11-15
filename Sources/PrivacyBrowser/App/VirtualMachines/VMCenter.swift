import BrowserCore
import Combine
import Foundation
import MachineCover
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
        /// A machine without a proxy whose connections are not being made: why.
        var trouble: VMNetworkTrouble?
        /// The same in the helper's own words (a range, an error's name): a technical detail.
        var troubleDetail: String?
        /// Its connections go through the proxy this Mac's network settings name.
        var viaSystemProxy = false
        /// It was woken from a saved state at this start: it is as it was closed.
        var woke = false
        /// Its macOS is being shut down (`shutDown`), not put to sleep.
        var shuttingDown = false
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
    /// The machines put to sleep (instant wake): each has a saved state for its next start.
    @Published private(set) var asleep: Set<UUID> = []
    /// Why a machine with instant wake was started anew at its last start instead of woken.
    @Published private(set) var wakeNotes: [UUID: VMWakeRefusal] = [:]
    /// When each machine's macOS last started anew rather than woken (since unlock): what its
    /// status file said before that is of a macOS that has since shut down (`VMGuestStatus.asOf`).
    private var startedAnew: [UUID: Date] = [:]
    /// Where a running machine's macOS connects, while its network panel is open — the person's
    /// browsing: shown, never kept or logged.
    @Published private(set) var hosts: [UUID: [VMHelperEvent.Host]] = [:]

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
    /// A restore image the person already had, being checked (the helper's `inspect`) and then
    /// taken into the library: the setup's first step says so instead of "downloading".
    @Published private(set) var importingFile = false
    private var importer: VMImageImport?
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
        asleep = Set(list.profiles.map(\.id).filter { library.machine(for: $0).hasSavedState })
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

    /// The room on the library's volume as a machine's start goes by it (`VMStartRoom`), and
    /// whether that volume clones files (APFS does). The room is the larger of the system's two
    /// figures: the one "for important usage" counts what macOS can free at need, and is zero on
    /// volumes that have no such thing (an external disk that is not APFS), where the plain one
    /// is the answer. Nil where the system says neither: nothing is refused on a guess.
    private var startRoom: (free: Int64?, clones: Bool?) {
        var url = library.root
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeAvailableCapacityKey, .volumeSupportsFileCloningKey]) else {
            return (nil, nil)
        }
        let figures: [Int64?] = [values.volumeAvailableCapacityForImportantUsage, values.volumeAvailableCapacity.map { Int64($0) }]
        return (figures.compactMap { $0 }.max(), values.volumeSupportsFileCloning)
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
        let saved = library.downloadState().flatMap { $0.image == image ? $0 : nil }
        activity = .downloading(VMImageDownloader.Progress(have: saved.map { library.downloadedBytes($0) } ?? 0,
                                                           total: saved?.expectedLength, speed: nil))
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
        // A copy of the person's file is called off, not paused: it starts over if chosen again.
        importer?.cancel()
        importer = nil
        importingFile = false
        setupRun = nil
        activity = nil
        holdAwake(false)
        setup = library.setupState()
        measureDisk()
    }

    /// The person chose a restore image they already have (`VMImageImport`): the helper loads it
    /// as the installer would and says which macOS it is and that it runs on this Mac; it is then
    /// cloned or copied into the download's place, and the setup goes on with the installation as
    /// after a download. The person's own file is never moved or changed.
    func useImageFile(_ source: URL) {
        guard activity == nil, Self.availability == .available else { return }
        guard isAllowed() else {
            setupError = L("vm.error.notInPlan")
            return
        }
        switch library.setupState() {
        case .ready, .needsGuestSetup:
            return
        case .none, .downloading, .downloaded:
            break
        }
        if let problem = VMImageImport.problem(with: source) {
            setupError = Self.text(of: problem)
            return
        }
        setupError = nil
        importingFile = true
        let run = beginRun()
        activity = .asking
        var image: VMRestoreImage?
        var known = false
        let helper = VMHelperProcess(onEvent: { event in
            if event.kind == .catalog { image = event.image }
            if event.kind == .failed { known = event.failureKind != nil }
        }, onEnd: { [weak self] failure in
            guard let self, self.setupRun == run else { return }
            self.setupHelper = nil
            guard let image, failure == nil else {
                // A reason the app has words for is a whole sentence, with what to do; the
                // system's own words are said as what is wrong with the file.
                if known, let failure { return self.setupFailed(failure) }
                return self.setupFailed(String(format: L("vm.import.error.notAnImage"), failure ?? L("vm.error.unknown")))
            }
            self.offeredImage = image
            self.takeImage(from: source, run: run)
        })
        start(helper, VMHelperRequest(mode: .inspect, restoreImagePath: source.path))
    }

    private func takeImage(from source: URL, run: UUID) {
        holdAwake(true)
        excludeFromBackups()
        activity = .downloading(VMImageDownloader.Progress(have: 0, total: VMLibrary.fileSize(source), speed: nil))
        let importer = VMImageImport(source: source, library: library, onProgress: { [weak self] progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.setupRun == run else { return }
                    self.activity = .downloading(progress)
                }
            }
        }, onFinish: { [weak self] result in
            let failure: Error?
            if case .failure(let error) = result { failure = error } else { failure = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.setupRun == run else { return }
                    self.importer = nil
                    self.importingFile = false
                    if let failure {
                        return self.setupFailed((failure as? VMImageImport.Problem).map(Self.text(of:)) ?? errorText(failure))
                    }
                    self.measureDisk()
                    self.install()
                }
            }
        })
        self.importer = importer
        importer.start()
    }

    /// What is wrong with a file the person chose, in their language.
    static func text(of problem: VMImageImport.Problem) -> String {
        switch problem {
        case .notAFile: return L("vm.import.error.notAFile")
        case .tooSmall: return L("vm.import.error.tooSmall")
        case .notARestoreImage: return L("vm.import.error.notAZip")
        case .unreadable: return L("vm.import.error.unreadable")
        case .notEnoughSpace(let needed, let free):
            return String(format: L("vm.import.error.space"), VMText.bytes(needed), VMText.bytes(free))
        }
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
        // A machine that is being made right now is a copy of the base's disk: the base is not
        // started — and its disk written — under the copy.
        guard !running.contains(where: { id, state in
            (state.phase == .checkingProxy || state.phase == .starting) && !library.machine(for: id).isComplete
        }) else {
            setupError = L("vm.error.machineStarting")
            return
        }
        setupError = nil
        do {
            try placeGuestTools()
        } catch {
            setupError = errorText(error)
            return
        }
        // A base not set up yet says in its own window what is left to do in it.
        var baseTexts = Self.helperTexts
        if info.stage != .ready {
            baseTexts["guide"] = L("vm.base.guide")
        }
        let run = beginRun()
        activity = .guestSetup
        let helper = VMHelperProcess(onEvent: { _ in }, onEnd: { [weak self] failure in
            guard let self, self.setupRun == run else { return }
            self.setupHelper = nil
            self.activity = nil
            if let failure { self.setupError = failure }
            // The tools' installer says in the shared folder that it has done its work — read off
            // the main thread, as a file the guest may have made anything of (`VMShareFile`).
            let statusURL = self.library.base.status
            Task { [weak self] in
                let read = await Task.detached(priority: .userInitiated) { VMGuestStatus.read(from: statusURL) }.value
                guard let self else { return }
                self.finishBaseSetup(info, status: self.accepted(read))
            }
        })
        start(helper, VMHelperRequest(mode: .run, machineDirectory: library.baseDirectory.path,
                                      cores: VMRequirements.cores(hostCores: ProcessInfo.processInfo.activeProcessorCount),
                                      memoryBytes: Int64(Self.setupMemoryGB) * VMRequirements.gibibyte,
                                      macAddress: VMProfile.randomMACAddress(), network: network,
                                      windowTitle: L("vm.base.window"), texts: baseTexts))
    }

    /// After the base's window has closed: the base is set up when its installer said so.
    private func finishBaseSetup(_ info: VMBaseInfo, status: VMGuestStatus?) {
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
        importer?.cancel()
        importer = nil
        importingFile = false
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
            let runs = name.hasSuffix(".command") || name.hasSuffix(".sh")
            try Self.placeFresh(source.appendingPathComponent(name), at: share.appendingPathComponent(name), runs: runs)
        }
        // What an earlier setup said is not this one's.
        try? FileManager.default.removeItem(at: library.base.status)
    }

    /// One of the tools, into a folder the guest reads: its bytes in a new file, not a copy of the
    /// file. A copy keeps the file's extended attributes, and in a Lumen downloaded from the
    /// internet those may be the download's quarantine — on which macOS in the machine would
    /// refuse to run "Install Lumen Tools" (or ask about it), with nothing of it from the internet.
    static func placeFresh(_ source: URL, at target: URL, runs: Bool) throws {
        let data = try Data(contentsOf: source)
        try? FileManager.default.removeItem(at: target)
        guard FileManager.default.createFile(atPath: target.path, contents: data,
                                             attributes: [.posixPermissions: runs ? 0o755 : 0o644]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
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
        asleep.remove(id)
        wakeNotes[id] = nil
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
        // Not onto a disk that is nearly full — a machine's macOS writes all the time, and writes
        // that fail are a failing disk to it — and not a copy of the base's whole disk where
        // there is no room for one: said now, with the numbers, not after minutes of copying.
        let room = startRoom
        let isMade = library.machine(for: id).isComplete
        // What a whole copy would take is counted only where one would be made.
        let baseDiskBytes = !isMade && room.clones == false ? VMLibrary.allocatedSize(of: library.baseDirectory) : 0
        if let problem = VMStartRoom.problem(free: room.free, isMade: isMade, volumeClones: room.clones, baseDiskBytes: baseDiskBytes) {
            problems[id] = Self.roomText(of: problem)
            return
        }
        problems[id] = nil
        wakeNotes[id] = nil
        guard let proxy = profile.proxy else {
            guard profile.asksWhereTheConnectionComesOut else {
                running[id] = Running(phase: .starting)
                return launch(profile)
            }
            // The person's choice for this machine: its time zone and language are those of the
            // place this Mac's own connection comes out at (its VPN, when one is on) — asked now,
            // by this Mac, as a profile without a proxy asks. No answer does not keep the machine
            // from starting: it keeps the time zone and language it had, and the row says so.
            running[id] = Running(phase: .checkingProxy)
            Task { [weak self] in
                let userAgent = ProfileConfiguration().userAgent(hostSafariVersion: HostSafari.version)
                let exit = ProxyChecker.result(of: await ProxyGeoLookup.lookUp(proxy: nil, userAgent: userAgent,
                                                                              timeout: ProxyChecker.timeout))
                guard let self, self.running[id]?.phase == .checkingProxy, var profile = self.list.profile(id) else { return }
                if exit.isAlive, exit.countryCode != nil {
                    self.exits[id] = exit
                    let followed = profile.followingConnection(exit: exit)
                    if followed != profile {
                        profile = followed
                        try? self.save(profile)
                    }
                } else {
                    self.problems[id] = L("vm.note.connectionUnknown")
                }
                guard self.runningCount < VMRequirements.runningLimit else {
                    self.running[id] = nil
                    self.problems[id] = L("vm.error.limit")
                    return
                }
                if self.activity == .guestSetup, !self.library.machine(for: id).isComplete {
                    self.running[id] = nil
                    self.problems[id] = L("vm.error.baseOpen")
                    return
                }
                self.running[id]?.phase = .starting
                self.launch(profile)
            }
            return
        }
        running[id] = Running(phase: .checkingProxy)
        Task { [weak self] in
            let check = await VMCenter.checkProxy(proxy)
            guard let self, self.running[id]?.phase == .checkingProxy, var profile = self.list.profile(id) else { return }
            self.exits[id] = check
            guard check.isAlive else {
                self.running[id] = nil
                self.problems[id] = VMCenter.proxyProblem(proxy, check: check)
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
            // And the base again: it may have been opened meanwhile, and a machine not made yet
            // would be a copy of a disk the base is writing.
            if self.activity == .guestSetup, !self.library.machine(for: id).isComplete {
                self.running[id] = nil
                self.problems[id] = L("vm.error.baseOpen")
                return
            }
            self.running[id]?.phase = .starting
            self.launch(profile)
        }
    }

    /// The check of a machine's proxy before its start: does it work, where does it come out, and
    /// its time zone — and nothing a machine does not use. The Proxies section's check also sets
    /// up two more tunnels for a steady latency, which the machines' list does not show, and waits
    /// for a SOCKS5 proxy's UDP (up to nine seconds where the proxy takes the association and
    /// carries nothing, then a request for where it leaves from) — and UDP never leaves a machine
    /// (docs/VM.md). A start, and a wake above all, is shorter by those.
    static func checkProxy(_ proxy: ProxySettings) async -> ProxyCheckResult {
        await ProxyChecker.check(proxy, latencySamples: 1, triesUDP: false)
    }

    /// Why a machine whose proxy did not pass its check was not started: what the check found, in
    /// the words the Proxies section has for it (`ProxyReport`) — a login the proxy rejects is not
    /// a proxy that is down, and asks something else of the person — and what to do about it.
    static func proxyProblem(_ proxy: ProxySettings, check: ProxyCheckResult) -> String {
        let report = ProxyReport(proxy: proxy, check: check)
        guard let explanation = report.explanation else { return L("vm.error.proxyDown") }
        return ([L("vm.error.proxyFailed"), explanation] + [report.advice].compactMap { $0 }).joined(separator: " ")
    }

    private func launch(_ profile: VMProfile) {
        let id = profile.id
        let files = library.machine(for: id)
        do {
            excludeFromBackups()
            try FileManager.default.createDirectory(at: files.share, withIntermediateDirectories: true)
            // The guest writes the share too: what it left in the settings' place that is not a
            // plain file (a link) goes, itself, before the settings are written.
            if !VMShareFile.isRegularFile(files.settings) { try? FileManager.default.removeItem(at: files.settings) }
            try Data(VMGuestSettings(profile: profile).text.utf8).write(to: files.settings, options: .atomic)
            // The boot script as this Lumen has it: a machine whose own is older takes it, so that a
            // later Lumen's settings need no visit to the base system. From the tools' folder, which
            // the machine is given read-only (tools 7 on take it from there only); and, for a
            // machine whose script is older than that, in the shared folder, where those look.
            if let script = Bundle.main.resourceURL?.appendingPathComponent("VMGuest/" + VMGuestSettings.scriptFileName),
               FileManager.default.fileExists(atPath: script.path) {
                try? FileManager.default.createDirectory(at: files.tools, withIntermediateDirectories: true)
                for folder in [files.tools, files.share] {
                    try? Self.placeFresh(script, at: folder.appendingPathComponent(VMGuestSettings.scriptFileName), runs: true)
                }
            }
            if profile.lumenWallpaper {
                // Lumen's desktop picture for this machine's screen, drawn once and left where the
                // boot script looks — beside the start, which takes the guest far longer.
                let display = profile.display, share = files.share
                Task.detached(priority: .userInitiated) { VMWallpaper.place(for: display, in: share) }
            }
            let helper = VMHelperProcess(onEvent: { [weak self] event in self?.take(event, of: id) },
                                         onEnd: { [weak self] failure in self?.ended(id, failure: failure) })
            var request = VMHelperRequest.run(profile: profile, library: library,
                                              hostCores: ProcessInfo.processInfo.activeProcessorCount, texts: Self.helperTexts)
            // The app's own "animations off": the start's cover moves nothing, as under Reduce Motion.
            if !AppearancePreferences.animationsEnabled { request.reducesMotion = true }
            try helper.start(request)
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
            running[id]?.woke = event.woke == true
            wakeNotes[id] = event.notWoken.flatMap(VMWakeRefusal.init(rawValue:))
            // Started anew, its macOS has what the one before wrote for "the next start"; woken,
            // it is the macOS that wrote it.
            if event.woke == true {
                startedAnew[id] = nil
            } else {
                let now = Date()
                startedAnew[id] = now
                guests[id] = guests[id]?.asOf(start: now, written: nil)
            }
            // Woken or started anew, the saved state is used up.
            asleep.remove(id)
            // What the guest says of itself — its system, its tools, whether Lumen's picture is on
            // its desktop — is read while it runs too, not only when it has stopped.
            for delay in [25.0, 60, 120, 240] {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, self.running[id] != nil else { return }
                    self.readGuestStatus(of: id)
                }
            }
        case .traffic:
            running[id]?.bytesUp = event.bytesUp ?? 0
            running[id]?.bytesDown = event.bytesDown ?? 0
            running[id]?.connections = event.connections ?? 0
            running[id]?.trouble = event.trouble.flatMap(VMNetworkTrouble.init(rawValue:))
            running[id]?.troubleDetail = event.troubleDetail
            running[id]?.viaSystemProxy = event.viaSystemProxy ?? false
        case .hosts:
            // Only while the panel asks: an answer that comes after it was closed is dropped.
            if hosts[id] != nil { hosts[id] = event.hosts ?? [] }
        case .notKept:
            // Instant wake could not keep the machine as it was — its state was not saved: its
            // macOS is shut down instead, which the row says from now on ("shutting down…", not
            // "saving…"), and why stays in the row until the machine's next start.
            running[id]?.shuttingDown = true
            problems[id] = Self.notKeptText(kind: event.failureKind, message: event.message)
        default:
            break
        }
    }

    private func ended(_ id: UUID, failure: String?) {
        helpers[id] = nil
        running[id] = nil
        hosts[id] = nil
        if let failure { problems[id] = failure }
        if library.machine(for: id).hasSavedState { asleep.insert(id) } else { asleep.remove(id) }
        readGuestStatus(of: id)
        measureDisk()
    }

    /// Shuts the machine's macOS down as its own menu would, whatever its instant wake says:
    /// nothing is kept for the next start.
    func shutDown(_ id: UUID) {
        guard let state = running[id], state.phase != .checkingProxy else { return stop(id) }
        running[id]?.phase = .stopping
        running[id]?.shuttingDown = true
        helpers[id]?.send(.shutdown)
    }

    /// The person asked for a machine that sleeps to be started anew: its saved state — what was
    /// open in it — is given up, and its macOS starts as after a shutdown that did not happen.
    func startAnewBecauseThePersonAsked(_ id: UUID) {
        guard running[id] == nil, helpers[id] == nil else { return }
        let files = library.machine(for: id)
        for url in [files.state, files.stateInfo] { try? FileManager.default.removeItem(at: url) }
        asleep.remove(id)
        start(id)
    }

    /// The network panel of a running machine was opened or closed: the helper says where the
    /// machine connects only while it is open.
    func watchNetwork(of id: UUID, _ watching: Bool) {
        if watching {
            guard helpers[id] != nil else { return }
            if hosts[id] == nil { hosts[id] = [] }
            helpers[id]?.send(.hosts(true))
        } else {
            hosts[id] = nil
            helpers[id]?.send(.hosts(false))
        }
    }

    /// Blocks a host for the machine: at once in the running machine, and — written into its
    /// profile — at every later start. Throws what is wrong with the name or the list.
    func block(_ host: String, in id: UUID) throws {
        guard let name = VMProfile.blockedHost(host), var profile = list.profile(id) else {
            throw CoreError.invalidConfiguration("a blocked name must be a host name such as ads.example.com")
        }
        if !profile.blockedHosts.contains(name) {
            profile.blockedHosts.append(name)
            try save(profile)
        }
        helpers[id]?.send(.block(name))
    }

    /// Whether a host is one the machine's profile blocks, or under one.
    func isBlocked(_ host: String, in id: UUID) -> Bool {
        guard let profile = list.profile(id) else { return false }
        return profile.blockedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Puts the front window of the machine's macOS full screen, or back (the key a person would
    /// press for it).
    func toggleGuestFullScreen(_ id: UUID) {
        helpers[id]?.send(.fullScreen)
    }

    /// Closes the machine: with instant wake it is put to sleep as it is; otherwise its macOS is
    /// shut down as its own menu would.
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
            importingFile = false
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

    /// What a machine's guest says of itself (`VMGuestStatus`), read off the main thread as a file
    /// the guest may have made anything of: a link, a pipe or a file too large is ignored, and the
    /// log says of it its kind only.
    private func readGuestStatus(of id: UUID) {
        let url = library.machine(for: id).status
        Task { [weak self] in
            // And when it was written — read first, so that a file put in place meanwhile is taken
            // as older, not newer: one from before the machine's macOS last started anew.
            let (read, written) = await Task.detached(priority: .utility) { () -> (Result<VMGuestStatus, VMShareFile.Refusal>, Date?) in
                let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                return (VMGuestStatus.read(from: url), written)
            }.value
            guard let self, let status = self.accepted(read) else { return }
            self.guests[id] = status.asOf(start: self.startedAnew[id], written: written)
        }
    }

    /// The status, or nil — with a word in the log when the file was there and was not one to read.
    private func accepted(_ read: Result<VMGuestStatus, VMShareFile.Refusal>) -> VMGuestStatus? {
        switch read {
        case .success(let status):
            return status
        case .failure(let refusal):
            if refusal != .missing {
                log.notice("A machine's status file was not read: \(refusal.rawValue, privacy: .public)")
            }
            return nil
        }
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

    /// What a failure the helper reports is said as. For a kind the app has words for
    /// (`VMFailureKind`): those words — in the person's language, with what to do — and under
    /// them the system's own, as a technical detail. For any other: the system's words alone, as
    /// they always were.
    static func failureText(kind: VMFailureKind?, message: String?) -> String {
        let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let kind else { return detail.isEmpty ? L("vm.error.unknown") : detail }
        let words = L("vm.failure.\(kind.rawValue)")
        return detail.isEmpty ? words : words + "\n" + String(format: L("vm.row.trouble.detail"), detail)
    }

    /// What the row says of a machine with instant wake that was shut down instead of kept as it
    /// was, because its state could not be saved: a full disk by name, anything else with the
    /// system's words for it.
    static func notKeptText(kind: VMFailureKind?, message: String?) -> String {
        if kind == .noRoom { return L("vm.row.notKept.noRoom") }
        let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? L("vm.row.notKept") : L("vm.row.notKept") + "\n" + String(format: L("vm.row.trouble.detail"), detail)
    }

    /// Why a machine is not started onto a disk that is nearly full (`VMStartRoom`), with the
    /// numbers.
    static func roomText(of problem: VMStartRoom.Problem) -> String {
        switch problem {
        case .full(let needed, let free):
            return String(format: L("vm.error.diskFull"), VMText.bytes(free), VMText.bytes(needed))
        case .copy(let needed, let free):
            return String(format: L("vm.error.diskCopy"), VMText.bytes(needed), VMText.bytes(free))
        }
    }

    /// The helper's few words, in the person's language (it has no strings of its own).
    static var helperTexts: [String: String] {
        ["stop": L("vm.window.stop"), "stopQuestion": L("vm.window.stopQuestion"), "stopDetail": L("vm.window.stopDetail"),
         "stopNow": L("vm.window.stopNow"), "cancel": L("common.cancel"), "stopping": L("vm.window.stopping"),
         "sleep": L("vm.window.sleep"), "sleeping": L("vm.window.sleeping"),
         "guestFullScreen": L("vm.window.guestFullScreen"), "nextStartQuestion": L("vm.window.nextStartQuestion"),
         "nextStartDetail": L("vm.window.nextStartDetail"), "keep": L("vm.window.keep")]
            .merging(VMNetworkTrouble.allCases.map { ("trouble." + $0.rawValue, L("vm.window.trouble")) }) { first, _ in first }
            .merging(coverTexts) { first, _ in first }
    }

    /// The words of the cover over a machine's start (MachineCover), as its request carries them.
    static var coverTexts: [String: String] {
        [MachineCoverTexts.captionKey: L("vm.cover.caption"), MachineCoverTexts.key(.boot): L("vm.cover.boot"),
         MachineCoverTexts.key(.signin): L("vm.cover.signin"), MachineCoverTexts.key(.locale): L("vm.cover.locale"),
         MachineCoverTexts.key(.look): L("vm.cover.look"), MachineCoverTexts.key(.wallpaper): L("vm.cover.wallpaper"),
         MachineCoverTexts.key(.safari): L("vm.cover.safari"), MachineCoverTexts.longerKey: L("vm.cover.longer"),
         MachineCoverTexts.showKey: L("vm.cover.show"), MachineCoverTexts.timedOutKey: L("vm.cover.timedOut"),
         MachineCoverTexts.labelKey: L("vm.cover.label")]
    }
}
