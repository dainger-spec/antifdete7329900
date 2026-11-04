import BrowserCore
import Foundation
import Network
import os

/// The local automation API (`AutomationHTTP`) on 127.0.0.1, for as long as the vault is
/// unlocked and the API is on. Every connection is one request and one answer, and no request is
/// acted on before `AutomationGate` lets it through. Only the build without the App Sandbox
/// listens: the sandboxed one has no entitlement to accept connections.
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
        listener.stateUpdateHandler = { [weak self] update in
            MainActor.assumeIsolated { self?.listenerChanged(update) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
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
