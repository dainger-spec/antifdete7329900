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

/// Drives a launch: Tart → image → VM/agent/Safari (via tart-prototype.sh),
/// and publishes stage-by-stage progress for the window.
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

    @Published var urlText: String
    @Published private(set) var progress = LaunchProgress()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText = "Введите адрес и нажмите «Запустить»"
    @Published private(set) var errorMessage: String?
    @Published private(set) var urlError: String?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var tartHelp: TartHelp?

    let vmName = LauncherDefaults.vmName
    let baseImage = LauncherDefaults.baseImage

    private let baseEnvironment: [String: String]
    private let statusCache = SetupStatusCache()
    private var pipeline: Task<Void, Never>?
    private var activeProcess: GroupProcess?
    private var downloader: TartDownloader?
    private var tartPath: String?
    private var tartVersion: String?
    private var targetURL: String?
    private var cancelRequested = false
    private var scriptParser = ScriptOutputParser()
    private var scriptError: String?
    private var imageStep = "Скачивание образа"
    private var lastOutputLine: String?
    private var nextLogID = 0

    /// No cached environment check yet → treat as a first run (show onboarding).
    let isFirstRun: Bool

    init() {
        urlText = UserDefaults.standard.string(forKey: "lastURL") ?? "https://browserleaks.com"
        var environment = ProcessInfo.processInfo.environment
        // A Finder-launched app has PATH=/usr/bin:/bin:/usr/sbin:/sbin; Homebrew's tart lives elsewhere.
        environment["PATH"] = LauncherEnvironment.searchPath(environment["PATH"])
        baseEnvironment = environment
        isFirstRun = statusCache.load() == nil
    }

    // MARK: - State for the view

    var isBusy: Bool { phase == .running || phase == .stopping }
    var canStart: Bool { !isBusy && phase != .ready }
    var canCancel: Bool { phase == .running }
    var hasActiveWork: Bool { isBusy || phase == .ready }
    var logText: String { log.map(\.text).joined(separator: "\n") }

    /// The benefit cards shown on the setup splash.
    var benefitCards: [BenefitCard] { CarouselDeck.cards }

    /// Show the full-window setup splash (carousel + progress) while the VM is
    /// coming up and Safari isn't open yet — i.e. the long first-launch/download
    /// wait. The Tart-missing panel and errors stay in the main window.
    var showsSplash: Bool { (phase == .running || phase == .stopping) && !progress[.done].isDone }

    // MARK: - Actions

    func start() {
        guard canStart else { return }
        guard let url = URLInput.normalize(urlText) else {
            urlError = "Нужен адрес вида https://example.com"
            return
        }
        urlError = nil
        urlText = url
        UserDefaults.standard.set(url, forKey: "lastURL")
        targetURL = url
        progress = LaunchProgress()
        tartHelp = nil
        appendLog("Запуск: \(url)", .info)
        run { try await self.launch(url: url, knownTart: nil) }
    }

    /// "Отмена" during a launch, or "Остановить VM" once Safari is open.
    func cancel() {
        guard phase == .running || phase == .ready else { return }
        let stoppingVM = phase == .ready || (progress.furthest ?? .tart) >= .vm
        cancelRequested = true
        phase = .stopping
        setStatus(stoppingVM ? "Остановка VM…" : "Отмена…")
        appendLog(stoppingVM ? "Остановка VM по запросу" : "Отмена по запросу", .info)
        downloader?.cancel()
        if let process = activeProcess {
            Task { await self.terminate(process, stoppingVM: stoppingVM) }
        }
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
        }
    }

    private func launch(url: String, knownTart: String?) async throws {
        guard let tart = try await checkTart(known: knownTart) else { return } // waits for the user
        try await ensureImage(tart: tart)
        try await runScript(tart: tart, url: url)
    }

    private func checkTart(known: String?) async throws -> String? {
        progress.start(.tart, detail: "Поиск tart…")
        setStatus("Проверка Tart…")
        guard HostInfo.isAppleSilicon else {
            throw LaunchFailure.failed("Tart запускает macOS-VM только на Mac с Apple Silicon (M1 и новее).")
        }
        let searchPath = baseEnvironment["PATH"] ?? ""
        guard let path = known ?? TartSetup.locate(searchPath: searchPath) else {
            progress.attention(.tart, detail: "Tart не найден")
            tartHelp = TartHelp(brewPath: LauncherEnvironment.findExecutable("brew", searchPath: searchPath))
            phase = .needsTart
            setStatus("Нужен Tart — выберите способ установки ниже")
            appendLog("tart не найден ни в PATH (\(searchPath)), ни в \(TartSetup.managedBinary.path)", .error)
            return nil
        }
        let version = try await GroupProcess.run(path, ["--version"], environment: baseEnvironment, timeout: 30)
        try checkCancelled()
        guard version.code == 0 else {
            throw LaunchFailure.failed("tart не запускается (\(path)): \(version.lines.last ?? "нет вывода")")
        }
        tartPath = path
        let versionText = version.lines.last ?? "?"
        tartVersion = versionText
        progress.finish(.tart, detail: "tart \(versionText) · \(path)")
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
        progress.start(.image, detail: "Поиск VM «\(vmName)»…")
        setStatus("Проверка образа macOS…")
        let list = try await GroupProcess.run(tart, ["list"], environment: baseEnvironment, timeout: 60)
        try checkCancelled()
        guard list.code == 0 else {
            throw LaunchFailure.failed("tart list завершился с ошибкой: \(list.lines.last ?? "нет вывода")")
        }
        if TartOutput.vmListContains(list.lines.joined(separator: "\n"), name: vmName) {
            progress.finish(.image, detail: "VM «\(vmName)» уже есть")
            saveSetupStatus(imagePresent: true)
            return
        }

        if let free = HostInfo.availableDiskBytes(), free < 60_000_000_000 {
            appendLog("Свободно \(Self.formatBytes(free)); образу macOS нужно около 50 ГБ", .error)
        }
        imageStep = "Скачивание образа"
        progress.update(.image, detail: "Скачивание \(baseImage)…")
        setStatus("Скачивание образа macOS (около 25 ГБ, это надолго)…")
        appendLog("tart clone \(baseImage) \(vmName)", .info)
        let code = try await stream(tart, ["clone", baseImage, vmName]) { [weak self] line in
            self?.handleCloneLine(line)
        }
        try checkCancelled()
        guard code == 0 else {
            throw LaunchFailure.failed("Не удалось скачать образ: \(lastOutputLine ?? "tart clone завершился с кодом \(code)")")
        }
        progress.finish(.image, detail: "Образ скачан, VM «\(vmName)» создана")
        saveSetupStatus(imagePresent: true)
    }

    private func handleCloneLine(_ line: String) {
        if let fraction = TartOutput.percent(in: line) {
            let percent = Int((fraction * 100).rounded(.down))
            progress.update(.image, detail: "\(imageStep): \(percent)%", progress: fraction)
            setStatus("Скачивание образа macOS: \(percent)%")
        } else if let label = TartOutput.label(in: line) {
            imageStep = label
            progress.update(.image, detail: label)
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
        let environment = LauncherEnvironment.scriptEnvironment(
            base: baseEnvironment, tartPath: tart, askPass: askPass,
            localPort: LauncherEnvironment.freeLocalPort())

        scriptParser = ScriptOutputParser()
        scriptError = nil
        progress.start(.vm, detail: "Запуск VM…")
        setStatus("Запуск VM…")
        appendLog("bash \(script) \(vmName) \(url)", .info)
        let code = try await stream("/bin/bash", [script, vmName, url], environment: environment) { [weak self] line in
            self?.handleScriptLine(line)
        }
        if cancelRequested { throw LaunchFailure.cancelled }
        if phase == .ready { // the VM was shut down from inside or its window closed
            phase = .finished
            setStatus("VM остановлена")
            appendLog("VM завершила работу (код \(code))", .info)
            return
        }
        throw LaunchFailure.failed(scriptError
            ?? lastOutputLine.map { "Скрипт запуска завершился с ошибкой: \($0)" }
            ?? "tart-prototype.sh завершился с кодом \(code)")
    }

    private func handleScriptLine(_ line: String) {
        guard let event = scriptParser.consume(line) else { return }
        switch event {
        case .stage(let stage, let detail):
            progress.start(stage, detail: detail)
            if phase == .running { setStatus(detail) }
        case .detail(let stage, let detail):
            progress.update(stage, detail: detail)
        case .ready(let ip):
            progress.finish(.safari, detail: "Открыт \(targetURL ?? "адрес")")
            progress.finish(.done, detail: ip.map { "Safari открыт в окне VM · IP \($0)" } ?? "Safari открыт в окне VM")
            if phase == .running {
                phase = .ready
                setStatus("Готово — Safari открыт в окне VM")
            }
        case .stopping:
            if phase == .stopping { setStatus("Остановка VM…") }
        case .error(let message):
            scriptError = message
        }
    }

    // MARK: - Installing Tart

    private func downloadAndInstallTart() async throws -> String {
        progress.start(.tart, detail: "Скачивание Tart с GitHub…", progress: 0)
        setStatus("Скачивание Tart…")
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
        setStatus("Установка Tart…")
        let path = try await TartSetup.install(archive: archive, environment: baseEnvironment)
        appendLog("Tart установлен: \(path)", .info)
        return path
    }

    private func installWithHomebrew(brew: String) async throws -> String {
        progress.start(.tart, detail: "brew install cirruslabs/cli/tart…")
        setStatus("Установка Tart через Homebrew…")
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
    private func stream(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
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

    /// Like Ctrl+C in a terminal, then harder: the script's trap stops the VM
    /// on SIGINT; SIGTERM/SIGKILL and a direct `tart stop` are fallbacks.
    private func terminate(_ process: GroupProcess, stoppingVM: Bool) async {
        process.signalGroup(SIGINT)
        if await process.waitForExit(timeout: stoppingVM ? 60 : 15) != nil { return }
        appendLog("Нет ответа на SIGINT — SIGTERM", .info)
        process.signalGroup(SIGTERM)
        if await process.waitForExit(timeout: 10) != nil { return }
        process.signalGroup(SIGKILL)
        _ = await process.waitForExit(timeout: 5)
        if stoppingVM, let tart = tartPath {
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
        setStatus("Ошибка — см. ниже")
        appendLog(message, .error)
    }

    private func finishCancelled() {
        let vmWasUp = progress[.done].isDone
        progress.cancelOpenStages()
        phase = vmWasUp ? .finished : .cancelled
        setStatus(vmWasUp ? "VM остановлена" : "Отменено")
    }

    private func setStatus(_ text: String) {
        statusText = text
    }

    private func appendLog(_ text: String, _ kind: LogLine.Kind) {
        if kind == .output { lastOutputLine = text }
        log.append(LogLine(id: nextLogID, text: text, kind: kind))
        nextLogID += 1
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
