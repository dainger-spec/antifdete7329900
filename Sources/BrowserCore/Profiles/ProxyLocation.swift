#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where a profile's proxy exits to the web, as a geolocation service saw it when asked through
/// that proxy: the exit IP, its time zone and country. A site compares the same IP against the
/// time zone and language the browser reports (e.g. "Local Time Zone" vs "System Time Zone").
public struct ProxyLocation: Codable, Equatable, Sendable {
    /// IANA identifier, e.g. "Europe/Berlin".
    public var timeZoneIdentifier: String
    /// ISO 3166-1 alpha-2, upper case, e.g. "DE".
    public var countryCode: String?
    /// The proxy this was resolved for (`endpoint(of:)`): a stored location applies to it only.
    public var proxyEndpoint: String
    public var resolvedAt: Date
    /// The address the service saw the request come from: the proxy's exit IP. Nil for a
    /// location stored by an older build, or a service that did not say.
    public var exitIP: String?

    public init(timeZoneIdentifier: String, countryCode: String?, proxyEndpoint: String, resolvedAt: Date = Date(),
                exitIP: String? = nil) {
        self.timeZoneIdentifier = timeZoneIdentifier
        self.countryCode = countryCode
        self.proxyEndpoint = proxyEndpoint
        self.resolvedAt = resolvedAt
        self.exitIP = exitIP
    }

    /// The proxy a location belongs to: kind, host and port, and its credentials when it has
    /// some, as a short digest. Gateway proxies pick the exit country or session from the
    /// username (some from the password), so other credentials are another proxy: nothing
    /// remembered applies, and an exit-IP change is not one. Without credentials the key is the
    /// one older builds stored.
    public static func endpoint(of proxy: ProxySettings) -> String {
        let address = "\(proxy.kind.rawValue)://\(proxy.host):\(proxy.port)"
        guard proxy.username?.isEmpty == false || proxy.password?.isEmpty == false else { return address }
        let credentials = Data(((proxy.username ?? "") + "\u{0}" + (proxy.password ?? "")).utf8)
        let digest = SHA256.hash(data: credentials).prefix(8).map { String(format: "%02x", $0) }.joined()
        return address + "#" + digest
    }

    /// Same place, from the same exit IP, for the same proxy (the lookup time aside).
    public func isSameLocation(as other: ProxyLocation?) -> Bool {
        guard let other else { return false }
        return timeZoneIdentifier == other.timeZoneIdentifier && countryCode == other.countryCode
            && proxyEndpoint == other.proxyEndpoint && exitIP == other.exitIP
    }

    /// The exit IP changed since `previous`, for the same proxy: the old and new address. Nil
    /// when either is unknown, or `previous` was looked up for another proxy (the user changed it).
    public func exitIPChange(since previous: ProxyLocation?) -> (old: String, new: String)? {
        guard let previous, previous.proxyEndpoint == proxyEndpoint,
              let old = previous.exitIP, let new = exitIP, old != new else { return nil }
        return (old, new)
    }

