import SwiftUI
#if DEBUG
import Foundation
import LumenCore
import Network
import SwiftUI
import UIKit
import WebKit

/// The network-switch measurement (DEBUG builds only; ios/DEVICE.md, q4). A page in a session asks
/// an address-echo service twice a second, through the session — its relay, its proxy — while the
/// person switches the iPhone from Wi-Fi to cellular and back. Meanwhile the app asks the same
/// service itself, never through any proxy, over each network, and so learns the device's own
/// addresses. Any answer to the page that carries one of them is a leak: that request went around
/// the proxy. The verdict is the probe's, not the person's.
@MainActor
final class NetProbe: NSObject, ObservableObject, WKScriptMessageHandler {
    struct Answer {
        let time: Date
        let url: String
        let ip: String?
        let error: String?
        let network: String
    }

    @Published private(set) var running = false
    @Published private(set) var answers: [Answer] = []
    @Published private(set) var ownAddresses: Set<String> = []
    @Published private(set) var network = "?"
    /// A VPN's interface that carried the default route at some point of the run, if any: then the
    /// device's "own" address is the VPN's and a network switch is hidden from the app (the owner's
    /// runs of 8 November had a fake-IP VPN on).
    @Published private(set) var tunnel: String?
    /// The device's side of the worker check (SettingsTests checks it on the simulator): does a worker
    /// made from a blob read this session's canvas as its page does? With canvas noise it does only
    /// with the worker hook of the mac app's fix (8 November).
    @Published private(set) var workerCheck = ""
    @Published private(set) var timeline: [String] = []
    @Published private(set) var webView: WKWebView?
    private var monitor: NWPathMonitor?
    private var refresh: Timer?
    private var started = Date()
    private var subject = ""

    /// What the page asks (through the session). A test points it at its testbed.
    static var echoURLs: [String] {
        if let value = ProcessInfo.processInfo.environment["LUMEN_TEST_ECHO"] { return [value] }
        return ["https://api.ipify.org/?format=json", "https://api64.ipify.org/?format=json"]
    }

    /// What the app asks itself, in plain HTTP and never through a proxy: another echo service, so
    /// that a recording of the iPhone's packets (scripts/run-device.sh) can tell the app's own direct
    /// questions from the page's, which must reach ipify only through the proxy.
    static var ownEchoes: [OwnAddress.Echo] {
        if let value = ProcessInfo.processInfo.environment["LUMEN_TEST_ECHO"], let url = URL(string: value), let host = url.host {
            return [OwnAddress.Echo(host: host, port: UInt16(url.port ?? 80), path: url.path.isEmpty ? "/" : url.path)]
        }
        return [OwnAddress.Echo(host: "ipv4.icanhazip.com", port: 80, path: "/"),
                OwnAddress.Echo(host: "ipv6.icanhazip.com", port: 80, path: "/")]
    }

