import Foundation

/// "What sites see": what one page of this Mac measured in a browser — a profile's window or this
/// Mac's Safari — with the scripts CI's live comparison runs (`scripts/live_compare.py`): the
/// fingerprint probe, the window's geometry, the request headers in the order the server got
/// them, the APIs an app's WebKit may answer differently; and the TLS ClientHello the browser
/// offered. One text value per signal, keyed as "probe.ua", "geometry.chrome",
/// "headers.navigation.order", "apis.quota", "tls.ja4".
public struct SiteSnapshot: Codable, Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    /// The page's report — `{"probe": …, "geometry": …, "apis": …, "headers": …}` as JSON — and
    /// the ClientHello its https request began with, flattened.
    public init(report: Data, clientHello: TLSClientHello?) throws {
        let parsed = try JSONDecoder().decode(JSONValue.self, from: report)
        var values: [String: String] = [:]
        parsed.flatten(into: &values, prefix: "")
        if let clientHello {
            for (key, value) in clientHello.values { values["tls." + key] = value }
        }
        self.values = values
    }
}

/// A JSON value as a page reports it, decoded the same way on every platform.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// As JavaScript prints it: whole numbers without a fraction, true and false.
    var text: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object: return "{…}"
        }
    }

    /// Objects become dotted keys; everything else one value.
    func flatten(into values: inout [String: String], prefix: String) {
        if case .object(let members) = self {
            for (key, member) in members { member.flatten(into: &values, prefix: prefix.isEmpty ? key : prefix + "." + key) }
        } else if !prefix.isEmpty {
            values[prefix] = text
        }
    }
}

/// The groups "What sites see" lists signals in.
public enum SiteSignalCategory: String, CaseIterable, Sendable {
    case navigator, screen, window, headers, tls, apis, rendering
}

/// One signal of a profile's snapshot next to Safari's.
public struct SiteSignal: Equatable, Sendable, Identifiable {
    public enum Verdict: Equatable, Sendable {
        case same
        case differs
        /// Each browser's window has its own size and place: shown, not compared.
        case perWindow
        /// One of the two did not report it (an API it does not have, a step that failed).
        case onlyProfile, onlySafari
    }

    public var key: String
    public var category: SiteSignalCategory
    public var profile: String?
    public var safari: String?
    public var verdict: Verdict
    public var id: String { key }

    public init(key: String, category: SiteSignalCategory, profile: String?, safari: String?, verdict: Verdict) {
        self.key = key
        self.category = category
        self.profile = profile
        self.safari = safari
        self.verdict = verdict
    }
}

public enum SiteComparison {
    /// Every signal either snapshot has, by category and key; without Safari's, each is
    /// `.onlyProfile` (the profile's own snapshot, nothing to compare with).
    public static func compare(profile: SiteSnapshot, safari: SiteSnapshot?) -> [SiteSignal] {
        let keys = Set(profile.values.keys).union(safari.map { Array($0.values.keys) } ?? [])
        return keys.map { key in
            let mine = profile.values[key], theirs = safari?.values[key]
            let verdict: SiteSignal.Verdict
            if perWindow(key) {
                verdict = .perWindow
            } else if let mine, let theirs {
                verdict = mine == theirs ? .same : .differs
            } else {
                verdict = mine == nil ? .onlySafari : .onlyProfile
            }
            return SiteSignal(key: key, category: category(of: key), profile: mine, safari: theirs, verdict: verdict)
        }
        .sorted { ($0.category.order, $0.key) < ($1.category.order, $1.key) }
    }

