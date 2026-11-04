import AppKit
import Darwin
import NetworkGuardCore
import WebKit

/// `Lumen --guard-probe`: the process the network guard's check on this Mac holds
/// (`NetworkGuard.prove`, docs/TUNNEL.md "Attribution"). Told to go by a line on stdin — once the
/// app has asked the guard to hold it — one page of it asks a STUN server at a documentation
/// address (`GuardProof.stunAddress`, TEST-NET-3, never routed on the Internet) for its address,
/// with WebKit's own WebRTC, as a profile's page would without the relay. WebKit's network process
/// opens that flow on this process's behalf: a guard that holds this process must see it as this
/// process's and drop it. If it does not, the guard would hold nothing of a profile but the
/// profile's own sockets, and WebRTC stays off.
///
/// Nothing of the person's is in it: no profile, no vault, an ephemeral data store, no window.
/// CI runs it inside a packet capture (scripts/guard_probe_check.py): there no guard holds it, and
/// the capture shows whom the system counts the packet for.
///
/// It says as it goes what it did, by the time since it was told to go — the page loaded, each
/// state of the ICE gathering, each candidate's type, each error the STUN server's address gave
/// (`icecandidateerror`) — which `Lumen --guard-diagnose` prints as the probe's own account. Its life:
/// the page's load (at most five seconds), then the gathering's six (`gather`), then it ends.
@MainActor
enum GuardProbe {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        print("GUARD-PROBE pid \(getpid())")
        Task { @MainActor in
            guard await waitForGo() else {
                print("GUARD-PROBE stopped: no go")
                exit(2)
            }
            let types = await gather()
            print("GUARD-PROBE done candidates \(types.isEmpty ? "none" : types)")
            exit(0)
        }
        application.run()
        exit(0)
    }

    private static var wentAt = Date()

    /// A line of the probe's own account, with the milliseconds since it was told to go.
    private static func say(_ text: String) {
        print("GUARD-PROBE +\(Int(Date().timeIntervalSince(wentAt) * 1000)) ms \(text)")
    }

    /// One line on stdin; false when the app closed it first (it went away, or did not hold this
    /// process): the probe then sends nothing at all.
    private static func waitForGo() async -> Bool {
        let went = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let line = readLine(strippingNewline: true)
                continuation.resume(returning: line == "go")
            }
        }
        wentAt = Date()
        return went
    }

    /// The page's gathering, for six seconds: the candidate types it saw (host ones only, when the
    /// STUN request went nowhere — as it must, held or not).
    private static func gather() async -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        // A secure context of its own (RTCPeerConnection needs one); nothing is fetched from it.
        webView.loadHTMLString("<!doctype html><title>probe</title>", baseURL: URL(string: "https://localhost/"))
        say("the page is loading")
        for _ in 0..<50 where webView.isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
        say(webView.isLoading ? "the page has not loaded in five seconds: asked anyway" : "the page loaded")
        // Measurement (claude/measure-guard-link, never merged): which network process WebKit names
        // to this process, as it goes — said again whenever the answer changes.
        let watcher = Task { @MainActor in
            var last = ""
            while !Task.isCancelled {
                let named = networkProcessIdentifiers(webView)
                if named != last {
                    last = named
                    say("networking \(named)")
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { watcher.cancel() }
        // What the page saw, by the time since it started: each gathering state, each candidate's
        // type and protocol (never its address), each error a STUN server's address gave.
        let script = """
        const started = Date.now();
        const events = [];
        const note = (text) => events.push('+' + (Date.now() - started) + ' ms ' + text);
        const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:\(GuardProof.stunAddress):\(GuardProof.stunPort)' }] });
        const types = [];
        pc.onicegatheringstatechange = () => note('gathering ' + pc.iceGatheringState);
        pc.onicecandidate = (event) => {
          if (event.candidate && event.candidate.candidate) {
            const type = (/ typ (\\w+)/.exec(event.candidate.candidate) || [])[1];
            types.push(type);
            note('candidate ' + type + ' ' + (event.candidate.protocol || '?'));
          } else {
            note('candidates: the end');
          }
        };
        pc.onicecandidateerror = (event) => note('error from ' + (event.url || '?') + ': ' + event.errorCode + ' ' + (event.errorText || ''));
        pc.createDataChannel('probe');
        await pc.setLocalDescription(await pc.createOffer());
        note('offer set: gathering asked');
        await new Promise((resolve) => setTimeout(resolve, 6000));
        note('six seconds: closed');
        pc.close();
        return JSON.stringify({ types: [...new Set(types)].sort().join(','), events });
        """
        do {
            let value = try await webView.callAsyncJavaScript(script, contentWorld: .page)
            guard let text = value as? String, let data = text.data(using: .utf8),
                  let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                say("the page answered nothing readable")
                return ""
            }
            for event in answer["events"] as? [String] ?? [] { say("page \(event)") }
            return answer["types"] as? String ?? ""
        } catch {
            say("the page's script failed: \(error.localizedDescription)")
            return "error"
        }
    }

    /// Measurement (claude/measure-guard-link, never merged): every method of WKWebsiteDataStore,
    /// WKProcessPool and WKWebView (and of the first two's classes) whose name speaks of the network
    /// process or of a process identifier; those that take nothing and answer an int are asked.
    private static func networkProcessIdentifiers(_ webView: WKWebView) -> String {
        let configuration = webView.configuration
        let receivers: [(String, AnyObject)] = [
            ("WKWebsiteDataStore", configuration.websiteDataStore),
            ("WKProcessPool", configuration.processPool),
            ("WKWebView", webView),
            ("+WKWebsiteDataStore", WKWebsiteDataStore.self as AnyObject),
            ("+WKProcessPool", WKProcessPool.self as AnyObject),
        ]
        var parts: [String] = []
        for (label, receiver) in receivers {
            var count: UInt32 = 0
            guard let methods = class_copyMethodList(object_getClass(receiver), &count) else { continue }
            defer { free(methods) }
            for index in 0..<Int(count) {
                let method = methods[index]
                let selector = method_getName(method)
                let name = NSStringFromSelector(selector)
                let lowered = name.lowercased()
                guard lowered.contains("networkprocess") || lowered.contains("processidentifier") else { continue }
                let encoding = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
                if method_getNumberOfArguments(method) == 2, encoding.hasPrefix("i") {
                    typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
                    let get = unsafeBitCast(method_getImplementation(method), to: Getter.self)
                    parts.append("\(label).\(name) = \(get(receiver, selector))")
                } else {
                    parts.append("\(label).\(name) [\(encoding)]")
                }
            }
        }
        return parts.isEmpty ? "no such method" : parts.sorted().joined(separator: "; ")
    }
}