    func start(runtime: SessionRuntime) {
        stop()
        answers = []
        timeline = []
        ownAddresses = []
        tunnel = nil
        workerCheck = ""
        started = Date()
        running = true
        subject = "сессия «\(runtime.session.name)», " + (runtime.proxy.map { "прокси \($0.kind.rawValue.uppercased())" } ?? "без прокси")
        note("начало: \(subject)")
        watchNetwork()
        learnOwnAddresses()
        refresh = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.learnOwnAddresses() }
        }
        let configuration = runtime.makeConfiguration()
        configuration.userContentController.add(self, name: "lumenProbe")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 90), configuration: configuration)
        view.customUserAgent = PageSettings.userAgent(for: runtime.session)
        view.loadHTMLString(Self.page(urls: Self.echoURLs), baseURL: nil)
        webView = view
    }

    func stop() {
        guard running else { return }
        running = false
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "lumenProbe")
        webView?.stopLoading()
        webView = nil
        monitor?.cancel()
        monitor = nil
        refresh?.invalidate()
        refresh = nil
        note("конец")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard running, let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == "worker" {
            let page = body["page"] as? String ?? "", worker = body["worker"] as? String ?? ""
            workerCheck = !page.isEmpty && page == worker
                ? "воркер из blob: тот же канвас, что у страницы (\(page))"
                : "воркер из blob: ДРУГОЙ канвас — страница \(page.isEmpty ? "?" : page), воркер \(worker)"
            note(workerCheck)
            return
        }
        answers.append(Answer(time: Date(), url: body["url"] as? String ?? "", ip: body["ip"] as? String,
                              error: body["error"] as? String, network: network))
    }

    // MARK: The verdict

    var leaks: [Answer] { answers.filter { $0.ip.map(ownAddresses.contains) ?? false } }
    var throughProxy: [Answer] { answers.filter { $0.ip.map { !ownAddresses.contains($0) } ?? false } }
    var errors: Int { answers.filter { $0.ip == nil }.count }

    var verdict: String {
        let invalid = tunnel.map { "НЕДЕЙСТВИТЕЛЬНО: сеть шла через VPN (\($0)) — выключите VPN и повторите. " } ?? ""
        return invalid + plainVerdict
    }

    private var plainVerdict: String {
        if answers.isEmpty { return "Ответов пока нет" }
        let leaked = leaks
        if !leaked.isEmpty {
            return "УТЕЧКА: \(leaked.count) из \(answers.count) ответов — с настоящим адресом устройства (\(Self.list(leaked)))"
        }
        if ownAddresses.isEmpty { return "Не проверено: настоящие адреса устройства неизвестны" }
        return "Утечек нет: \(throughProxy.count) ответов, ни одного с адреса устройства (адреса: \(Self.list(throughProxy))); ошибок: \(errors)"
    }

    private static func list(_ answers: [Answer]) -> String { Set(answers.compactMap(\.ip)).sorted().joined(separator: ", ") }

    /// Everything, for the person to send: the device, the verdict, the networks, every answer.
    var report: String {
        var lines = ["Lumen — замер смены сети", "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)",
                     "начало \(ISO8601DateFormatter().string(from: started))", subject,
                     "адреса устройства: \(ownAddresses.sorted().joined(separator: ", "))", "ИТОГ: \(verdict)",
                     workerCheck.isEmpty ? "воркер из blob: не проверен" : workerCheck, ""]
        lines += timeline
        lines.append("")
        for answer in answers {
            let kind = answer.ip.map { ownAddresses.contains($0) ? "УТЕЧКА" : "прокси" } ?? "ошибка"
            lines.append(String(format: "%7.1f с  ", answer.time.timeIntervalSince(started))
                         + "\(answer.network) | \(answer.url) | \(answer.ip ?? answer.error ?? "") | \(kind)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: The networks and the device's own addresses

    private func note(_ text: String) {
        timeline.append(String(format: "%7.1f с  ", Date().timeIntervalSince(started)) + text)
    }

    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let text = NetProbe.describe(path)
            let vpn = NetProbe.tunnelName(path)
            Task { @MainActor in self?.networkChanged(text, tunnel: vpn) }
        }
        monitor.start(queue: DispatchQueue(label: "lumen.probe.path"))
        self.monitor = monitor
    }

    nonisolated static func describe(_ path: NWPath) -> String {
        let primary = path.availableInterfaces.first.map { "\($0.type) \($0.name)" } ?? "нет"
        return "\(path.status), \(primary)"
    }

    /// The default route's interface when it is a tunnel (utun…, ipsec…, ppp…): a VPN's.
    nonisolated static func tunnelName(_ path: NWPath) -> String? {
        guard let first = path.availableInterfaces.first, first.type == .other else { return nil }
        return ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: { first.name.hasPrefix($0) }) ? first.name : nil
    }

    private func networkChanged(_ text: String, tunnel vpn: String?) {
        guard running else { return }
        if let vpn, tunnel == nil {
            tunnel = vpn
            note("VPN: основной маршрут через \(vpn)")
        }
        guard text != network else { return }
        network = text
        note("сеть: \(text)")
        learnOwnAddresses()
    }

    /// Over the default route and over each kind of network the device may have: what the services
    /// see when the app asks them directly.
    private func learnOwnAddresses() {
        let kinds: [NWInterface.InterfaceType?] = [nil, .wifi, .cellular, .wiredEthernet]
        for echo in Self.ownEchoes {
            for kind in kinds {
                OwnAddress.fetch(echo, over: kind) { [weak self] ip in
                    guard let ip else { return }
                    Task { @MainActor in self?.learned(ip, over: kind) }
                }
            }
        }
    }

    private func learned(_ ip: String, over kind: NWInterface.InterfaceType?) {
        guard running, !Faults.isActive(.probeBlind) else { return }   // the planted fault: the probe never knows them
        if ownAddresses.insert(ip).inserted {
            note("адрес устройства \(ip) (\(kind.map { "\($0)" } ?? "основной маршрут"))")
        }
    }

    // MARK: The page

    static func page(urls: [String]) -> String {
        let list = (try? String(data: JSONSerialization.data(withJSONObject: urls), encoding: .utf8)) ?? "[]"
        return """
        <!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width">
        <title>Замер сети</title></head><body style="font: 13px -apple-system; margin: 6px">
        <div id=s>…</div><script>
        const URLS = \(list);
        let n = 0, ok = 0, bad = 0;
        function post(m) { try { window.webkit.messageHandlers.lumenProbe.postMessage(m); } catch (e) {} }
        async function once() {
          const base = URLS[n % URLS.length];
          const url = base + (base.includes('?') ? '&' : '?') + 'n=' + (n++);
          const ctl = new AbortController();
          const timer = setTimeout(() => ctl.abort(), 4000);
          try {
            const r = await fetch(url, { cache: 'no-store', signal: ctl.signal });
            const j = await r.json();
            ok++;
            post({ url: base, ip: String(j.ip) });
          } catch (e) {
            bad++;
            post({ url: base, error: String((e && e.name) || e) });
          }
          clearTimeout(timer);
          document.getElementById('s').textContent = 'ответов ' + ok + ', ошибок ' + bad;
        }
        once();
        setInterval(once, 500);
        // The worker check: the same drawing on an OffscreenCanvas, here and in a worker made from a blob.
        const paint = (c) => { const x = c.getContext('2d'); x.textBaseline = 'top'; x.font = '14px Arial';
          x.fillStyle = '#f60'; x.fillRect(125, 1, 62, 20); x.fillStyle = '#069'; x.fillText('Lumen probe Cwm fjordbank glyphs vext quiz', 2, 15);
          x.fillStyle = 'rgba(102, 204, 0, 0.7)'; x.fillText('Lumen probe', 4, 35);
          const d = x.getImageData(0, 0, c.width, c.height).data; let h = 0x811c9dc5;
          for (let i = 0; i < d.length; i++) { h ^= d[i]; h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(16); };
        (async () => {
          try {
            paint(new OffscreenCanvas(240, 60));
            const mine = paint(new OffscreenCanvas(240, 60));
            const src = 'const paint = ' + paint.toString() + '; paint(new OffscreenCanvas(240, 60)); postMessage(paint(new OffscreenCanvas(240, 60)));';
            const worker = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
            const theirs = await new Promise((done) => {
              const timer = setTimeout(() => done('нет ответа за 10 с'), 10000);
              worker.onmessage = (e) => { clearTimeout(timer); done(String(e.data)); worker.terminate(); };
              worker.onerror = (e) => { clearTimeout(timer); done('ошибка ' + (e.message || e)); };
            });
            post({ kind: 'worker', page: mine, worker: theirs });
          } catch (e) { post({ kind: 'worker', page: '', worker: 'ошибка ' + e }); }
        })();
        </script></body></html>
        """
    }
}

