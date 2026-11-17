import AppKit
import BrowserCore
import Darwin
import Foundation
import Network

/// `Lumen --xray-check <spec.json>`: profiles on VLESS, VMess, Trojan and Shadowsocks links, started
/// the way the app starts one — a process of their own, their link's relay started by this process
/// (`XrayRelays`), the profile held to it — against real Xray servers, inside a capture of every
/// packet of this Mac (scripts/xray_leak_check.py, which makes the servers, the spec and the capture,
/// and reads it). docs/TUNNEL.md, "Links".
///
/// The servers' only way out is the self-test proxy (scripts/selftest_proxy.py `--socks-udp`), which
/// answers every page itself and connects nowhere: what reaches it came through the link. For each
/// link, with the self-test standing in for the network guard (CI cannot load it):
///
/// - the leak page (`/pb-leak`): every kind of request a page can make, to host names carrying the
///   run's id, to documentation addresses and to this Mac's loopback — they must reach the self-test
///   proxy through the server (its log names them), its canary on loopback must take none of them,
///   and the capture must hold none of them;
/// - the WebRTC call page (`/pb-rtc`, `call`): two peer connections through the app's relay, the
///   link's UDP and the server — relay candidates only, at the self-test proxy's address;
/// - the relay's door: SOCKS5 without the launch's login, and with a wrong password, refused; with it, taken;
/// - for the link named `failClosed`: a page fetching every 300 ms and its relay killed three times,
///   as the app runs it (`restartLimit` 2): after the first two kills the relay is started again on its
///   port with its login and the fetches go through again; after the third, within the minute, it is
///   not — no fetch succeeds after it, the profile is stopped and says why. The capture shows that
///   nothing went another way at any time.
///
/// Prints `XRAY-CHECK PASS/FAIL/INFO …`, and the capture's marks (`INFO egress-window begin/end`,
/// `egress-pid`, `xray-relay-pid`, `egress-token`, `egress-control`). Exit 1 on any FAIL.
@MainActor
enum XrayCheck {
    static let tag = "XRAY-CHECK"

    struct Spec: Decodable {
        struct Link: Decodable {
            var name: String
            var link: String
        }
        var links: [Link]
        /// The self-test proxy's HTTP listener, which its logs are read from.
        var httpProxyPort: Int
        /// Where a proxy's TCP exit is asked: the self-test proxy's own trace.
        var exitTrace: String?
        /// The link whose relay is killed while its profile runs.
        var failClosed: String?
        /// Where the server lets a page out to the Internet (its routing): a page offering HTTP/3, to
        /// see it fetched as HTTP/2 through the link. Unset: not asked.
        var quicSite: String?
    }

