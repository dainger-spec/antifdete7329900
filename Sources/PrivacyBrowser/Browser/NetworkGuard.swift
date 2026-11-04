import AppKit
import BrowserCore
import NetworkExtension
import NetworkGuardCore
import os
import Security
import SystemExtensions

/// The app's side of the network guard (docs/TUNNEL.md): the content-filter system extension
/// (`NetworkGuardExtension`) that holds each process of a profile whose WebRTC goes through its
/// proxy to that proxy — its connections anywhere else, and what WebKit's processes or the system
/// open on its behalf, are dropped. The guard carries nothing: a page's WebRTC goes to the relay on
/// 127.0.0.1 (`WebRTCRelays`, this process), which sends it through the profile's proxy.
///
/// Its state is one input of `WebRTCGate`: while it is anything but `ready`, every proxied profile
/// runs with WebRTC off in the engine and is told why. It is `ready` only when the extension is
/// installed, switched on, this app's own version, answering, and proven on this Mac.
///
/// When it stops answering while it holds processes — the extension crashed, was switched off in
/// System Settings, or replaced — their profiles are stopped (`onHoldsLost`): nothing of theirs
/// runs on without it.
///
/// The self-test can stand in for the guard — CI cannot load a system extension — for the profiles
/// it starts itself; a launch the person makes never has a stand-in.
@MainActor
final class NetworkGuard: NSObject, ObservableObject {
    static let shared = NetworkGuard()

    /// What stopped the last attempt to install or switch on the guard; each is said in words with
    /// who can do what about it (the settings page).
    enum Problem: Equatable {
        /// macOS finishes installing it at the next restart.
        case reboot
        /// Lumen is not in /Applications (macOS installs system extensions of apps there only).
        case location
        /// This copy's signature does not fit the extension's.
        case signing
        /// Only an administrator of this Mac may allow it.
        case authorization
        /// This Mac's management (MDM) forbids it.
        case policy
        /// The filter configuration's prompt was declined.
        case declined
        case other(String)
    }

    /// Where the installed guard stands (the self-test's stand-in aside).
    @Published private(set) var installedState: NetworkGuardState = .notInBuild
    /// Asking macOS: the extension's properties, an activation, the filter configuration, its answer.
    @Published private(set) var checking = false
    @Published private(set) var problem: Problem?
    /// The check on this Mac is running (`prove`), or it ran and did not show what it must.
    @Published private(set) var proving = false
    @Published private(set) var proofFailed = false

    /// Set by the self-test only (`SelfTest`), around the profiles it starts.
    var selfTestStandIn = false {
        willSet { objectWillChange.send() }
    }

    var state: NetworkGuardState { selfTestStandIn ? .ready : installedState }

    /// Called with the processes that were held when the guard stopped answering for them: their
    /// profiles are stopped (`ProfileManager`).
    var onHoldsLost: (([pid_t]) -> Void)?