/// The device's own address, as an echo service sees it when the app asks it directly: plain HTTP
/// on a TCP connection that no proxy may carry, over a given kind of network if asked.
enum OwnAddress {
    struct Echo {
        let host: String
        let port: UInt16
        let path: String
    }

    private final class Fetch: @unchecked Sendable {
        private let lock = NSLock()
        private var done: ((String?) -> Void)?
        var buffer = Data()
        init(_ done: @escaping (String?) -> Void) { self.done = done }

        func finish(_ ip: String?) {
            lock.lock()
            let call = done
            done = nil
            lock.unlock()
            call?(ip)
        }
    }

    private static let queue = DispatchQueue(label: "lumen.probe.own")

    static func fetch(_ echo: Echo, over kind: NWInterface.InterfaceType?, done: @escaping (String?) -> Void) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        if let kind { parameters.requiredInterfaceType = kind }
        let connection = NWConnection(host: NWEndpoint.Host(echo.host), port: NWEndpoint.Port(rawValue: echo.port) ?? 80, using: parameters)
        let fetch = Fetch(done)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET \(echo.path) HTTP/1.1\r\nHost: \(echo.host)\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                receive(connection, fetch)
            case .waiting, .failed:
                fetch.finish(nil)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) {
            fetch.finish(nil)
            connection.cancel()
        }
    }

    private static func receive(_ connection: NWConnection, _ fetch: Fetch) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data { fetch.buffer.append(data) }
            if isComplete || error != nil {
                fetch.finish(parse(fetch.buffer))
                connection.cancel()
            } else {
                receive(connection, fetch)
            }
        }
    }

    /// The address in the answer: the "ip" of a JSON body (between its first "{" and its last "}"),
    /// or a body that is only an address (icanhazip).
    static func parse(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else { return nil }
        let body = text[split.upperBound...]
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end,
           let json = try? JSONSerialization.jsonObject(with: Data(body[start...end].utf8)) as? [String: Any],
           let ip = json["ip"] as? String, !ip.isEmpty {
            return ip
        }
        // A plain body, chunked or not: the line that is an address.
        for line in body.split(whereSeparator: \.isNewline) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            if IPv4Address(candidate) != nil || IPv6Address(candidate) != nil { return candidate }
        }
        return nil
    }
}