    /// Reads a geolocation service's JSON answer: the time zone at `timeZoneKeyPath`, the country
    /// at `countryKeyPath` (e.g. `["timezone", "id"]` for `{"timezone": {"id": "Europe/Berlin"}}`),
    /// the exit IP at `ipKeyPath`. nil unless the time zone is a known IANA identifier; the IP is
    /// kept only when it is an IPv4 or IPv6 literal.
    public static func parse(_ data: Data, timeZoneKeyPath: [String], countryKeyPath: [String], ipKeyPath: [String] = ["ip"],
                             proxyEndpoint: String, resolvedAt: Date = Date()) -> ProxyLocation? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func value(at path: [String]) -> String? {
            var current: Any? = object
            for key in path { current = (current as? [String: Any])?[key] }
            return (current as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let zone = value(at: timeZoneKeyPath), zone.contains("/"), TimeZone(identifier: zone) != nil else { return nil }
        let country = value(at: countryKeyPath).map { $0.uppercased() }
            .flatMap { code in code.count == 2 && code.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) } ? code : nil }
        let ip = value(at: ipKeyPath).flatMap { isIPLiteral($0) ? $0 : nil }
        return ProxyLocation(timeZoneIdentifier: zone, countryCode: country, proxyEndpoint: proxyEndpoint,
                             resolvedAt: resolvedAt, exitIP: ip)
    }

    static func isIPLiteral(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    /// The language websites would expect from a Safari user in this country (a BCP 47 tag such
    /// as "de-DE"): the country's most common browser language, English when unknown.
    public var webLanguage: String {
        countryCode.flatMap { Self.webLanguages[$0] } ?? "en-US"
    }

    static let webLanguages: [String: String] = [
        // Europe
        "DE": "de-DE", "AT": "de-AT", "CH": "de-CH", "LI": "de-LI", "LU": "fr-LU",
        "FR": "fr-FR", "MC": "fr-MC", "BE": "nl-BE", "NL": "nl-NL",
        "GB": "en-GB", "IE": "en-IE", "MT": "en-MT",
        "ES": "es-ES", "PT": "pt-PT", "IT": "it-IT", "SM": "it-SM", "GR": "el-GR", "CY": "el-CY",
        "DK": "da-DK", "NO": "nb-NO", "SE": "sv-SE", "FI": "fi-FI", "IS": "is-IS",
        "EE": "et-EE", "LV": "lv-LV", "LT": "lt-LT",
        "PL": "pl-PL", "CZ": "cs-CZ", "SK": "sk-SK", "HU": "hu-HU", "RO": "ro-RO", "MD": "ro-MD",
        "BG": "bg-BG", "RS": "sr-RS", "HR": "hr-HR", "SI": "sl-SI", "BA": "bs-BA", "ME": "sr-ME",
        "MK": "mk-MK", "AL": "sq-AL",
        "UA": "uk-UA", "BY": "ru-BY", "RU": "ru-RU",
        // Middle East, Caucasus, Central Asia
        "TR": "tr-TR", "IL": "he-IL", "AE": "ar-AE", "SA": "ar-SA", "QA": "ar-QA", "KW": "ar-KW",
        "BH": "ar-BH", "OM": "ar-OM", "JO": "ar-JO", "LB": "ar-LB", "IQ": "ar-IQ", "EG": "ar-EG",
        "IR": "fa-IR", "GE": "ka-GE", "AM": "hy-AM", "AZ": "az-AZ", "KZ": "ru-KZ", "KG": "ru-KG",
        "UZ": "uz-UZ",
        // Africa
        "MA": "fr-MA", "DZ": "fr-DZ", "TN": "fr-TN", "ZA": "en-ZA", "NG": "en-NG", "KE": "en-KE",
        "GH": "en-GH",
        // Americas
        "US": "en-US", "CA": "en-CA", "MX": "es-MX", "BR": "pt-BR", "AR": "es-AR", "CL": "es-CL",
        "CO": "es-CO", "PE": "es-PE", "VE": "es-VE", "EC": "es-EC", "UY": "es-UY", "PY": "es-PY",
        "BO": "es-BO", "CR": "es-CR", "PA": "es-PA", "DO": "es-DO", "GT": "es-GT", "PR": "es-PR",
        // Asia-Pacific
        "JP": "ja-JP", "KR": "ko-KR", "CN": "zh-CN", "TW": "zh-TW", "HK": "zh-HK", "MO": "zh-MO",
        "SG": "en-SG", "IN": "en-IN", "PK": "en-PK", "BD": "bn-BD", "TH": "th-TH", "VN": "vi-VN",
        "ID": "id-ID", "MY": "ms-MY", "PH": "en-PH", "AU": "en-AU", "NZ": "en-NZ",
    ]
}