    /// Where a key is listed. The probe's keys by what they describe.
    public static func category(of key: String) -> SiteSignalCategory {
        let parts = key.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return .apis }
        switch parts[0] {
        case "headers": return .headers
        case "tls": return .tls
        case "apis": return .apis
        case "geometry":
            return ["screen", "devicePixelRatio", "media"].contains(parts[1]) ? .screen : .window
        case "probe":
            switch parts[1] {
            case "screen", "colorDepth", "orientation", "pointer", "touch", "ownScreen": return .screen
            case "innerSize", "outerSize": return .window
            case "canvas", "canvasText", "webgl", "audio", "fonts": return .rendering
            case "features", "natives", "safari", "safariShape", "webkitObject", "windowOwnCount", "errorStack": return .apis
            default: return .navigator
            }
        default:
            return .apis
        }
    }

    /// The window's own size and place, and the tab's history: each browser's window has its own,
    /// so these are shown and not compared. What the browser's bars take of a window
    /// ("geometry.chrome") is compared.
    public static func perWindow(_ key: String) -> Bool {
        [
            "geometry.outer", "geometry.inner", "geometry.client", "geometry.visualViewport",
            "geometry.screenPosition", "geometry.historyLength", "probe.innerSize", "probe.outerSize",
        ].contains(key)
    }

    /// A sentence's key (the app's strings) for what a known difference means, or nil.
    public static func noteKey(for key: String) -> String? {
        switch key {
        case "probe.safari", "probe.safariShape", "probe.features.window.ApplePaySetup",
             "probe.features.window.MerchantValidationEvent", "probe.features.window.ApplePaySession":
            return "whatSites.note.safariOnly"
        case "probe.windowOwnCount": return "whatSites.note.windowCount"
        case "geometry.chrome": return "whatSites.note.chrome"
        case "probe.webdriver": return "whatSites.note.webdriver"
        default:
            if key.hasPrefix("probe.natives.") { return "whatSites.note.natives" }
            if key.hasPrefix("tls.") { return "whatSites.note.tls" }
            if key.hasPrefix("headers.") && key.hasSuffix(".order") { return "whatSites.note.headerOrder" }
            return nil
        }
    }
}

extension SiteSignalCategory {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// The page both browsers open: one page of this Mac (`http://127.0.0.1:<port>/headers.html`)
/// that runs the scripts and posts what they found to where it came from.
public enum SiteSnapshotPage {
    /// The two browsers a snapshot measures.
    public enum Side: String, Sendable, CaseIterable {
        case profile, safari
    }

    /// The token's prefix, which also tells the page apart from any other (`isMeasuringPage`).
    public static let tokenPrefix = "pbwss-"

    /// A new token for one snapshot's side: "pbwss-<random hex>-profile".
    public static func token(_ side: Side) -> String {
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return tokenPrefix + String(random.prefix(20)) + "-" + side.rawValue
    }

    public static func url(port: UInt16, token: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/headers.html?token=\(token)")!
    }

    /// The measuring page of a snapshot: no history kept of it.
    public static func isMeasuringPage(_ url: URL) -> Bool {
        guard url.host == "127.0.0.1", url.path == "/headers.html",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return query.contains { $0.name == "token" && ($0.value ?? "").hasPrefix(tokenPrefix) }
    }

    /// The page: each script in a function of its own (a failing one is reported, the rest go
    /// on), the https request whose ClientHello is read (it fails: the listener has no
    /// certificate a browser trusts, and needs none), then the report, posted to this page's own
    /// origin. `scripts`: "probe" (synchronous), "geometry" (synchronous), "apis" and "headers"
    /// (asynchronous, `await` in them).
    public static func html(scripts: [String: String], tlsPort: UInt16, token: String, title: String,
                            measuring: String, done: String) -> String {
        func body(_ name: String) -> String { scripts[name] ?? "return 'missing';" }
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        func literal(_ text: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escaped(title))</title>
        <style>body{font:15px -apple-system,sans-serif;margin:40px;color:#222}@media (prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}}</style>
        </head><body><h1>\(escaped(title))</h1><p id="state">\(escaped(measuring))</p>
        <script>
        (async () => {
          const report = {};
          const failed = (e) => ({ error: String(e && e.message || e) });
          try { report.probe = (function () {
        \(body("probe"))
          })(); } catch (e) { report.probe = failed(e); }
          try { report.geometry = (function () {
        \(body("geometry"))
          })(); } catch (e) { report.geometry = failed(e); }
          try { report.apis = await (async function () {
        \(body("apis"))
          })(); } catch (e) { report.apis = failed(e); }
          try { report.headers = await (async function () {
        \(body("headers"))
          })(); } catch (e) { report.headers = failed(e); }
          try { await fetch('https://localhost:\(tlsPort)/tls?token=\(token)', { mode: 'no-cors', cache: 'no-store' }); } catch (e) {}
          await fetch('/report?token=\(token)', { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'text/plain' },
                                                  body: JSON.stringify(report) });
          document.getElementById('state').textContent = \(literal(done));
        })();
        </script></body></html>
        """
    }
}
