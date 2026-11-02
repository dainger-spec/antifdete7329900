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

    /// One line on stdin; false when the app closed it first (it went away, or did not hold this
    /// process): the probe then sends nothing at all.
    private static func waitForGo() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let line = readLine(strippingNewline: true)
                continuation.resume(returning: line == "go")
            }
        }
    }

    /// The page's gathering, for six seconds: the candidate types it saw (host ones only, when the
    /// STUN request went nowhere — as it must, held or not).
    private static func gather() async -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        // A secure context of its own (RTCPeerConnection needs one); nothing is fetched from it.
        webView.loadHTMLString("<!doctype html><title>probe</title>", baseURL: URL(string: "https://localhost/"))
        for _ in 0..<50 where webView.isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
        let script = """
        const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:\(GuardProof.stunAddress):\(GuardProof.stunPort)' }] });
        const types = [];
        pc.onicecandidate = (event) => {
          if (event.candidate && event.candidate.candidate) types.push((/ typ (\\w+)/.exec(event.candidate.candidate) || [])[1]);
        };
        pc.createDataChannel('probe');
        await pc.setLocalDescription(await pc.createOffer());
        await new Promise((resolve) => setTimeout(resolve, 6000));
        pc.close();
        return [...new Set(types)].sort().join(',');
        """
        do {
            let value = try await webView.callAsyncJavaScript(script, contentWorld: .page)
            return value as? String ?? ""
        } catch {
            return "error"
        }
    }
}
