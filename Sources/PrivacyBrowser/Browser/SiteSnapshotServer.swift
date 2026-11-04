import BrowserCore
import Foundation
import Network
import os

/// The listener of a "What sites see" snapshot (`WhatSitesSee`): on 127.0.0.1 only, on ports the
/// system picks, for as long as one snapshot takes.
///
/// Over HTTP it serves the measuring page (`SiteSnapshotPage`), records the header lines of the
/// page's own requests in the order they came — what the headers script reads back from `/echo` —
/// and takes the page's report. On a second port it reads the ClientHello of the page's https
/// request and closes the connection: no certificate, no handshake; the ClientHello is what a
/// server sees before anything is encrypted, and all this needs. Requests are answered only for
/// the snapshot's own tokens and only when they name this Mac by its loopback address (a name of
/// a page's that resolves here — DNS rebinding — is refused).
@MainActor
final class SiteSnapshotServer {
    private struct RecordedRequest: Encodable {
        var path: String
        var headers: [[String]]
    }

    private(set) var httpPort: UInt16 = 0
    private(set) var tlsPort: UInt16 = 0
    private var http: NWListener?
    private var tls: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tokens: Set<String> = []
    private var requests: [String: [RecordedRequest]] = [:]
    private var reports: [String: Data] = [:]
    private var clientHellos: [String: TLSClientHello] = [:]
    /// The token whose page asked last: the side being measured, whose https request comes next.
    private var currentToken: String?
    private let page: (_ token: String, _ tlsPort: UInt16) -> String
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SiteSnapshot")

    /// `page`: the measuring page for a token.
    init(page: @escaping (_ token: String, _ tlsPort: UInt16) -> String) {
        self.page = page
    }

    /// Listens on two ports of 127.0.0.1; false when either could not (and nothing listens).
    func start() async -> Bool {
        do {
            http = try listener { [weak self] in self?.acceptHTTP($0) }
            tls = try listener { [weak self] in self?.acceptTLS($0) }
        } catch {
            Self.log.error("Could not listen for a snapshot: \(error.logKind, privacy: .public)")
            stop()
            return false
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let httpPort = ready(http), let tlsPort = ready(tls) {
                self.httpPort = httpPort
                self.tlsPort = tlsPort
                Self.log.notice("Snapshot listening on 127.0.0.1:\(httpPort, privacy: .private) and :\(tlsPort, privacy: .private)")
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        stop()
        return false
    }

    func stop() {
        http?.cancel()
        tls?.cancel()
        http = nil
        tls = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    /// A new side's page: its address, which only this snapshot answers.
    func newPage(_ side: SiteSnapshotPage.Side) -> (token: String, url: URL) {
        let token = SiteSnapshotPage.token(side)
        tokens.insert(token)
        return (token, SiteSnapshotPage.url(port: httpPort, token: token))
    }

    /// The page's report and the ClientHello of its https request, once the report has come;
    /// nil when it has not within `timeout`.
    func measured(_ token: String, timeout: TimeInterval) async -> (report: Data, clientHello: TLSClientHello?)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let report = reports[token] { return (report, clientHellos[token]) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return reports[token].map { ($0, clientHellos[token]) }
    }

    // MARK: Listening

    private func listener(_ accept: @escaping (NWConnection) -> Void) throws -> NWListener {
        let parameters = NWParameters.tcp
        // The loopback address and nothing else: no other machine can reach it.
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { accept(connection) }
        }
        listener.start(queue: .main)
        return listener
    }

    private func ready(_ listener: NWListener?) -> UInt16? {
        guard let listener, listener.state == .ready, let port = listener.port?.rawValue, port != 0 else { return nil }
        return port
    }

    private func track(_ connection: NWConnection) -> Bool {
        guard connections.count < 32 else {
            connection.cancel()
            return false
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        return true
    }

    // MARK: HTTP

    private func acceptHTTP(_ connection: NWConnection) {
        guard track(connection) else { return }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch AutomationHTTP.parse(buffer) {
                case .incomplete:
                    if isComplete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                case .invalid(let response):
                    self.send(response, on: connection)
                case .request(let request):
                    self.answer(request, on: connection)
                }
            }
        }
    }

    private func answer(_ request: AutomationHTTP.Request, on connection: NWConnection) {
        let host = request.headers["host"] ?? ""
        guard host == "127.0.0.1:\(httpPort)" || host == "localhost:\(httpPort)",
              let token = request.query["token"], tokens.contains(token) else {
            send(.error(404, "not_found", "Nothing here."), on: connection)
            return
        }
        currentToken = token
        requests[token, default: []].append(RecordedRequest(path: request.path, headers: request.headerLines))
        func text(_ body: String, _ type: String = "text/plain; charset=utf-8") -> AutomationHTTP.Response {
            AutomationHTTP.Response(status: 200, contentType: type, body: Data(body.utf8))
        }
        switch (request.method, request.path) {
        case ("GET", "/headers.html"):
            send(text(page(token, tlsPort), "text/html; charset=utf-8"), on: connection)
        case ("GET", "/fetch.txt"), ("GET", "/xhr.txt"):
            send(text("ok"), on: connection)
        case ("GET", "/echo"):
            let body = (try? JSONEncoder().encode(requests[token] ?? [])) ?? Data("[]".utf8)
            send(AutomationHTTP.Response(status: 200, body: body), on: connection)
        case ("POST", "/report"):
            if reports[token] == nil { reports[token] = request.body }
            send(text("ok"), on: connection)
        default:
            send(.error(404, "not_found", "Nothing here."), on: connection)
        }
    }

    private func send(_ response: AutomationHTTP.Response, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: TLS

    private func acceptTLS(_ connection: NWConnection) {
        guard track(connection) else { return }
        readHello(on: connection, buffer: [])
    }

    private func readHello(on connection: NWConnection, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer += data }
                do {
                    let hello = try TLSClientHello.parse(buffer)
                    if let token = self.currentToken, self.clientHellos[token] == nil { self.clientHellos[token] = hello }
                    connection.cancel()
                } catch TLSClientHello.ParseError.incomplete where !isComplete && error == nil && buffer.count < 64 * 1024 {
                    self.readHello(on: connection, buffer: buffer)
                } catch {
                    connection.cancel()
                }
            }
        }
    }
}