    /// The extension's bundle identifier, from the app's Info.plist (`NE=1 scripts/build-app.sh`),
    /// when the extension is inside this app.
    let extensionIdentifier: String?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "NetworkGuard")
    private var connection: NSXPCConnection?
    private var pendingRequest: OSSystemExtensionRequest?
    private var pendingIsActivation = false
    /// The pending activation came from the Install button: the filter configuration is then
    /// added (its prompt) or switched back on. An update keeps the configuration as it is.
    private var activationInstalls = false
    private var held: [pid_t: GuardRegistration] = [:]
    private var standIns: Set<pid_t> = []
    private var heartbeat: Timer?
    private var settledWaiters: [CheckedContinuation<Void, Never>] = []
    /// macOS still keeps an earlier copy of the guard, to be removed at the next restart: the copy
    /// it switched on does not run before then (`NetworkGuardReading.silent`).
    private var earlierCopyAwaitsRestart = false
    private var configurationObserver: NSObjectProtocol?

    override init() {
        let identifier = Bundle.main.object(forInfoDictionaryKey: NetworkGuardNames.appInfoKey) as? String
        let bundled = identifier.map { Self.bundledURL(of: $0) }
        extensionIdentifier = bundled.map { FileManager.default.fileExists(atPath: $0.path) } == true ? identifier : nil
        super.init()
        guard extensionIdentifier != nil else { return }
        installedState = .notInstalled
        checking = true
        // Switched off or removed in System Settings: asked again.
        configurationObserver = NotificationCenter.default.addObserver(forName: .NEFilterConfigurationDidChange, object: nil,
                                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        DispatchQueue.main.async { self.refresh() }
    }

    // MARK: State

    /// The settings page's Check Again: everything asked again, the check on this Mac included.
    func checkAgain() {
        problem = nil
        proofFailed = false
        refresh()
    }

    /// Reads where the extension and its filter configuration stand (no prompts).
    func refresh() {
        guard let identifier = extensionIdentifier, !(pendingIsActivation && pendingRequest != nil) else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        pendingIsActivation = false
        checking = true
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// The state once asking macOS is over (at most 8 s): what a launch decides on.
    func settledState() async -> NetworkGuardState {
        if selfTestStandIn { return .ready }
        if checking {
            await withCheckedContinuation { continuation in
                settledWaiters.append(continuation)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self.resumeSettledWaiters()
                }
            }
        }
        return state
    }

    private func settle(_ new: NetworkGuardState) {
        if new != installedState { log.notice("guard: \(new.rawValue, privacy: .public)") }
        installedState = new
        checking = false
        resumeSettledWaiters()
        if new != .ready, new != .unproven { connectionLost(reason: new.rawValue) }
    }

    private func resumeSettledWaiters() {
        let waiters = settledWaiters
        settledWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func extensionProperties(_ properties: [OSSystemExtensionProperties]) {
        earlierCopyAwaitsRestart = properties.contains(where: \.isUninstalling)
        if earlierCopyAwaitsRestart { log.notice("an earlier copy of the guard waits to be removed at the next restart") }
        let enabled = properties.filter { $0.isEnabled && !$0.isUninstalling }
        if !enabled.isEmpty {
            // macOS replaces an installed extension only on an activation request: one that is not
            // this app's own version (the app was updated) is replaced now, without a new approval.
            if let bundled = bundledExtensionVersion, !enabled.contains(where: { $0.bundleVersion == bundled }) {
                log.notice("the installed guard is not this app's version \(bundled, privacy: .public): replacing it")
                activate(installing: false)
                return
            }
            Task { await configureFilter(install: false) }
        } else if properties.contains(where: \.isAwaitingUserApproval) {
            settle(.awaitingApproval)
        } else {
            settle(.notInstalled)
        }
    }

    // MARK: Install

    /// Asks macOS to install the extension (its prompt, then a switch in System Settings), then
    /// adds the filter configuration (another prompt). The settings page explains both first.
    func install() {
        problem = nil
        activate(installing: true)
    }

    private func activate(installing: Bool) {
        guard let identifier = extensionIdentifier else { return }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        pendingIsActivation = true
        activationInstalls = installing
        checking = true
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func openSystemSettings() {
        SystemOpen.openSystemSettingsForExtensions()
    }

    /// Loads the guard's filter configuration; with `install`, adds it (the "filter network content"
    /// prompt) or switches it back on. Then asks the extension itself.
    private func configureFilter(install: Bool) async {
        guard let identifier = extensionIdentifier else { return }
        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
            let ours = manager.providerConfiguration?.filterDataProviderBundleIdentifier == identifier
            if !ours || !manager.isEnabled {
                guard install else {
                    settle(.off)
                    return
                }
                let configuration = NEFilterProviderConfiguration()
                // Every new socket flow of the Mac is asked about; the extension lets any flow of a
                // process it does not hold through at once, unread (GuardFilterProvider).
                configuration.filterSockets = true
                configuration.filterPackets = false
                configuration.filterDataProviderBundleIdentifier = identifier
                manager.providerConfiguration = configuration
                manager.localizedDescription = L("guard.configurationName")
                manager.isEnabled = true
                try await manager.saveToPreferences()
            }
            await connect()
        } catch {
            log.error("filter configuration: \(error.logKind, privacy: .public) \(error.localizedDescription, privacy: .private)")
            if install {
                // The prompt declined: NEFilterErrorDomain's "permission denied".
                let nsError = error as NSError
                let declined = nsError.domain == NEFilterErrorDomain && nsError.code == NEFilterManagerError.configurationPermissionDenied.rawValue
                problem = declined ? .declined : .other(error.localizedDescription)
            }
            settle(.off)
        }
    }

    // MARK: The extension's own answer

    /// The extension's Mach service (its Info.plist), where the app holds and releases processes.
    private var machServiceName: String? {
        guard let identifier = extensionIdentifier,
              let info = Bundle(url: Self.bundledURL(of: identifier))?.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        else { return nil }
        return info["NEMachServiceName"] as? String
    }

    private func connect() async {
        guard let service = machServiceName, let requirement = extensionRequirement else {
            log.error("the guard cannot be asked: no Mach service, or this copy has no team to check the extension against")
            settle(.notAnswering)
            return
        }
        connection?.invalidate()
        let connection = NSXPCConnection(machServiceName: service, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkGuardControl.self)
        // Only our own extension, signed by this app's team, is talked to.
        connection.setCodeSigningRequirement(requirement)
        connection.interruptionHandler = { [weak self, weak connection] in
            Task { @MainActor in if let connection, self?.connection === connection { self?.connectionLost(reason: "interrupted") } }
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in if let connection, self?.connection === connection { self?.connectionLost(reason: "invalidated") } }
        }
        connection.resume()
        self.connection = connection
        guard let answer = await call(connection, { (guardian: NetworkGuardControl, done: @escaping ((String, Bool)) -> Void) in
            guardian.hello { done(($0, $1)) }
        }) else {
            settle(NetworkGuardReading.silent(earlierCopyAwaitsRestart: earlierCopyAwaitsRestart))
            return
        }
        let (version, running) = answer
        let current = version == bundledExtensionVersion
        guard running, current else {
            log.notice("the guard answers, but its filter runs: \(running, privacy: .public), its version is this app's: \(current, privacy: .public)")
            settle(NetworkGuardReading.silent(earlierCopyAwaitsRestart: earlierCopyAwaitsRestart))
            return
        }
        // A restarted extension holds nothing: what this app holds is given to it again, and a
        // process it does not take back loses its profile.
        var refused: [pid_t] = []
        for (pid, registration) in held {
            if await give(registration, to: connection) != nil { refused.append(pid) }
        }
        if !refused.isEmpty {
            for pid in refused { held[pid] = nil }
            log.error("the guard did not take back \(refused.count, privacy: .public) process(es): their profiles stop")
            onHoldsLost?(refused)
        }
        if proven {
            settle(.ready)
            return
        }
        settle(.unproven)
        if !proofFailed { await prove(on: connection) }
    }

    /// Hands one registration to the guard: nil when it took it, the reason otherwise.
    private func give(_ registration: GuardRegistration, to connection: NSXPCConnection) async -> String? {
        guard let data = try? JSONEncoder().encode(registration) else { return "unencodable" }
        guard let answer = await call(connection, { (guardian: NetworkGuardControl, done: @escaping ((Bool, String?)) -> Void) in
            guardian.hold(data) { done(($0, $1)) }
        }) else { return "no answer" }
        return answer.0 ? nil : (answer.1 ?? "refused")
    }

    /// Whether this Mac has shown that the guard holds what WebKit opens for a process — the check
    /// below, for this macOS build, this WebKit and this guard. Until it has, the guard stays
    /// `unproven` and WebRTC off in proxied profiles: holding a process whose connections the
    /// system counts for another would hold nothing. A macOS or Safari update asks again.
    private var proven: Bool {
        UserDefaults.standard.string(forKey: Self.proofKey) == proofIdentity
    }

    private static let proofKey = "PBNetworkGuardProof"

    private var proofIdentity: String {
        let webKit = Bundle(identifier: "com.apple.WebKit")?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(Self.systemBuild)|\(webKit)|\(bundledExtensionVersion ?? "?")"
    }

    private static var systemBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    /// The check on this Mac (docs/TUNNEL.md, "Attribution"): a probe process of this app
    /// (`GuardProbe`, nothing of the person's in it) is held to a proxy that is not there, then asks
    /// a STUN server at a documentation address with WebKit's own WebRTC. The guard holds a profile
    /// only if it saw that flow as the probe's, opened for it by WebKit, and dropped it
    /// (`GuardProof`). The request reaches no one either way: the address is never routed.
    private func prove(on connection: NSXPCConnection) async {
        // The probe stands in for a profile's process: started as one is (`ProfileExecutable`), so
        // what the guard is shown to see is what it sees of a profile.
        guard !proving, let executable = try? ProfileExecutable.url() else { return }
        proving = true
        defer { proving = false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--guard-probe"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("the guard's check could not start its probe: \(error.logKind, privacy: .public)")
            proofFailed = true
            return
        }
        let pid = process.processIdentifier
        let registration = GuardRegistration(pid: pid, proxyHost: "127.0.0.1", proxyPort: 9, proxyAddresses: [])
        if let refusal = await give(registration, to: connection) {
            // Not held: the probe is told nothing and sends nothing.
            log.error("the guard did not take its probe: \(refusal, privacy: .public)")
            try? input.fileHandleForWriting.close()
            process.terminate()
            proofFailed = true
            return
        }
        try? input.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
        try? input.fileHandleForWriting.close()
        for _ in 0..<250 where process.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        if process.isRunning { process.terminate() }
        let data = await call(connection, { (guardian: NetworkGuardControl, done: @escaping (Data) -> Void) in
            guardian.report(pid) { done($0) }
        })
        _ = await call(connection, { (guardian: NetworkGuardControl, done: @escaping (Bool) -> Void) in
            guardian.release(pid) { done(true) }
        })
        let report = data.flatMap { try? JSONDecoder().decode(GuardReport.self, from: $0) }
        guard let report, GuardProof.holds(report) else {
            log.error("the guard's check failed: dropped \(report?.dropped ?? -1, privacy: .public), seen on the probe's behalf \(report?.seenOnItsBehalf ?? -1, privacy: .public)")
            proofFailed = true
            return
        }
        UserDefaults.standard.set(proofIdentity, forKey: Self.proofKey)
        log.notice("the guard holds what WebKit opens for a process on this Mac: proven")
        if self.connection === connection, installedState == .unproven { settle(.ready) }
    }

    /// The guard is gone for the processes it held: their profiles are stopped, and it is asked
    /// again in a moment (a restarted extension, an update's).
    private func connectionLost(reason cause: String) {
        let lost = Array(held.keys)
        connection?.invalidate()
        connection = nil
        heartbeat?.invalidate()
        heartbeat = nil
        if installedState == .ready || installedState == .unproven { installedState = .notAnswering }
        guard !lost.isEmpty else { return }
        log.error("the guard stopped answering (\(cause, privacy: .public)) while holding \(lost.count, privacy: .public) process(es): their profiles stop")
        held.removeAll()
        onHoldsLost?(lost)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.refresh()
        }
    }

    // MARK: Holding a profile's process

    /// Asks the guard to hold the process `pid` — a profile's own process, and what WebKit's
    /// processes and the system do on its behalf — to `proxy`. False when it did not: the profile
    /// then runs with WebRTC off.
    func hold(pid: pid_t, proxy: ProxySettings) async -> Bool {
        if selfTestStandIn {
            log.notice("self-test: a stand-in takes the guard's place for process \(pid, privacy: .public)")
            standIns.insert(pid)
            return true
        }
        guard installedState == .ready, let connection, let port = UInt16(exactly: proxy.port) else { return false }
        let registration = GuardRegistration(pid: pid, proxyHost: proxy.host, proxyPort: port,
                                             proxyAddresses: await Self.addresses(of: proxy.host))
        if let refusal = await give(registration, to: connection) {
            log.error("the guard did not take process \(pid, privacy: .public): \(refusal, privacy: .public)")
            return false
        }
        held[pid] = registration
        startHeartbeat()
        return true
    }

    /// The process is gone or its profile stopped.
    func release(pid: pid_t) {
        standIns.remove(pid)
        guard held.removeValue(forKey: pid) != nil, let connection else { return }
        if held.isEmpty {
            heartbeat?.invalidate()
            heartbeat = nil
        }
        Task {
            _ = await call(connection, { (guardian: NetworkGuardControl, done: @escaping (Bool) -> Void) in
                guardian.release(pid) { done(true) }
            })
        }
    }

    /// What the guard did for `pid` (for the self-test and the check on this Mac).
    func report(pid: pid_t) async -> GuardReport? {
        guard let connection else { return nil }
        let data = await call(connection, { (guardian: NetworkGuardControl, done: @escaping (Data) -> Void) in
            guardian.report(pid) { done($0) }
        })
        return data.flatMap { try? JSONDecoder().decode(GuardReport.self, from: $0) }
    }

    /// While it holds processes, the guard is asked every 5 seconds whether its filter still runs:
    /// switched off in System Settings, the extension lives on but filters nothing.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let connection = self.connection, !self.held.isEmpty else { return }
                Task { @MainActor in
                    let answer = await self.call(connection, { (guardian: NetworkGuardControl, done: @escaping ((String, Bool)) -> Void) in
                        guardian.hello { done(($0, $1)) }
                    })
                    if answer?.1 != true, self.connection === connection { self.connectionLost(reason: "filter not running") }
                }
            }
        }
    }

    /// One call to the guard: its answer, or nil when it failed or took longer than `seconds`.
    private func call<T>(_ connection: NSXPCConnection, seconds: Double = 5,
                         _ body: @escaping (NetworkGuardControl, @escaping (T) -> Void) -> Void) async -> T? {
        await Self.ask(connection, seconds: seconds, body)
    }

    // MARK: The bundled extension

    private static func bundledURL(of identifier: String) -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension")
    }

    /// CFBundleVersion of the extension inside this app (a new one per build, scripts/build-app.sh).
    private var bundledExtensionVersion: String? {
        guard let identifier = extensionIdentifier else { return nil }
        return Bundle(url: Self.bundledURL(of: identifier))?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private var extensionRequirement: String? {
        extensionIdentifier.flatMap { Self.requirement(for: $0) }
    }

    /// What the guard's code must be: `identifier`, signed by the team that signed this app; nil for
    /// a copy without a team (ad hoc), which then talks to no guard.
    static func requirement(for identifier: String) -> String? {
        ownTeamIdentifier().map { "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\($0)\"" }
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Every address of the proxy's host, as this Mac resolves it (an IP literal is its own): the
    /// guard lets the profile reach those, and the name itself.
    nonisolated static func addresses(of host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: Set<String> = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addresses.insert(String(cString: buffer))
                    }
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: addresses.sorted())
            }
        }
    }
}

