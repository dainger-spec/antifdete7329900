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
        var safariObject = false
        var storageQuota: Double?
        var fingerprint: Fingerprint
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

    static func config(for session: Session, proxy: ProxyEntry?) -> ShimConfig {
        let locale = locale(of: session, proxy: proxy)
        let settings = session.settings
        return ShimConfig(
            timeZone: Faults.isActive(.timeZoneIgnored) ? nil : locale.timeZone,
            // With a proxy, WebRTC would go around it (measured: STUN from the real address on every
            // iOS measured); removed by the shim, page and frames alike (measured: no STUN at all).
            webRTC: proxy == nil ? "unrestricted" : "disabled",
            fingerprint: .init(seed: settings.noiseSeed, canvas: settings.canvas.rawValue, webgl: settings.webGL.rawValue,
                               audio: settings.audio.rawValue, language: locale.language,
                               unstable: Faults.isActive(.noiseUnstable), naive: Faults.isActive(.unmaskedReplacement),
                               lowBit: Faults.isActive(.canvasNoiseLowBit)))
    }

    static func script(for session: Session, proxy: ProxyEntry?) -> WKUserScript {
        let json = (try? String(data: JSONEncoder().encode(config(for: session, proxy: proxy)), encoding: .utf8)) ?? "{}"
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
