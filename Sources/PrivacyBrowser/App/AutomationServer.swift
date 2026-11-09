import BrowserCore
import Foundation
import Network
import os

/// The local automation API (`AutomationHTTP`) on 127.0.0.1, for as long as the vault is
/// unlocked and the API is on. Every connection is one request and one answer, and no request is
/// acted on before `AutomationGate` lets it through. Only the build without the App Sandbox
/// offers it: the sandboxed one listens for nothing but a "What sites see" snapshot, on
/// 127.0.0.1 while one is taken (`SiteSnapshotServer`), and never for scripts.
@MainActor
final class AutomationServer {
    enum State: Equatable {
        case stopped
        case listening(port: Int)
        case failed(String)
    }

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "Automation")
    /// Connections at once; more are closed at once.
    static let maximumConnections = 8
    /// A connection that has not sent its whole request by then is closed.
    static let requestTimeout: TimeInterval = 15

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    private let settings: AutomationSettings
    private let handler: AutomationHandler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    static var isAvailable: Bool { !AppEnvironment.isSandboxed }

    init(settings: AutomationSettings, handler: AutomationHandler) {
        self.settings = settings
        self.handler = handler
    }

    /// Listens on `settings.port` (0: any free port, which `state` then names).
    func start() {
        guard listener == nil else { return }
        guard Self.isAvailable else {
            state = .failed(L("automation.error.sandboxed"))
            return
        }
        guard settings.port == 0 || AutomationSettings.ports.contains(settings.port),
              let port = settings.port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: UInt16(settings.port)) else {
            state = .failed(String(format: L("automation.error.port"), settings.port))
            return
        }
        let parameters = NWParameters.tcp
        // The loopback address and nothing else: no other machine can reach it.
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        // Only the current listener is heard: `stop()` cancels one, and cancelling is asynchronous —
        // a connection it took meanwhile is closed unanswered, and its late states change nothing.
        listener.stateUpdateHandler = { [weak self, weak listener] update in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                self.listenerChanged(update)
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        state = .stopped
    }

    private func listenerChanged(_ update: NWListener.State) {
        switch update {
        case .ready:
            let port = Int(listener?.port?.rawValue ?? UInt16(settings.port))
            Self.log.notice("Automation API listening on 127.0.0.1:\(port)")
            state = .listening(port: port)
        case .failed(let error):
            Self.log.error("Automation API could not listen: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            listener?.cancel()
            listener = nil
            state = .failed(error.localizedDescription)
        case .cancelled:
            if case .listening = state { state = .stopped }
        default:
            break
        }
    }

    private var listeningPort: Int {
        if case .listening(let port) = state { return port }
        return settings.port
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] update in
            switch update {
            case .failed, .cancelled:
                MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let connection = self.connections[id], !self.answering.contains(id) else { return }
                connection.cancel()
            }
        }
    }

    /// Connections whose request is being acted on (a launch can take longer than the timeout).
    private var answering: Set<ObjectIdentifier> = []

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch AutomationHTTP.parse(buffer) {
                case .incomplete:
                    if isComplete || error != nil {
                        connection.cancel()
                    } else {
                        self.receive(on: connection, buffer: buffer)
                    }
                case .invalid(let response):
                    self.send(response, on: connection)
                case .request(let request):
                    self.answer(request, on: connection)
                }
            }
        }
    }

    private func answer(_ request: AutomationHTTP.Request, on connection: NWConnection) {
        if let refusal = AutomationGate.refusal(of: request, token: settings.token, port: listeningPort) {
            Self.log.notice("Automation API refused a request: \(refusal.status)")
            send(refusal, on: connection)
            return
        }
        switch AutomationRoute.of(request) {
        case .failure(let refusal):
            send(refusal.response, on: connection)
        case .success(let route):
            let id = ObjectIdentifier(connection)
            answering.insert(id)
            Task { @MainActor in
                let response = await self.handler.handle(route)
                self.answering.remove(id)
                self.send(response, on: connection)
            }
        }
    }

    private func send(_ response: AutomationHTTP.Response, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// What the automation API's routes do: through the same `ProfileManager` as the app's own
/// buttons, so a profile started from a script is the profile started from the list — its proxy,
/// its process, its sealing.
@MainActor
final class AutomationHandler {
    private let manager: ProfileManager
    private let repository: ProfileRepository
    /// A launch reads the files a sync replaces: it waits for the sync (`AppModel.launch`).
    var waitForSync: () async -> Void = {}
    /// Something changed that the Profiles list shows.
    var onChange: () -> Void = {}
    /// Whether the plan has scenario automation; without it the scenario routes refuse, saying so.
    var allowsAutomation: () -> Bool = { false }
    /// A saved scenario by its exact name (one), for `{"scenario": "…"}`.
    var savedScenario: (String) -> Scenario? = { _ in nil }

    init(manager: ProfileManager, repository: ProfileRepository) {
        self.manager = manager
        self.repository = repository
    }

    func handle(_ route: AutomationRoute) async -> AutomationHTTP.Response {
        switch route {
        case .listProfiles:
            return .json(200, repository.list().map(entry))
        case .profile(let reference):
            return await profile(reference) { .json(200, self.entry($0)) }
        case .start(let reference, let window):
            return await profile(reference) { summary in
                if manager.isRunning(summary.id) { return .json(200, entry(summary)) }
                await waitForSync()
                do {
                    try await manager.launch(summary.id, openingWindow: window)
                } catch {
                    return .error(409, "launch_failed", error.localizedDescription)
                }
                onChange()
                return .json(200, entry(summary))
            }
        case .stop(let reference):
            return await profile(reference) { summary in
                do {
                    try await manager.stop(summary.id)
                } catch {
                    return .error(500, "stop_failed", error.localizedDescription)
                }
                onChange()
                return .json(200, entry(summary))
            }
        case .open(let reference, let url):
            return await profile(reference) { summary in
                guard manager.isRunning(summary.id) else {
                    return .error(409, "not_running", "Start the profile first (POST …/start).")
                }
                manager.openWindow(summary.id, url: url)
                return .json(200, entry(summary))
            }
        case .exportCookies(let reference, let format):
            return await profile(reference) { summary in
                do {
                    let cookies = try await manager.exportCookies(of: summary.id)
                    return AutomationHTTP.Response(status: 200, contentType: format == .netscape ? "text/plain; charset=utf-8" : "application/json",
                                                   body: CookieExport.data(cookies, format: format))
                } catch {
                    return .error(409, "busy", error.localizedDescription)
                }
            }
        case .runScenario(let reference, let spec):
            guard allowsAutomation() else { return Self.notInPlan }
            return await profile(reference) { summary in
                guard manager.isRunning(summary.id) else {
                    return .error(409, "not_running", "Start the profile first (POST …/start).")
                }
                let name: String, source: String
                if let text = spec.source {
                    (name, source) = ("API", text)
                } else if let wanted = spec.scenario, let saved = savedScenario(wanted) {
                    (name, source) = (saved.name, saved.source)
                } else {
                    return .error(404, "no_scenario", "No saved scenario is named \(spec.scenario ?? "") (exactly, one).")
                }
                let runID = UUID()
                guard manager.runScenario(summary.id, name: name, source: source, parametersJSON: spec.parametersJSON, runID: runID) else {
                    return .error(409, "busy", "A run of this profile is still going (POST …/scenario/stop).")
                }
                return .json(202, ScenarioAnswer(runID: runID.uuidString))
            }
        case .scenarioState(let reference):
            guard allowsAutomation() else { return Self.notInPlan }
            return await profile(reference) { summary in
                guard let run = manager.scenarioRuns[summary.id] else {
                    return .error(404, "no_run", "This profile has not run a scenario since the vault was unlocked.")
                }
                return .json(200, ScenarioState(run))
            }
        case .stopScenario(let reference):
            guard allowsAutomation() else { return Self.notInPlan }
            return await profile(reference) { summary in
                guard manager.scenarioRuns[summary.id]?.isRunning == true else {
                    return .error(409, "not_running", "No run of this profile is going.")
                }
                manager.stopScenario(summary.id)
                return .json(202, ScenarioAnswer(runID: manager.scenarioRuns[summary.id]?.runID.uuidString ?? ""))
            }
        case .importCookies(let reference, let data):
            return await profile(reference) { summary in
                let report = CookieImporter.read(data)
                guard !report.cookies.isEmpty else {
                    return .error(400, "no_cookies", "No cookie could be read from the body (\(report.failures.count) entries left out).")
                }
                do {
                    switch try await manager.importCookies(report.cookies, into: summary.id) {
                    case .applied(let stored, let refused):
                        return .json(200, ImportAnswer(applied: stored, refused: refused.count, queued: nil, leftOut: report.failures.count))
                    case .queued(let count):
                        return .json(200, ImportAnswer(applied: nil, refused: nil, queued: count, leftOut: report.failures.count))
                    }
                } catch {
                    return .error(409, "busy", error.localizedDescription)
                }
            }
        }
    }

    /// The scenario routes without automation in the plan: said, with the reason.
    private static let notInPlan = AutomationHTTP.Response.error(403, "automation_not_in_plan",
        "Running scenarios is part of the plan with automation; this license's plan does not include it.")

    private struct ScenarioAnswer: Encodable {
        var runID: String
    }

    /// A run as the API gives it: the log's lines with their times and kinds, and how it ended.
    private struct ScenarioState: Encodable {
        struct Line: Encodable {
            var at: Date
            var kind: String
            var text: String
        }

        var runID: String
        var name: String
        var startedAt: Date
        var running: Bool
        /// "finished", "failed", "stopped" — nil while running.
        var outcome: String?
        /// Why it failed or stopped.
        var reason: String?
        var lines: [Line]

        init(_ run: ProfileManager.ScenarioRunState) {
            runID = run.runID.uuidString
            name = run.name
            startedAt = run.startedAt
            running = run.isRunning
            switch run.outcome {
            case nil: outcome = nil
            case .finished?: outcome = "finished"
            case .failed(let message)?: outcome = "failed"; reason = message
            case .stopped(let why)?: outcome = "stopped"; reason = why.rawValue
            }
            lines = run.lines.map { Line(at: $0.at, kind: $0.kind.rawValue, text: $0.text) }
        }
    }

    /// `applied`: into the running profile's store now (`refused`: those WebKit did not keep);
    /// `queued`: the profile is stopped, and this many wait for its next launch. `leftOut`: entries
    /// of the file that could not be read.
    private struct ImportAnswer: Encodable {
        var applied: Int?
        var refused: Int?
        var queued: Int?
        var leftOut: Int
    }

    private func entry(_ summary: ProfileSummary) -> AutomationProfiles.Entry {
        AutomationProfiles.Entry(summary, running: manager.isRunning(summary.id),
                                 busy: manager.busyProfileIDs.contains(summary.id),
                                 proxy: (try? repository.loadConfiguration(summary.id))?.proxy)
    }

    private func profile(_ reference: String, _ body: (ProfileSummary) async -> AutomationHTTP.Response) async -> AutomationHTTP.Response {
        switch AutomationProfiles.find(reference, in: repository.list()) {
        case .failure(let refusal): return refusal.response
        case .success(let summary): return await body(summary)
        }
    }
}
