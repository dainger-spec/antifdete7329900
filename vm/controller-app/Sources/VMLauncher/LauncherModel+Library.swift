import AppKit
import Foundation
import VMControllerCore

/// What the profile editor hands the model.
struct ProfileDraft: Equatable {
    var name = ""
    var network: NetworkMode = .direct
    var proxy = ""
    var timeZone: String?
    var language: String?
    var clipboardShared = false

    init() {}

    init(profile: Profile) {
        name = profile.name
        network = profile.network
        proxy = profile.proxy ?? ""
        timeZone = profile.timeZone
        language = profile.language
        clipboardShared = profile.clipboardShared
    }

    var cleanProxy: String? {
        let trimmed = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A user-facing problem with the draft, or nil.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Введите имя профиля" }
        guard network == .proxy else { return nil }
        guard let proxy = cleanProxy else { return "Укажите прокси или выберите другой режим" }
        guard let endpoint = ProxyEndpoint(proxy) else {
            return "Прокси вида socks5://host:port или http://host:port"
        }
        if endpoint.scheme == "https" { return "https://-прокси не поддерживаются; используйте http:// или socks5://" }
        if endpoint.allowCIDR == nil {
            return "Укажите прокси IP-адресом (например 203.0.113.5): по имени хоста его нельзя пропустить через защиту"
        }
        return nil
    }
}

extension LauncherModel {
    /// Host resource snapshot for the resources section.
    struct ResourceReport: Equatable, Sendable {
        var runningVMs: Int
        var profilesDiskBytes: Int64
        var freeRAMBytes: Int64?
        var lowRAM: Bool { HostResources.isLowRAM(freeRAMBytes) }
    }

    var logFileURL: URL { fileLog.url }
    func logFileTail() -> String { fileLog.tail() }

    // MARK: - Profiles

    func reloadProfiles() {
        profiles = (try? profileStore.list()) ?? []
    }

    /// Creates a profile; returns an error message to show, or nil.
    @discardableResult
    func createProfile(_ draft: ProfileDraft) -> (Profile?, String?) {
        if let problem = draft.problem { return (nil, problem) }
        do {
            let profile = try profileStore.add(Profile(
                name: draft.name, proxy: draft.cleanProxy, clipboardShared: draft.clipboardShared,
                network: draft.network, timeZone: draft.timeZone, language: draft.language))
            reloadProfiles()
            appendLog("Создан профиль «\(profile.name)» [\(profile.vmName)]", .info)
            return (profile, nil)
        } catch {
            return (nil, Self.describe(error))
        }
    }

