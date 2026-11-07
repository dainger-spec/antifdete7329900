import Foundation

/// The language and time zone a session's pages get from its proxy's exit country.
public enum CountryLocale {
    /// The language websites expect from a Safari user in a country: the macOS app's table
    /// (BrowserCore/Profiles/ProxyLocation.swift, `webLanguages`), English when unknown.
    public static func language(forCountry code: String?) -> String {
        guard let code = code?.uppercased() else { return "en-US" }
        return webLanguages[code] ?? "en-US"
    }

    static let webLanguages: [String: String] = [
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
        "TR": "tr-TR", "IL": "he-IL", "AE": "ar-AE", "SA": "ar-SA", "QA": "ar-QA", "KW": "ar-KW",
        "BH": "ar-BH", "OM": "ar-OM", "JO": "ar-JO", "LB": "ar-LB", "IQ": "ar-IQ", "EG": "ar-EG",
        "IR": "fa-IR", "GE": "ka-GE", "AM": "hy-AM", "AZ": "az-AZ", "KZ": "ru-KZ", "KG": "ru-KG",
        "UZ": "uz-UZ",
        "MA": "fr-MA", "DZ": "fr-DZ", "TN": "fr-TN", "ZA": "en-ZA", "NG": "en-NG", "KE": "en-KE",
        "US": "en-US", "CA": "en-CA", "MX": "es-MX", "BR": "pt-BR", "AR": "es-AR", "CL": "es-CL",
        "CO": "es-CO", "PE": "es-PE", "VE": "es-VE",
        "JP": "ja-JP", "KR": "ko-KR", "CN": "zh-CN", "TW": "zh-TW", "HK": "zh-HK", "SG": "en-SG",
        "IN": "en-IN", "ID": "id-ID", "MY": "ms-MY", "TH": "th-TH", "VN": "vi-VN", "PH": "en-PH",
        "AU": "en-AU", "NZ": "en-NZ",
    ]

    /// The flag emoji of a country code ("DE" → 🇩🇪).
    public static func flag(_ code: String?) -> String {
        guard let code = code?.uppercased(), code.count == 2 else { return "" }
        return code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
}

/// Safari's User-Agent on an iPhone. WebKit freezes the OS version in it (iOS 26 and 27 both say
/// "18_7", measured on the iOS 26.2, 26.5 and 27.2 simulators); Safari adds its own version and
/// "Safari/604.1" (the owner's iPhone, Safari 27: `… Version/27.0 Mobile/15E148 Safari/604.1`).
public struct UserAgentPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let userAgent: String

    public static let all: [UserAgentPreset] = [
        .init(id: "ios27", title: "iOS 27 — Safari 27",
              userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"),
        .init(id: "ios26", title: "iOS 26 — Safari 26",
              userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"),
        .init(id: "ios18", title: "iOS 18.6 — Safari 18.6",
              userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"),
        .init(id: "ios17", title: "iOS 17.5 — Safari 17.5",
              userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"),
    ]

    public static func preset(id: String) -> UserAgentPreset? { all.first { $0.id == id } }

    /// What WKWebView's configuration should append to WebKit's own string to read as Safari
    /// (`applicationNameForUserAgent`): Safari's version, "Mobile/15E148", "Safari/604.1".
    public static func safariApplicationName(systemVersion: String) -> String {
        let parts = systemVersion.split(separator: ".")
        let major = parts.first.map(String.init) ?? "17"
        let minor = parts.count > 1 ? String(parts[1]) : "0"
        return "Version/\(major).\(minor) Mobile/15E148 Safari/604.1"
    }
}