    private static var failures = 0

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A process of its own per profile, with Safari's window: as the app starts one.
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1500) {
            print("\(tag) FAIL the check did not finish in 25 minutes")
            exit(1)
        }
        guard let index = arguments.firstIndex(of: "--xray-check"), arguments.count > index + 1,
              let data = FileManager.default.contents(atPath: arguments[index + 1]),
              let spec = try? JSONDecoder().decode(Spec.self, from: data) else {
            print("usage: Lumen --xray-check <spec.json>")
            exit(64)
        }
        Task { @MainActor in exit(await run(spec)) }
        application.run()
    }

    private static func pass(_ text: String) { print("\(tag) PASS \(text)") }
    private static func fail(_ text: String) {
        failures += 1
        print("\(tag) FAIL \(text)")
    }
    private static func info(_ text: String) { print("\(tag) INFO \(text)") }
    private static func check(_ text: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { pass(text) } else { fail(detail().isEmpty ? text : "\(text): \(detail())") }
    }

    private static func run(_ spec: Spec) async -> Int32 {
        info("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version)")
        guard XrayRelays.isAvailable else {
            fail("this build has no relay for links (XRAY=1 scripts/build-app.sh), or is sandboxed")
            return 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-xray-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: UUID().uuidString, iterations: 10_000))
        } catch {
            fail("no vault for the check: \(error)")
            return 1
        }
        if let trace = spec.exitTrace.flatMap(URL.init(string:)) { ProxyExitLookup.endpoints = [trace] }
        // CI cannot load the network guard: the self-test's stand-in takes its place, as in the self-test.
        NetworkGuard.shared.selfTestStandIn = true
        // The relay's restarts as the app has them; a profile whose relay stays dead runs on for a few
        // seconds before it stops, to see its pages fail meanwhile.
        ProfileManager.relayDeathGrace = 8

        // The capture's own control: this process asks this Mac's resolver for a name with the
        // check's token, outside every window — the capture must hold that question.
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        info("egress-token \(token)")
        info("egress-process \(ProcessInfo.processInfo.processName) \(getpid())")
        // Under a real domain: this Mac's resolver answers a .invalid name asked this way itself, and
        // the question never reached the capture (run 44012119541).
        let control = "dns-control-\(token).leak.example.com"
        info("egress-control \(control)")
        var result: UnsafeMutablePointer<addrinfo>?
        _ = getaddrinfo(control, "80", nil, &result)
        if let result { freeaddrinfo(result) }

        for (index, link) in spec.links.enumerated() {
            await checkLink(link, number: index, token: token, spec: spec, repository: repository)
        }
        print("\(tag) \(failures == 0 ? "PASSED" : "FAILED (\(failures))")")
        return failures == 0 ? 0 : 1
    }

    // MARK: One link

    private static func checkLink(_ link: Spec.Link, number: Int, token: String, spec: Spec, repository: ProfileRepository) async {
        let name = link.name
        let proxy: ProxySettings
        do {
            proxy = try ProxySettings(shareLink: link.link)
        } catch {
            fail("\(name): Lumen does not take the link: \(error)")
            return
        }
        let run = "\(token)x\(number)"
        // The leak page: every request it makes carries the run's id, or a documentation address.
        let profile: ProfileSummary
        do {
            profile = try repository.create(name: "Link \(name)", configuration: ProfileConfiguration(
                startURL: URL(string: "http://\(run).leak.example.com/pb-leak?run=\(run)"),
                proxy: proxy, webRTCPolicy: .unrestricted, matchProxyLocation: false))
        } catch {
            fail("\(name): no profile: \(error)")
            return
        }
        // (The check's vault, a temporary folder, goes whole at its end: no profile is deleted one by one.)
        let manager = ProfileManager(repository: repository)
        var messages: [String] = []
        manager.onError = { messages.append($0) }
        var hostsChrome: Bool?
        manager.onProfileRunning = { _, hosts in hostsChrome = hosts }
        var exited: Int32?
        manager.onChildExited = { _, status in exited = status }

        info("egress-window begin \(Date().timeIntervalSince1970) \(name)")
        do {
            try await manager.launch(profile.id)
        } catch {
            fail("\(name): the profile did not start: \(error.localizedDescription)")
            if let output = XrayRelays.shared.lastStartFailure { info("\(name): the relay said: \(output)") }
            info("egress-window end \(Date().timeIntervalSince1970) \(name)")
            return
        }
        guard let pid = manager.processIdentifier(of: profile.id) else {
            fail("\(name): the profile did not get a process of its own")
            await manager.shutDown()
            info("egress-window end \(Date().timeIntervalSince1970) \(name)")
            return
        }
        info("egress-pid \(pid)")
        let relayPID = XrayRelays.shared.processIdentifier(owner: profile.id)
        if let relayPID { info("xray-relay-pid \(relayPID) \(name)") }
        check("\(name): the profile runs in a process of its own, its link's relay running", relayPID != nil,
              "no relay process for it")
        _ = await waitUntil(90) { hostsChrome != nil || exited != nil }
        check("\(name): the profile's window came up", hostsChrome != nil, exited.map { "its process exited with \($0)" } ?? "no word in 90 s")

        // 1. The leak page, through the link: its report reached the self-test proxy, by the server.
        var leakLog: [String: Any] = [:]
        _ = await waitUntil(60) {
            leakLog = await log(run: run, port: spec.httpProxyPort)
            return !((leakLog["reports"] as? [[String: Any]]) ?? []).isEmpty
        }
        let targets = (leakLog["targets"] as? [[String: Any]]) ?? []
        let vias = Set(targets.compactMap { $0["via"] as? String })
        check("\(name): the leak page loaded through the link — its requests reached the server's side by name",
              !targets.isEmpty && vias == ["via=socks5-udp"],
              "targets \(targets.count), vias \(vias.sorted())")
        check("\(name): the page reported what it could see, through the link",
              !((leakLog["reports"] as? [[String: Any]]) ?? []).isEmpty)
        // The page's requests to this Mac's own loopback (127.0.0.1, localhost, ::1, 0.0.0.0) went through
        // the link too: the self-test proxy's canary, listening there, took none of them. (The capture
        // leaves loopback out; this is what sees it.)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let latest = await log(run: run, port: spec.httpProxyPort)
        let canary = latest["canary"] as? [[String: Any]]
        check("\(name): no request of the page reached this Mac's own loopback around the link (the canary took none)",
              canary?.isEmpty == true, canary.map { "\($0.count) connection(s): \($0.prefix(3))" } ?? "the self-test proxy's log did not come")

        // 2. The relay's door: its login only.
        if let route = ProxyRoutes.shared.route(for: proxy) {
            let open = await Task.detached { Self.socksWithoutLogin(port: route.port) }.value
            let wrong = await Task.detached { XrayRelays.socksLogin(port: route.port, username: route.username, password: "wrong") }.value
            let right = await Task.detached { XrayRelays.socksLogin(port: route.port, username: route.username, password: route.password) }.value
            check("\(name): the relay refuses SOCKS5 without its login and with a wrong password, and takes its own",
                  open == false && wrong == false && right == true, "no login taken \(open), wrong taken \(wrong), its own taken \(right)")
        } else {
            fail("\(name): no route to the link's relay while its profile runs")
        }

        // 3. WebRTC: a call between two connections of a page, through the app's relay and the link's UDP.
        let rtcRun = run + "r"
        let opened = await webDriver(manager, profile.id, "open", [:])
        _ = await webDriver(manager, profile.id, "navigate", ["url": "http://127.0.0.1:\(spec.httpProxyPort)/pb-rtc?run=\(rtcRun)&mode=call"])
        var rtc: [String: Any] = [:]
        _ = await waitUntil(120) {
            let log = await log(run: rtcRun, port: spec.httpProxyPort)
            rtc = ((log["reports"] as? [[String: Any]]) ?? []).first { $0["rtcPage"] != nil } ?? [:]
            return !rtc.isEmpty
        }
        let types = rtc["candidateTypes"] as? [String] ?? []
        let addresses = rtc["candidateAddresses"] as? [String] ?? []
        info("\(name): WebRTC \(rtc), refusals \(manager.webRTCRefusals.values.map(\.rawValue)), WebDriver \(opened.error.map { "\($0)" } ?? "open")")
        check("\(name): WebRTC through the link: relay candidates only, at the server side's address (its STUN went by the link's UDP)",
              !types.isEmpty && Set(types) == ["relay"] && Set(addresses) == ["203.0.113.77"],
              "types \(types), addresses \(addresses), refusals \(manager.webRTCRefusals.values.map(\.rawValue))")
        info("\(name): WebRTC call connected \(rtc["connected"] ?? "nil"), frames \((rtc["inbound"] as? [String: Any])?["framesDecoded"] ?? "nil")")

        // 4. HTTP/3 offered by a site on the Internet: fetched through the link as HTTP/2 or 1.1.
        if number == 0, let site = spec.quicSite {
            _ = await webDriver(manager, profile.id, "navigate", ["url": site])
            let text = await webDriver(manager, profile.id, "executeSync", ["script": "return document.body ? document.body.innerText : ''", "args": []])
            let body = text.value ?? ""
            if body.contains("http=") {
                check("\(name): a site that offers HTTP/3 is fetched through the link without QUIC", !body.contains("http=http/3"),
                      String(body.prefix(200)))
            } else {
                info("\(name): SKIPPED the HTTP/3 site did not answer through the link (\(String(body.prefix(120))))")
            }
        }

        // 5. Fail closed: the relay killed — started again twice, then not. From a page of the leak
        // domain over http (the HTTP/3 site above is https, and would block the loop's http fetches as
        // mixed content: run 44012119541).
        if spec.failClosed == name, let relayPID {
            await failClosed(name: name, manager: manager, profile: profile.id, pid: pid, relayPID: relayPID, run: run,
                             messages: { messages })
        }

        await manager.shutDown()
        info("egress-window end \(Date().timeIntervalSince1970) \(name)")
        if let relayPID {
            let gone = await waitUntil(10) { kill(relayPID, 0) != 0 }
            check("\(name): the relay ended with its profile", gone)
        }
    }

    private static func failClosed(name: String, manager: ProfileManager, profile id: UUID, pid: pid_t, relayPID: pid_t, run: String,
                                   messages: () -> [String]) async {
        let loop = """
            window.__fc = {ok: 0, failed: 0};
            window.__fcTimer = setInterval(() => {
              // Another origin than the page's: an opaque answer (no-cors) counts as one that came.
              fetch('http://fc-\(run).leak.example.com/pb-served.json?t=' + Date.now(), {cache: 'no-store', mode: 'no-cors'})
                .then(r => r.text()).then(() => { window.__fc.ok++; }, () => { window.__fc.failed++; });
            }, 300);
            return true;
            """
        let read = "return JSON.stringify(window.__fc || null);"
        func now() async -> (ok: Int, failed: Int) {
            counters(await webDriver(manager, id, "executeSync", ["script": read, "args": []]))
        }
        _ = await webDriver(manager, id, "navigate", ["url": "http://\(run).leak.example.com/pb-served.json?fc=1"])
        _ = await webDriver(manager, id, "executeSync", ["script": loop, "args": []])
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let before = await now()
        check("\(name), fail closed: the page fetches through the link before the relay is killed", before.ok > 0, "\(before)")
        let route = XrayRelays.shared.route(owner: id)

        // Twice: the relay killed, started again on its port with its login, and the fetches through again.
        var current = relayPID
        for round in 1...2 {
            info("egress-relay-killed \(Date().timeIntervalSince1970) \(name)")
            kill(current, SIGKILL)
            let atKill = await now()
            var again: pid_t?
            _ = await waitUntil(20) {
                again = XrayRelays.shared.processIdentifier(owner: id).flatMap { $0 != current ? $0 : nil }
                return again != nil
            }
            guard let again else {
                fail("\(name), fail closed: the relay killed (\(round)) was not started again")
                return
            }
            info("xray-relay-pid \(again) \(name)")
            let sameDoor = XrayRelays.shared.route(owner: id) == route
            check("\(name), fail closed: the relay killed (\(round)) is started again, on its port with its login", sameDoor)
            let resumed = await waitUntil(20) { await now().ok > atKill.ok + 1 }
            let after = await now()
            check("\(name), fail closed: after the relay's restart (\(round)) the page fetches through the link again", resumed,
                  "at the kill \(atKill), now \(after)")
            info("\(name), fail closed: restart \(round): fetches at the kill \(atKill), after \(after)")
            current = again
        }

        // The third time in the minute: not started again — the fetches fail, the profile stops and says why.
        info("egress-relay-killed \(Date().timeIntervalSince1970) \(name)")
        kill(current, SIGKILL)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let atKill = await now()
        try? await Task.sleep(nanoseconds: 4_500_000_000)
        let after = await now()
        check("\(name), fail closed: the relay killed a third time in a minute is not started again",
              XrayRelays.shared.processIdentifier(owner: id) == nil)
        check("\(name), fail closed: with its relay dead, the profile's fetches fail — none gets through another way",
              after.ok <= atKill.ok + 1 && after.failed > atKill.failed, "at the kill \(atKill), 5 s later \(after)")
        let stopped = await waitUntil(60) { !manager.isRunning(id) && manager.processIdentifier(of: id) == nil }
        check("\(name), fail closed: the profile is stopped", stopped)
        let said = messages().contains { $0.contains(L("launch.relayEnded").components(separatedBy: "%@").last ?? "\u{0}") }
        check("\(name), fail closed: the profile says why, in words", said, messages().joined(separator: " | "))
        check("\(name), fail closed: the profile's process ended", await waitUntil(30) { kill(pid, 0) != 0 })
    }

    private static func counters(_ answer: WebDriverAnswer) -> (ok: Int, failed: Int) {
        guard let value = answer.value, let outer = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(outer.utf8)) as? [String: Any] else { return (-1, -1) }
        return ((object["ok"] as? NSNumber)?.intValue ?? -1, (object["failed"] as? NSNumber)?.intValue ?? -1)
    }

    // MARK: Helpers

    private static func webDriver(_ manager: ProfileManager, _ id: UUID, _ command: String, _ body: [String: Any]) async -> WebDriverAnswer {
        let text = (try? JSONSerialization.data(withJSONObject: body)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return await manager.webDriver(id, WebDriverCall(id: UUID(), command: command, element: nil, name: nil, body: text))
    }

    /// The self-test proxy's log of a run, asked of its HTTP listener (on this Mac, never through a link).
    private static func log(run: String, port: Int) async -> [String: Any] {
        guard let url = URL(string: "http://proxied.selftest.invalid/pb-leak/log.json?run=\(run)"),
              let proxies = try? ProxyConfigurationFactory.make(ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port)) else {
            return [:]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = proxies
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: url) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    @discardableResult
    private static func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return await condition()
    }

    /// A SOCKS5 greeting offering no login: true when the relay takes it.
    nonisolated static func socksWithoutLogin(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        let greeting: [UInt8] = [5, 1, 0]
        guard greeting.withUnsafeBytes({ send(fd, $0.baseAddress, 3, 0) }) == 3 else { return false }
        var answer = [UInt8](repeating: 0, count: 2)
        let got = answer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 2, 0) }
        return got == 2 && answer == [5, 0]
    }
}