    /// Saves the editor's changes; returns an error message to show, or nil.
    func updateProfile(_ id: String, _ draft: ProfileDraft) -> String? {
        if let problem = draft.problem { return problem }
        do {
            try profileStore.update(id) {
                $0.name = draft.name
                $0.network = draft.network
                $0.proxy = draft.cleanProxy
                $0.timeZone = draft.timeZone
                $0.language = draft.language
                $0.clipboardShared = draft.clipboardShared
            }
            reloadProfiles()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Deletes the profile, its files and its VM (all of its browsing data).
    func deleteProfile(_ profile: Profile) {
        guard !isActive(profile) else {
            errorMessage = "Сначала остановите профиль «\(profile.name)»"
            return
        }
        do {
            try profileStore.remove(profile.id)
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        reloadProfiles()
        appendLog("Удалён профиль «\(profile.name)»", .info)
        guard let tart = TartSetup.locate(searchPath: baseEnvironment["PATH"] ?? "") else { return }
        Task { @MainActor in
            let result = try? await GroupProcess.run(tart, ProfilePlan.delete(vmName: profile.vmName),
                                                     environment: baseEnvironment, timeout: 300)
            if result?.code == 0 {
                appendLog("Удалена VM \(profile.vmName)", .info)
            } else {
                appendLog("VM \(profile.vmName) не удалена: \(result?.lines.last ?? "tart delete не запустился")", .error)
            }
            await refreshResources()
        }
    }

    /// A new serial number and MAC for a profile created before profiles got
    /// their own. Can lock Safari out of passwords saved in the VM's "Local
    /// Items" keychain — the UI says so before calling this.
    func makeIdentityUnique(_ profile: Profile) {
        guard canStart else {
            errorMessage = "Сначала остановите запущенный профиль"
            return
        }
        guard let tart = TartSetup.locate(searchPath: baseEnvironment["PATH"] ?? "") else {
            errorMessage = "Не найден компонент виртуализации (tart)"
            return
        }
        Task { @MainActor in
            let result = try? await GroupProcess.run(tart, ProfilePlan.uniqueIdentity(profile),
                                                     environment: baseEnvironment, timeout: 60)
            if result?.code == 0 {
                try? profileStore.update(profile.id) { $0.uniqueIdentity = true }
                reloadProfiles()
                appendLog("Профилю «\(profile.name)» выдан собственный серийный номер и MAC", .info)
            } else {
                errorMessage = "Не удалось: \(result?.lines.last ?? "tart set не запустился")"
            }
        }
    }

    /// Export a profile (settings + cookies + its VM) to one portable .tar.gz.
    func exportProfile(_ profile: Profile, to url: URL) {
        let vms = LauncherEnvironment.tartVMsDirectory()
        appendLog("Экспорт профиля «\(profile.name)» → \(url.path)", .info)
        Task { @MainActor in
            do {
                try await ProfileBundle.export(profile: profile, store: self.profileStore, vmsDirectory: vms, to: url)
                self.appendLog("Экспорт готов: \(url.lastPathComponent)", .info)
            } catch {
                self.errorMessage = "Экспорт не удался: \(error)"
                self.appendLog("Экспорт не удался: \(error)", .error)
            }
        }
    }

    /// Import a profile archive (new id, non-clashing name). Its VM gets a new
    /// MAC so it can run next to the profile it was exported from.
    func importProfile(from url: URL) {
        let vms = LauncherEnvironment.tartVMsDirectory()
        appendLog("Импорт профиля из \(url.lastPathComponent)", .info)
        Task { @MainActor in
            do {
                let profile = try await ProfileBundle.importArchive(url, store: self.profileStore, vmsDirectory: vms)
                if FileManager.default.fileExists(atPath: vms.appendingPathComponent(profile.vmName).path),
                   let tart = TartSetup.locate(searchPath: self.baseEnvironment["PATH"] ?? "") {
                    let result = try? await GroupProcess.run(tart, ["set", profile.vmName, "--random-mac"],
                                                             environment: self.baseEnvironment, timeout: 60)
                    if result?.code != 0 {
                        self.appendLog("Новый MAC для \(profile.vmName) не задан: \(result?.lines.last ?? "?")", .error)
                    }
                }
                self.reloadProfiles()
                self.appendLog("Импортирован профиль «\(profile.name)»", .info)
            } catch {
                self.errorMessage = "Импорт не удался: \(error)"
                self.appendLog("Импорт не удался: \(error)", .error)
            }
        }
    }

    /// Import cookies into a profile from a file the user picked. They go into
    /// the VM's Safari on the profile's next launch.
    func importCookies(for id: String, from url: URL) {
        do {
            let count = try profileStore.importCookies(for: id, from: url)
            reloadProfiles()
            appendLog("Импортировано cookies: \(count) (профиль \(id))", .info)
        } catch {
            errorMessage = "Не удалось импортировать cookies: \(error)"
            appendLog("Импорт cookies не удался: \(error)", .error)
        }
    }

    func clearCookies(for id: String) {
        try? profileStore.clearCookies(for: id)
        reloadProfiles()
    }

    static func describe(_ error: Error) -> String {
        switch error as? ProfileError {
        case .invalidName: "Введите имя профиля"
        case .duplicateName(let name): "Профиль «\(name)» уже есть"
        case .notFound: "Профиль не найден"
        case nil: "\(error)"
        }
    }

    // MARK: - Base image

    var currentBaseImage: String { LauncherDefaults.baseImage }
    var profilesOnOtherBase: [Profile] {
        BaseImagePolicy.profilesOnOtherBase(profiles, currentBase: currentBaseImage)
    }

    /// Ask the registry for the base tag's current digest and compare it with
    /// the one recorded at last pull — a read, not a download. Best-effort: on
    /// any failure the state stays/returns to `.unknown`.
    func checkBaseImageUpdate() {
        guard !baseUpdateChecking, !baseUpdateInProgress else { return }
        baseUpdateChecking = true
        Task { @MainActor in
            defer { baseUpdateChecking = false }
            guard let reference = OCIReference(currentBaseImage) else {
                baseUpdateState = .unknown
                return
            }
            let stored = statusCache.load()?.baseImageDigest
            let remote = await RegistryClient.remoteDigest(for: reference)
            baseUpdateState = BaseImagePolicy.updateState(stored: stored, remote: remote)
        }
    }

    /// After a successful pull, remember the tag's current digest so a later
    /// check can tell whether it has moved. Merges into the cached status
    /// (keeping Tart path/version/presence); best-effort — a missed digest just
    /// leaves the next check "unknown".
    private func recordBaseImageDigest() async {
        guard let reference = OCIReference(currentBaseImage),
              let digest = await RegistryClient.remoteDigest(for: reference) else { return }
        var status = statusCache.load() ?? SetupStatus(baseImage: currentBaseImage, baseImagePresent: true)
        status.baseImageDigest = digest
        status.checkedAt = Date()
        statusCache.save(status)
        baseUpdateState = .upToDate
    }

    /// Pull the latest base image into Tart's cache (for new profiles). Existing
    /// profiles are independent clones — see BaseImagePolicy; this doesn't touch
    /// them. Runs off the launch pipeline.
    func updateBaseImage() {
        guard canStart, !baseUpdateInProgress else { return }
        baseUpdateInProgress = true
        baseUpdateDetail = "Запуск…"
        appendLog("Обновление базового образа: tart pull \(currentBaseImage)", .info)
        Task { @MainActor in
            defer { baseUpdateInProgress = false }
            guard let tart = TartSetup.locate(searchPath: baseEnvironment["PATH"] ?? "") else {
                errorMessage = "Не найден компонент виртуализации (tart)"
                baseUpdateDetail = "Tart не найден"
                return
            }
            do {
                let code = try await stream(tart, ProfilePlan.pullBase(currentBaseImage)) { [weak self] line in
                    guard let self else { return }
                    if let fraction = TartOutput.percent(in: line) {
                        self.baseUpdateDetail = "\(Int((fraction * 100).rounded(.down)))%"
                    } else if let label = TartOutput.label(in: line) {
                        self.baseUpdateDetail = String(label.prefix(80))
                    }
                }
                if code == 0 {
                    baseUpdateDetail = "Готово"
                    appendLog("Базовый образ обновлён", .info)
                    await recordBaseImageDigest()
                    await refreshResources()
                } else {
                    baseUpdateDetail = "Ошибка"
                    errorMessage = "Не удалось обновить базовый образ (код \(code))"
                    appendLog("Обновление образа не удалось (код \(code))", .error)
                }
            } catch {
                baseUpdateDetail = "Ошибка"
                errorMessage = "Не удалось обновить базовый образ: \(error)"
                appendLog("Обновление образа не удалось: \(error)", .error)
            }
        }
    }

    // MARK: - Host resources

    /// Recount running VMs, sum the profiles' disk use, read free RAM. Cheap
    /// enough to call on window appear and after a launch.
    func refreshResources() async {
        let vms = LauncherEnvironment.tartVMsDirectory()
        let current = profiles
        let disk = await Task.detached { HostResources.profilesDiskBytes(current, vmsDirectory: vms) }.value
        var running = 0
        if let tart = TartSetup.locate(searchPath: baseEnvironment["PATH"] ?? ""),
           let result = try? await GroupProcess.run(tart, ["list"], environment: baseEnvironment, timeout: 30),
           result.code == 0 {
            running = TartOutput.runningVMNames(result.lines.joined(separator: "\n"), prefix: "pb-").count
        }
        let free = await HostResources.freeRAMBytes(environment: baseEnvironment)
        resource = ResourceReport(runningVMs: running, profilesDiskBytes: disk, freeRAMBytes: free)
    }
}
