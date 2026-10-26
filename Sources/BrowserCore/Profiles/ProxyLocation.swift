import Foundation

/// Where a profile's proxy exits to the web, as a geolocation service saw it when asked through
/// that proxy: the exit IP's time zone and country. A site compares the same IP against the
/// time zone and language the browser reports (e.g. "Local Time Zone" vs "System Time Zone").
public struct ProxyLocation: Codable, Equatable, Sendable {
    /// IANA identifier, e.g. "Europe/Berlin".
    public var timeZoneIdentifier: String
    /// ISO 3166-1 alpha-2, upper case, e.g. "DE".
    public var countryCode: String?
    /// The proxy this was resolved for (`endpoint(of:)`): a stored location applies to it only.
    public var proxyEndpoint: String
    public var resolvedAt: Date

    public init(timeZoneIdentifier: String, countryCode: String?, proxyEndpoint: String, resolvedAt: Date = Date()) {
        self.timeZoneIdentifier = timeZoneIdentifier
        self.countryCode = countryCode
        self.proxyEndpoint = proxyEndpoint
        self.resolvedAt = resolvedAt
    }

    public static func endpoint(of proxy: ProxySettings) -> String {
        "\(proxy.kind.rawValue)://\(proxy.host):\(proxy.port)"
    }

    /// Same place for the same proxy (the lookup time aside).
    public func isSameLocation(as other: ProxyLocation?) -> Bool {
        guard let other else { return false }
        return timeZoneIdentifier == other.timeZoneIdentifier && countryCode == other.countryCode
            && proxyEndpoint == other.proxyEndpoint
    }

    /// Reads a geolocation service's JSON answer: the time zone at `timeZoneKeyPath`, the country
    /// at `countryKeyPath` (e.g. `["timezone", "id"]` for `{"timezone": {"id": "Europe/Berlin"}}`).
    /// nil unless the time zone is a known IANA identifier.
    public static func parse(_ data: Data, timeZoneKeyPath: [String], countryKeyPath: [String],
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
        return ProxyLocation(timeZoneIdentifier: zone, countryCode: country, proxyEndpoint: proxyEndpoint, resolvedAt: resolvedAt)
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
