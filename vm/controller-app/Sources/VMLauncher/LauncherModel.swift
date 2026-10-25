import AppKit
import Foundation
import VMControllerCore

struct LogLine: Identifiable, Equatable {
    enum Kind { case info, output, error }

    let id: Int
    let text: String
    let kind: Kind
}

/// What the "Tart is missing" panel can offer.
struct TartHelp: Equatable {
    let brewPath: String?
}

enum LaunchFailure: Error, Equatable {
    case cancelled
    case failed(String)
}

/// Drives a launch: Tart → image → VM → agent/Safari, and publishes progress.
///
/// The VM runs inside the app (EmbeddedVM, shown in the browser window) when
/// it can; otherwise — the setting is off, the build lacks the virtualization
/// entitlement, the VM is a stacked clone — `tart run` shows it in Tart's own
/// window. Either way tart-prototype.sh does the in-guest setup (proxy,
/// identity, kiosk, agent) and opens the page.
@MainActor
final class LauncherModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running   // a step is in progress
        case needsTart // waiting for the user to pick how to install Tart
        case ready     // Safari is open in the VM, which keeps running
        case stopping  // cancelling, or stopping the VM
        case finished  // the VM was stopped
        case cancelled
        case failed
    }

    /// Where the running VM's screen is.
    enum Display: Equatable {
        case none
        /// In the app's browser window.
        case embedded
        /// In a window of Tart's own (fallback / setting off).
        case tartWindow
    }

    @Published var urlText: String
    @Published private(set) var progress = LaunchProgress()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText = "Выберите профиль и нажмите «Открыть браузер»"
    @Published var errorMessage: String?
    @Published private(set) var urlError: String?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var tartHelp: TartHelp?
    /// Run the VM inside the app's browser window (default). Off: `tart run`
    /// with Tart's own window — for troubleshooting.
    @Published var useEmbeddedWindow: Bool {
        didSet { UserDefaults.standard.set(useEmbeddedWindow, forKey: "useEmbeddedWindow") }
    }
    @Published private(set) var embeddedVM: EmbeddedVM?
    @Published private(set) var display: Display = .none
    /// Safari is open: the browser window shows the VM instead of the splash.
    @Published private(set) var browserReady = false

    let profileStore = ProfileStore()
    let fileLog = FileLog()
    /// Saved profiles, for the window's list (the menu bar reads the store too).
    @Published var profiles: [Profile] = []
    /// The profile being launched, or nil for the quick launch.
    @Published private(set) var activeProfile: Profile?
    /// The VM/base the current launch targets — a profile's, or the default.
    var vmName: String { activeProfile?.vmName ?? LauncherDefaults.vmName }
    var baseImage: String { activeProfile?.baseImage ?? LauncherDefaults.baseImage }

    let baseEnvironment: [String: String]
    let statusCache = SetupStatusCache()
    private var pipeline: Task<Void, Never>?
    private var activeProcess: GroupProcess?
    private var downloader: TartDownloader?
    private(set) var tartPath: String?
    private var tartVersion: String?
    private var targetURL: String?
    private var cancelRequested = false
    private var scriptParser = ScriptOutputParser()
    private var scriptError: String?
    private var imageStep = "Загрузка"
    private(set) var lastOutputLine: String?
    private var nextLogID = 0
    private var sentCookies = false
    private var cookieImportFailed = false
    private var vmStopMessage: String?

    // Base image and host resources (LauncherModel+Library.swift).
    @Published var resource: ResourceReport?
    @Published var baseUpdateInProgress = false
    @Published var baseUpdateDetail = ""
    /// Whether the registry has a newer base than the one last pulled here.
    @Published var baseUpdateState: BaseUpdateState = .unknown
    @Published var baseUpdateChecking = false

    /// No cached environment check yet → treat as a first run (show onboarding).
    let isFirstRun: Bool

    init() {
        urlText = UserDefaults.standard.string(forKey: "lastURL") ?? "https://browserleaks.com"
        useEmbeddedWindow = UserDefaults.standard.object(forKey: "useEmbeddedWindow") as? Bool ?? true
        var environment = ProcessInfo.processInfo.environment
        // A Finder-launched app has PATH=/usr/bin:/bin:/usr/sbin:/sbin; Homebrew's tart lives elsewhere.
        environment["PATH"] = LauncherEnvironment.searchPath(environment["PATH"])
        baseEnvironment = environment
        isFirstRun = statusCache.load() == nil
        profiles = (try? profileStore.list()) ?? []
    }

    // MARK: - State for the view

    var isBusy: Bool { phase == .running || phase == .stopping }
    var canStart: Bool { !isBusy && phase != .ready && !baseUpdateInProgress }
    var canCancel: Bool { phase == .running }
    var hasActiveWork: Bool { isBusy || phase == .ready }
    var logText: String { log.map(\.text).joined(separator: "\n") }

    /// The benefit cards shown on the setup splash.
    var benefitCards: [BenefitCard] { CarouselDeck.cards }

    /// Whether `profile` (nil = quick launch) is the one launching or open.
    func isActive(_ profile: Profile?) -> Bool {
        hasActiveWork && activeProfile?.id == profile?.id
    }

    var browserTitle: String {
        activeProfile.map { "\($0.name) — \(Brand.name)" } ?? Brand.name
    }

    /// The step in plain words, for the splash.
    var currentStepTitle: String {
        if phase == .ready { return "Готово" }
        return (progress.current ?? progress.furthest ?? .tart).title
    }

    /// The image download's own fraction, when that is what's running.
    var downloadFraction: Double? {
        progress.current == .image ? progress[.image].progress : nil
    }

    // MARK: - Actions

    /// The quick launch: the default VM, direct internet, the URL field.
    /// True if a launch started (the caller then opens the browser window).
    @discardableResult
    func start() -> Bool {
        guard canStart else { return false }
        guard let url = URLInput.normalize(urlText) else {
            urlError = "Нужен адрес вида https://example.com"
            return false
        }
        activeProfile = nil
        urlError = nil
        urlText = url
        UserDefaults.standard.set(url, forKey: "lastURL")
        prepareLaunch(url: url)
        appendLog("Запуск: \(url)", .info)
        run { try await self.launch(url: url, knownTart: nil) }
        return true
    }

    /// Launch a saved profile: its own VM, its network mode, identity and
    /// cookies, at `url` (or its last URL).
    @discardableResult
    func start(profile: Profile, url requested: String? = nil) -> Bool {
        guard canStart else { return false }
        // Fresh from the store; a profile renamed before VM names were pinned
        // gets its VM back.
        let vms = LauncherEnvironment.tartVMsDirectory()
        let profile = (try? profileStore.adoptOrphanedVM(profile.id, vmsDirectory: vms)) ?? profile
        if let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty {
            guard URLInput.normalize(requested) != nil else {
                urlError = "Нужен адрес вида https://example.com"
                return false
            }
        }
        let url = URLInput.normalize(requested ?? "") ?? URLInput.normalize(profile.lastURL ?? "")
            ?? "https://browserleaks.com"
        activeProfile = profile
        urlError = nil
        prepareLaunch(url: url)
        appendLog("Запуск профиля «\(profile.name)» [\(profile.vmName)]: \(url)", .info)
        run { try await self.launch(url: url, knownTart: nil) }
        return true
    }

    private func prepareLaunch(url: String) {
        targetURL = url
        progress = LaunchProgress()
        tartHelp = nil
        browserReady = false
        display = .none
        vmStopMessage = nil
    }

    /// "Отмена" during a launch, or "Остановить" once Safari is open.
    func cancel() {
        guard phase == .running || phase == .ready else { return }
        let stoppingVM = phase == .ready || (progress.furthest ?? .tart) >= .vm
        cancelRequested = true
        phase = .stopping
        setStatus(stoppingVM ? "Остановка…" : "Отмена…")
        appendLog(stoppingVM ? "Остановка VM по запросу" : "Отмена по запросу", .info)
        downloader?.cancel()
        if let process = activeProcess {
            Task { await self.terminate(process, stoppingVM: stoppingVM) }
        } else if let vm = embeddedVM {
            Task { await vm.stop() }
        }
    }

    /// The browser window was closed: closing it stops that profile.
    func browserWindowClosed() {
        if phase == .running || phase == .ready { cancel() }
    }

    func downloadTart() {
        guard phase == .needsTart, let url = targetURL else { return }
        tartHelp = nil
        run {
            let path = try await self.downloadAndInstallTart()
            try await self.launch(url: url, knownTart: path)
        }
    }

    func installTartWithHomebrew() {
        guard phase == .needsTart, let brew = tartHelp?.brewPath, let url = targetURL else { return }
        tartHelp = nil
        run {
            let path = try await self.installWithHomebrew(brew: brew)
            try await self.launch(url: url, knownTart: path)
        }
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    /// Stops the VM and any running step; used when the app quits.
    func shutdown() async {
        guard hasActiveWork else { return }
        if phase == .running || phase == .ready { cancel() }
        let task = pipeline
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task?.value }
            group.addTask { try? await Task.sleep(nanoseconds: 90 * 1_000_000_000) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Pipeline

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        cancelRequested = false
        errorMessage = nil
        phase = .running
        pipeline = Task { @MainActor in
            do {
                try await body()
                if self.cancelRequested {
                    self.finishCancelled()
                } else if self.phase == .running {
                    self.phase = .idle
                }
            } catch {
                self.handle(error)
            }
            self.embeddedVM = nil
            self.display = .none
            self.browserReady = false
            await self.refreshResources()
        }
    }

    private func launch(url: String, knownTart: String?) async throws {
        guard let tart = try await checkTart(known: knownTart) else { return } // waits for the user
        try await ensureImage(tart: tart)
        try await runScript(tart: tart, url: url)
    }

    private func checkTart(known: String?) async throws -> String? {
        progress.start(.tart, detail: "Проверка компонентов…")
        setStatus("Подготовка…")
        guard HostInfo.isAppleSilicon else {
            throw LaunchFailure.failed("Нужен Mac с Apple Silicon (M1 и новее): только он запускает macOS в виртуальной машине.")
        }
        let searchPath = baseEnvironment["PATH"] ?? ""
        guard let path = known ?? TartSetup.locate(searchPath: searchPath) else {
            progress.attention(.tart, detail: "Нужен компонент виртуализации Tart")
            tartHelp = TartHelp(brewPath: LauncherEnvironment.findExecutable("brew", searchPath: searchPath))
            phase = .needsTart
            setStatus("Нужно установить компонент виртуализации")
            appendLog("tart не найден ни в PATH (\(searchPath)), ни в \(TartSetup.managedBinary.path)", .error)
            return nil
        }
        let version = try await GroupProcess.run(path, ["--version"], environment: baseEnvironment, timeout: 30)
        try checkCancelled()
        guard version.code == 0 else {
            throw LaunchFailure.failed("Компонент виртуализации (tart) не запускается: \(version.lines.last ?? "нет вывода")")
        }
        tartPath = path
        let versionText = version.lines.last ?? "?"
        tartVersion = versionText
        progress.finish(.tart, detail: "Готово")
        appendLog("tart \(versionText): \(path)", .info)
        return path
    }

    /// Remember the environment check so the next launch can show "ready" fast
    /// (SetupStatusCache); it's only a hint — the next launch revalidates.
    private func saveSetupStatus(imagePresent: Bool) {
        statusCache.save(SetupStatus(tartPath: tartPath, tartVersion: tartVersion,
                                     baseImage: baseImage, baseImagePresent: imagePresent))
    }

    private func ensureImage(tart: String) async throws {
        progress.start(.image, detail: "Проверка…")
        setStatus("Проверка системы…")
        let list = try await GroupProcess.run(tart, ["list"], environment: baseEnvironment, timeout: 60)
        try checkCancelled()
        guard list.code == 0 else {
            throw LaunchFailure.failed("Не удалось получить список VM: \(list.lines.last ?? "нет вывода")")
        }
        if TartOutput.vmListContains(list.lines.joined(separator: "\n"), name: vmName) {
            progress.finish(.image, detail: "Готово")
            saveSetupStatus(imagePresent: true)
            return
        }

        if let free = HostInfo.availableDiskBytes(), free < 60_000_000_000 {
            appendLog("Свободно \(Self.formatBytes(free)); образу macOS нужно около 50 ГБ", .error)
        }
        imageStep = "Загрузка macOS"
        progress.update(.image, detail: "Загрузка macOS…")
        setStatus(activeProfile == nil ? "Загрузка macOS (около 25 ГБ, один раз)…"
                                       : "Создание системы профиля…")
        appendLog("tart clone \(baseImage) \(vmName)", .info)
        let code = try await stream(tart, ["clone", baseImage, vmName]) { [weak self] line in
            self?.handleCloneLine(line)
        }
        try checkCancelled()
        guard code == 0 else {
            throw LaunchFailure.failed("Не удалось загрузить macOS: \(lastOutputLine ?? "код \(code)")")
        }
        try await giveNewProfileItsOwnIdentity(tart: tart)
        progress.finish(.image, detail: "Готово")
        saveSetupStatus(imagePresent: true)
    }

    /// Right after cloning, before the first boot: a serial number and MAC of
    /// its own, so this profile isn't the same "Mac" as every other one.
    private func giveNewProfileItsOwnIdentity(tart: String) async throws {
        guard let profile = activeProfile else { return }
        let result = try await GroupProcess.run(tart, ProfilePlan.uniqueIdentity(profile),
                                                environment: baseEnvironment, timeout: 60)
        if result.code == 0 {
            activeProfile = try? profileStore.update(profile.id) { $0.uniqueIdentity = true }
            reloadProfiles()
            appendLog("Профилю «\(profile.name)» выдан собственный серийный номер и MAC", .info)
        } else {
            appendLog("Не удалось сделать профиль уникальным (tart set): \(result.lines.last ?? "?")", .error)
        }
    }

    private func handleCloneLine(_ line: String) {
        if let fraction = TartOutput.percent(in: line) {
            let percent = Int((fraction * 100).rounded(.down))
            progress.update(.image, detail: "\(imageStep): \(percent)%", progress: fraction)
            setStatus("Загрузка macOS: \(percent)%")
        } else if TartOutput.label(in: line) != nil {
            progress.update(.image, detail: imageStep)
        }
    }

    private func runScript(tart: String, url: String) async throws {
        try checkCancelled()
        let candidates = LauncherEnvironment.scriptCandidates(
            environment: baseEnvironment, resourceDirectory: Bundle.main.resourceURL,
            currentDirectory: FileManager.default.currentDirectoryPath,
            executablePath: CommandLine.arguments[0])
        guard let script = LauncherEnvironment.locateScript(in: candidates) else {
            throw LaunchFailure.failed("Не найден tart-prototype.sh. Соберите приложение через scripts/build-app.sh "
                + "или укажите путь в переменной PB_TART_SCRIPT.")
        }
        let missing = LauncherEnvironment.missingAgentFiles(forScript: script)
        guard missing.isEmpty else {
            throw LaunchFailure.failed("Рядом со скриптом нет файлов агента: \(missing.joined(separator: ", "))")
        }
        let askPass = try LauncherEnvironment.writeAskPass(in: TartSetup.supportDirectory)

        var network: NetworkPolicy = .openNAT
        var cookiesFile: String?
        var proxyURL: String?
        var identity: LauncherEnvironment.GuestIdentity?
        if let profile = activeProfile {
            network = profile.networkPolicy
            proxyURL = profile.guestProxy
            identity = .init(profile: profile)
            if profile.network == .proxy && proxyURL == nil {
                appendLog("Прокси профиля не задан IP-адресом: профиль запускается без интернета "
                    + "(в режиме «через прокси» доступен только IP прокси)", .error)
            }
            // Only after a new import: re-sending them every launch would
            // overwrite cookies Safari refreshed in the meantime.
            let cookies = profileStore.cookiesURL(for: profile)
            if profile.needsCookieApply && FileManager.default.fileExists(atPath: cookies.path) {
                cookiesFile = cookies.path
            }
        }
        sentCookies = cookiesFile != nil
        cookieImportFailed = false

        scriptParser = ScriptOutputParser()
        scriptError = nil
        progress.start(.vm, detail: "Запуск…")
        setStatus("Запуск системы…")
        let external = try await startEmbeddedVMIfPossible(policy: network)
        display = external ? .embedded : .tartWindow
        let environment = LauncherEnvironment.scriptEnvironment(
            base: baseEnvironment, tartPath: tart, askPass: askPass,
            localPort: LauncherEnvironment.freeLocalPort(), network: network, cookiesFile: cookiesFile,
            showWindow: !external, proxyURL: proxyURL, identity: identity, kiosk: true, externalVM: external)

        appendLog("bash \(script) \(vmName) \(url)\(external ? " (VM в окне приложения)" : " (VM в окне Tart)")", .info)
        let code = try await stream("/bin/bash", [script, vmName, url], environment: environment) { [weak self] line in
            self?.handleScriptLine(line)
        }
        if external { await embeddedVM?.stop() }
        if cancelRequested { throw LaunchFailure.cancelled }
        if phase == .ready { // the VM was shut down from inside or its window closed
            if let message = vmStopMessage { throw LaunchFailure.failed("VM остановилась: \(message)") }
            phase = .finished
            setStatus("Браузер закрыт")
            appendLog("VM завершила работу (код \(code))", .info)
            return
        }
        throw LaunchFailure.failed(vmStopMessage.map { "VM остановилась: \($0)" }
            ?? scriptError
            ?? lastOutputLine.map { "Запуск не удался: \($0)" }
            ?? "tart-prototype.sh завершился с кодом \(code)")
    }

    /// Starts the VM in the app's own window. False → the script runs
    /// `tart run` instead (setting off, VM not runnable here, entitlement
    /// missing). Throws for problems `tart run` would hit as well.
    private func startEmbeddedVMIfPossible(policy: NetworkPolicy) async throws -> Bool {
        guard useEmbeddedWindow else { return false }
        guard EmbeddedVM.isSupported else {
            appendLog("Virtualization.framework недоступен — VM откроется в окне Tart", .info)
            return false
        }
        let bundle: TartVMBundle
        do {
            bundle = try TartVMBundle.load(name: vmName, vmsDirectory: LauncherEnvironment.tartVMsDirectory())
        } catch {
            appendLog("Эту VM нельзя показать в окне приложения (\(error)) — откроется окно Tart", .info)
            return false
        }
        var softnetPath: String?
        if SoftnetCommand.arguments(macAddress: bundle.config.macAddress, policy: policy) != nil {
            setStatus("Проверка сети…")
            let readiness = await SoftnetReadiness.check(searchPath: baseEnvironment["PATH"] ?? "",
                                                         environment: baseEnvironment)
            try checkCancelled()
            guard case .ready(let path) = readiness else {
                throw LaunchFailure.failed(readiness.problem ?? "softnet недоступен")
            }
            softnetPath = path
        }
        let vm = EmbeddedVM(bundle: bundle)
        vm.onLog = { [weak self] line in self?.appendLog(line, .output) }
        vm.onStopped = { [weak self] message in self?.embeddedVMStopped(message) }
        embeddedVM = vm
        setStatus("Запуск системы…")
        do {
            try await vm.start(policy: policy, softnetPath: softnetPath)
            appendLog("VM запущена в окне приложения", .info)
            return true
        } catch EmbeddedVMError.alreadyRunning {
            embeddedVM = nil
            throw LaunchFailure.failed(EmbeddedVMError.alreadyRunning.errorDescription ?? "VM уже запущена")
        } catch {
            embeddedVM = nil
            try checkCancelled()
            appendLog("VM не запустилась в окне приложения: \(error.localizedDescription) — откроется окно Tart", .error)
            return false
        }
    }

    /// The in-app VM stopped by itself (macOS shut down, an error, softnet
    /// died). The script holds the tunnel for it: end the script too.
    private func embeddedVMStopped(_ message: String?) {
        guard !cancelRequested else { return }
        vmStopMessage = message
        appendLog(message.map { "VM остановилась: \($0)" } ?? "macOS в VM выключена", message == nil ? .info : .error)
        activeProcess?.signalGroup(SIGINT)
    }

    private func handleScriptLine(_ line: String) {
        if line.contains("cookie import failed") { cookieImportFailed = true }
        guard let event = scriptParser.consume(line) else { return }
        switch event {
        case .stage(let stage, let detail):
            progress.start(stage, detail: detail)
            if phase == .running { setStatus(detail) }
        case .detail(let stage, let detail):
            progress.update(stage, detail: detail)
        case .ready:
            progress.finish(.safari, detail: "Открыто")
            progress.finish(.done, detail: "Браузер открыт")
            if phase == .running {
                phase = .ready
                browserReady = true
                setStatus(display == .embedded ? "Браузер открыт" : "Браузер открыт в окне Tart")
                // Remember the profile's last URL; cookies count as applied
                // only if the agent took them.
                if let profile = activeProfile {
                    let applied = sentCookies && !cookieImportFailed
                    activeProfile = try? profileStore.update(profile.id) {
                        $0.lastURL = targetURL
                        if applied { $0.cookiesAppliedAt = Date() }
                    }
                    reloadProfiles()
                }
            }
        case .stopping:
            if phase == .stopping { setStatus("Остановка…") }
        case .error(let message):
            scriptError = message
        }
    }

    // MARK: - Installing Tart

    private func downloadAndInstallTart() async throws -> String {
        progress.start(.tart, detail: "Скачивание компонента виртуализации…", progress: 0)
        setStatus("Скачивание компонента виртуализации (Tart)…")
        appendLog("Скачивание \(TartDownloader.releaseURL.absoluteString)", .info)
        let downloader = TartDownloader { [weak self] fraction, received, expected in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .running else { return }
                    let text = expected > 0
                        ? "Скачивание Tart: \(Self.formatBytes(received)) из \(Self.formatBytes(expected))"
                        : "Скачивание Tart: \(Self.formatBytes(received))"
                    self.progress.update(.tart, detail: text, progress: fraction)
                    self.setStatus(text)
                }
            }
        }
        self.downloader = downloader
        defer { self.downloader = nil }
        let archive = try await downloader.download()
        try checkCancelled()
        progress.update(.tart, detail: "Распаковка и проверка подписи…", progress: 1)
        setStatus("Установка компонента виртуализации…")
        let path = try await TartSetup.install(archive: archive, environment: baseEnvironment)
        appendLog("Tart установлен: \(path)", .info)
        return path
    }

    private func installWithHomebrew(brew: String) async throws -> String {
        progress.start(.tart, detail: "Установка через Homebrew…")
        setStatus("Установка компонента виртуализации через Homebrew…")
        appendLog("\(brew) install cirruslabs/cli/tart", .info)
        var environment = baseEnvironment
        environment["NONINTERACTIVE"] = "1"
        let code = try await stream(brew, ["install", "cirruslabs/cli/tart"], environment: environment) { [weak self] line in
            self?.progress.update(.tart, detail: String(line.prefix(140)))
        }
        try checkCancelled()
        guard code == 0 else {
            throw LaunchFailure.failed("Homebrew не смог установить Tart: \(lastOutputLine ?? "код \(code)")")
        }
        guard let path = TartSetup.locate(searchPath: baseEnvironment["PATH"] ?? "") else {
            throw LaunchFailure.failed("Homebrew закончил установку, но tart не найден")
        }
        return path
    }

    // MARK: - Processes

    /// Runs a command in its own process group, logging its output and passing
    /// each line to `onLine` on the main actor. Cancellable through `cancel()`.
    func stream(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                onLine: @escaping @MainActor @Sendable (String) -> Void) async throws -> Int32 {
        let process = GroupProcess(executable: executable, arguments: arguments,
                                   environment: environment ?? baseEnvironment) { [weak self] line in
            // One reader thread + the serial main queue keep lines in order, and
            // they are all delivered before exitCode() returns (see GroupProcess).
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.appendLog(line, .output)
                    onLine(line)
                }
            }
        }
        try process.start()
        activeProcess = process
        defer { activeProcess = nil }
        return await process.exitCode()
    }

    /// Like Ctrl+C in a terminal, then harder: the script's trap stops a VM it
    /// started on SIGINT; SIGTERM/SIGKILL and a direct stop are fallbacks.
    private func terminate(_ process: GroupProcess, stoppingVM: Bool) async {
        process.signalGroup(SIGINT)
        if await process.waitForExit(timeout: stoppingVM ? 60 : 15) != nil { return }
        appendLog("Нет ответа на SIGINT — SIGTERM", .info)
        process.signalGroup(SIGTERM)
        if await process.waitForExit(timeout: 10) != nil { return }
        process.signalGroup(SIGKILL)
        _ = await process.waitForExit(timeout: 5)
        guard stoppingVM else { return }
        if let vm = embeddedVM {
            await vm.stop()
        } else if let tart = tartPath {
            appendLog("Принудительная остановка: tart stop \(vmName)", .info)
            _ = try? await GroupProcess.run(tart, ["stop", vmName], environment: baseEnvironment, timeout: 60)
        }
    }

    // MARK: - Outcome

    private func checkCancelled() throws {
        if cancelRequested { throw LaunchFailure.cancelled }
    }

    private func handle(_ error: Error) {
        if cancelRequested || error is CancellationError || (error as? LaunchFailure) == .cancelled {
            finishCancelled()
            return
        }
        let message: String
        if case LaunchFailure.failed(let text) = error {
            message = text
        } else {
            message = error.localizedDescription
        }
        progress.fail(detail: message)
        errorMessage = message
        phase = .failed
        setStatus("Не удалось открыть браузер")
        appendLog(message, .error)
    }

    private func finishCancelled() {
        let vmWasUp = progress[.done].isDone
        progress.cancelOpenStages()
        phase = vmWasUp ? .finished : .cancelled
        setStatus(vmWasUp ? "Браузер закрыт" : "Отменено")
    }

    func setStatus(_ text: String) {
        statusText = text
    }

    func appendLog(_ text: String, _ kind: LogLine.Kind) {
        if kind == .output { lastOutputLine = text }
        log.append(LogLine(id: nextLogID, text: text, kind: kind))
        nextLogID += 1
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
        // Persist the meaningful events (launch, errors, VM IP) to the host log
        // file — not every streamed subprocess line, which would rewrite the
        // file on each append.
        if kind != .output { fileLog.append(text, level: kind == .error ? "error" : "info") }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
