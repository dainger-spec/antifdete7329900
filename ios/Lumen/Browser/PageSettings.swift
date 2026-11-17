import Foundation
import LumenCore
import UIKit
import WebKit

/// What a session's pages are given: its User-Agent, and the page shim (the macOS app's
/// PrivacyScripts body with the fingerprint part, ios/Lumen/Resources/page-shim.js) configured for it.
@MainActor
enum PageSettings {
    private static let shimBody: String = {
        guard let url = Bundle.main.url(forResource: "page-shim", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    struct ShimConfig: Encodable, Equatable {
        struct Geolocation: Encodable, Equatable { var mode = "deny" }
        struct Fingerprint: Encodable, Equatable {
            var seed: String
            var canvas: String
            var webgl: String
            var audio: String
            var language: String?
            var unstable: Bool
            var naive: Bool
            var lowBit: Bool
        }
        var timeZone: String?
        var geolocation = Geolocation()
        var webRTC: String
        /// With "tunnel": the session's WebRTC relay (WebRTCTunnel), the pages' only ICE server.
        var webRTCRelay: WebRTCTunnel.Relay?
        var safariObject = false
        var storageQuota: Double?
        var fingerprint: Fingerprint
        /// The type of the event by which a page's same-origin windows (its frames, a window it
        /// opens) find the shim's one registry of replacements — the Mac's
        /// `PrivacyScripts.ShimConfiguration.channel`. Made at random for each session's runtime when
        /// it starts (`makeChannel`, kept by `SessionRuntime`), so no page can name it: a page that
        /// could would be handed the list of what the shim replaced. Never given to a worker (the
        /// shim's `WORKER_KEYS`). Empty: each window is a family of its own, and a frame's
        /// `Function.prototype.toString` prints its parent's replacements as no engine would.
        var channel = ""
    }

    /// A runtime's own event type for the shim's family of windows: 122 random bits, as text.
    nonisolated static func makeChannel() -> String {
        UUID().uuidString.lowercased()
    }

    /// The time zone and language a session's pages get: its proxy's exit country (its last check),
    /// set by hand, or the device's own (nil: nothing changed).
    static func locale(of session: Session, proxy: ProxyEntry?) -> (timeZone: String?, language: String?) {
        switch session.settings.locale {
        case .device:
            return (nil, nil)
        case let .manual(timeZone, language):
            return (timeZone, language)
        case .proxyCountry:
            guard let check = proxy?.check, check.alive else { return (nil, nil) }
            return (check.timeZone, check.country.map { CountryLocale.language(forCountry: $0) })
        }
    }

    /// What the shim is given; `channel` is the runtime's (`makeChannel`), empty for the comparison
    /// of what the pages were last given (`SessionRuntime.applyPageSettings`).
    static func config(for session: Session, proxy: ProxyEntry?, relay: WebRTCTunnel.Relay?, channel: String = "") -> ShimConfig {
        let locale = locale(of: session, proxy: proxy)
        let settings = session.settings
        return ShimConfig(
            timeZone: Faults.isActive(.timeZoneIgnored) ? nil : locale.timeZone,
            webRTC: webRTCPolicy(proxy: proxy, relay: relay),
            webRTCRelay: proxy == nil ? nil : relay,
            fingerprint: .init(seed: settings.noiseSeed, canvas: settings.canvas.rawValue, webgl: settings.webGL.rawValue,
                               audio: settings.audio.rawValue, language: locale.language,
                               unstable: Faults.isActive(.noiseUnstable), naive: Faults.isActive(.unmaskedReplacement),
                               lowBit: Faults.isActive(.canvasNoiseLowBit)),
            channel: channel)
    }

    /// WebRTC in a session's pages. Without a proxy, as Safari has it. With one, left to itself it
    /// would go around the proxy (measured: STUN from the real address on every iOS measured), so it
    /// goes through the session's relay (WebRTCTunnel: relay-only, the relay the only ICE server —
    /// candidates at the proxy's address alone), or, when the proxy cannot carry it (HTTP, a SOCKS5
    /// proxy without UDP, not checked yet), it is removed by the shim, page and frames alike
    /// (measured: no STUN at all).
    static func webRTCPolicy(proxy: ProxyEntry?, relay: WebRTCTunnel.Relay?) -> String {
        guard proxy != nil else { return "unrestricted" }
        guard relay != nil else { return "disabled" }
        // The planted fault: the relay is started but the pages are left to the engine's own servers.
        return Faults.isActive(.webRTCAroundTunnel) ? "unrestricted" : "tunnel"
    }

    static func script(for session: Session, proxy: ProxyEntry?, relay: WebRTCTunnel.Relay?, channel: String) -> WKUserScript {
        let json = (try? String(data: JSONEncoder().encode(config(for: session, proxy: proxy, relay: relay, channel: channel)), encoding: .utf8)) ?? "{}"
        // The planted fault: the blob-worker hook on its old condition, the time zone alone — the shim as
        // it was before the mac app's fix of 8 November (a noised page, a worker with the real canvas).
        let body = Faults.isActive(.workerHookTimeZoneOnly)
            ? shimBody.replacingOccurrences(of: "if (substitutesInWorkers(CONFIG)) {", with: "if (CONFIG.timeZone) {")
            : shimBody
        // Wrapped as PrivacyScripts.source wraps it: the function must be named `install`.
        let source = "(function install(CONFIG) {\n" + body + "\n})(" + json + ");"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    /// nil: WebKit's own string with Safari's application name (what Safari on this iPhone sends).
    static func userAgent(for session: Session) -> String? {
        guard !Faults.isActive(.userAgentIgnored) else { return nil }
        switch session.settings.userAgent {
        case .thisDevice: return nil
        case let .preset(id): return UserAgentPreset.preset(id: id)?.userAgent
        case let .custom(text): return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
        }
    }
}