/// Resumes a continuation once, whichever of an answer, an error or a timeout comes first.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension NetworkGuard: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // This app's own extension replaces an older one (an update): the person allowed the guard
        // once, for this team and this identifier.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { settle(.awaitingApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            pendingRequest = nil
            pendingIsActivation = false
            switch result {
            case .completed:
                let install = activationInstalls
                Task { await configureFilter(install: install) }
            case .willCompleteAfterReboot:
                // Installed and switched on as far as the person goes; macOS runs it after a
                // restart. Not "not installed": nothing more is to be installed or allowed.
                problem = .reboot
                settle(.restartNeeded)
            @unknown default:
                problem = .other("\(result.rawValue)")
                settle(.notInstalled)
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            log.error("system extension request: \(error.logKind, privacy: .public) \(error.localizedDescription, privacy: .private)")
            let activation = pendingIsActivation
            pendingRequest = nil
            pendingIsActivation = false
            // A properties request that fails (an extension never installed) just means it is not.
            guard activation else {
                settle(.notInstalled)
                return
            }
            switch (error as? OSSystemExtensionError)?.code {
            case .requestCanceled?: break
            case .unsupportedParentBundleLocation?: problem = .location
            case .missingEntitlement?, .codeSignatureInvalid?, .validationFailed?, .extensionNotFound?, .extensionMissingIdentifier?:
                problem = .signing
            case .authorizationRequired?: problem = .authorization
            case .forbiddenBySystemPolicy?: problem = .policy
            default: problem = .other(error.localizedDescription)
            }
            settle(.notInstalled)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        MainActor.assumeIsolated {
            pendingRequest = nil
            extensionProperties(properties)
        }
    }
}

// MARK: - What `Lumen --guard-diagnose` shares with the app's own guard (GuardDiagnosis.swift)

extension NetworkGuard {
    /// The guard bundled in this copy of the app, as the app itself talks to it: its identifier, its
    /// Mach service, its version, and the requirement its code must meet (nil without a team: an ad
    /// hoc copy talks to no guard). Nil when this copy has no guard.
    static func bundledGuard() -> (identifier: String, machService: String?, version: String?, requirement: String?)? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: NetworkGuardNames.appInfoKey) as? String else { return nil }
        let bundle = Bundle(url: bundledURL(of: identifier))
        let machService = (bundle?.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any])?["NEMachServiceName"] as? String
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return (identifier, machService, version, requirement(for: identifier))
    }

    /// One call to the guard: its answer, or nil when it failed or took longer than `seconds` (a
    /// guard of an older build does not answer a call it does not have).
    static func ask<T>(_ connection: NSXPCConnection, seconds: Double = 5,
                       _ body: @escaping (NetworkGuardControl, @escaping (T) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once(continuation)
            guard let guardian = connection.remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) }) as? NetworkGuardControl else {
                once.resume(nil)
                return
            }
            body(guardian) { once.resume($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
        }
    }
}