/// The probe's screen: which session, start and stop, the verdict, the page, and the record to send.
struct NetProbeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var probe = NetProbe()
    @State private var sessionID: UUID?

    var body: some View {
        List {
            Section {
                ForEach(model.sessions) { session in
                    Button {
                        sessionID = session.id
                    } label: {
                        HStack {
                            Text("\(session.name) — \(model.proxy(session.proxyID)?.name ?? "без прокси")")
                            Spacer()
                            if sessionID == session.id { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("probe-\(session.name)")
                    .disabled(probe.running || model.lock(session).isLocked)
                }
            } header: {
                Text("Сессия")
            } footer: {
                Text("Начните на Wi-Fi, через 20 с выключите Wi-Fi в Пункте управления (не в Настройках: Lumen должен остаться на экране), через 30 с включите. Повторите три раза, остановите и отправьте журнал.")
            }
            Section("Итог") {
                Text(probe.verdict)
                    .accessibilityIdentifier("probeVerdict")
                Text("Сеть: \(probe.network)")
                Text("Адреса устройства: \(probe.ownAddresses.sorted().joined(separator: ", "))")
                    .accessibilityIdentifier("probeOwn")
                if !probe.workerCheck.isEmpty {
                    Text(probe.workerCheck).accessibilityIdentifier("probeWorker")
                }
                Button(probe.running ? "Остановить" : "Начать") {
                    if probe.running {
                        probe.stop()
                    } else if let id = sessionID, let session = model.sessions.first(where: { $0.id == id }) {
                        probe.start(runtime: SessionRuntimes.shared.runtime(for: session, model: model))
                    }
                }
                .disabled(sessionID == nil)
                .accessibilityIdentifier("probeStart")
                if TestHooks.enabled, probe.running, let id = sessionID, let runtime = SessionRuntimes.shared.existing(id) {
                    HStack {
                        Button("учение: сеть") { runtime.drill(.networkChange) }
                            .accessibilityIdentifier("probeDrillNetwork")
                        Spacer()
                        Button("учение: перезапуск") { runtime.drill(.restart) }
                            .accessibilityIdentifier("probeDrillRestart")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let view = probe.webView {
                Section("Страница сессии") {
                    WebViewContainer(webView: view)
                        .frame(height: 70)
                }
            }
            Section("Журнал") {
                ShareLink("Отправить журнал", item: probe.report)
                ForEach(Array(probe.timeline.suffix(20).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Замер сети")
        .onDisappear { probe.stop() }
    }
}
#endif

/// The way to the probe from the session list: in a DEBUG build only (a release build has nothing here).
struct DebugProbeLink: View {
    var body: some View {
        #if DEBUG
        NavigationLink { NetProbeView() } label: { Image(systemName: "waveform.path.ecg") }
            .accessibilityIdentifier("netProbeButton")
            .accessibilityLabel("Замер сети")
        #else
        EmptyView()
        #endif
    }
}
