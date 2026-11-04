import Foundation

/// Where a profile's time zone and language come from (`ProfileConfiguration.localeSource`).
public enum LocaleSource: String, Codable, Sendable, CaseIterable {
    /// Where the connection comes out: the proxy's country, looked up through it at each launch;
    /// without a proxy, this Mac's.
    case connection
    /// The ones the person chose.
    case manual
    /// A country's own pair, chosen at random once and kept until another is picked.
    case random
}

/// Time zones and languages that belong together: what a random choice picks from, and the
/// languages a manual one offers.
public enum LocalePlaces {
    public struct Place: Equatable, Sendable {
        /// ISO 3166-1 alpha-2.
        public let country: String
        public let timeZone: String
        /// BCP 47, as Safari there would send it.
        public let language: String
    }

    /// One pair per place, each a country's most common one.
    public static let all: [Place] = [
        Place(country: "US", timeZone: "America/New_York", language: "en-US"),
        Place(country: "US", timeZone: "America/Chicago", language: "en-US"),
        Place(country: "US", timeZone: "America/Los_Angeles", language: "en-US"),
        Place(country: "CA", timeZone: "America/Toronto", language: "en-CA"),
        Place(country: "MX", timeZone: "America/Mexico_City", language: "es-MX"),
        Place(country: "BR", timeZone: "America/Sao_Paulo", language: "pt-BR"),
        Place(country: "GB", timeZone: "Europe/London", language: "en-GB"),
        Place(country: "IE", timeZone: "Europe/Dublin", language: "en-IE"),
        Place(country: "DE", timeZone: "Europe/Berlin", language: "de-DE"),
        Place(country: "AT", timeZone: "Europe/Vienna", language: "de-AT"),
        Place(country: "CH", timeZone: "Europe/Zurich", language: "de-CH"),
        Place(country: "FR", timeZone: "Europe/Paris", language: "fr-FR"),
        Place(country: "BE", timeZone: "Europe/Brussels", language: "nl-BE"),
        Place(country: "NL", timeZone: "Europe/Amsterdam", language: "nl-NL"),
        Place(country: "ES", timeZone: "Europe/Madrid", language: "es-ES"),
        Place(country: "PT", timeZone: "Europe/Lisbon", language: "pt-PT"),
        Place(country: "IT", timeZone: "Europe/Rome", language: "it-IT"),
        Place(country: "DK", timeZone: "Europe/Copenhagen", language: "da-DK"),
        Place(country: "SE", timeZone: "Europe/Stockholm", language: "sv-SE"),
        Place(country: "NO", timeZone: "Europe/Oslo", language: "nb-NO"),
        Place(country: "FI", timeZone: "Europe/Helsinki", language: "fi-FI"),
        Place(country: "PL", timeZone: "Europe/Warsaw", language: "pl-PL"),
        Place(country: "CZ", timeZone: "Europe/Prague", language: "cs-CZ"),
        Place(country: "TR", timeZone: "Europe/Istanbul", language: "tr-TR"),
        Place(country: "JP", timeZone: "Asia/Tokyo", language: "ja-JP"),
        Place(country: "KR", timeZone: "Asia/Seoul", language: "ko-KR"),
        Place(country: "SG", timeZone: "Asia/Singapore", language: "en-SG"),
        Place(country: "IN", timeZone: "Asia/Kolkata", language: "en-IN"),
        Place(country: "AU", timeZone: "Australia/Sydney", language: "en-AU"),
        Place(country: "NZ", timeZone: "Pacific/Auckland", language: "en-NZ"),
    ]

    /// A place at random, another than `current` when there is one; only places whose time zone
    /// this system knows.
    public static func random<G: RandomNumberGenerator>(using generator: inout G, otherThan current: Place? = nil) -> Place {
        let known = all.filter { TimeZone(identifier: $0.timeZone) != nil && $0 != current }
        return known.randomElement(using: &generator) ?? all[0]
    }

    /// The place a time zone and language are, if they are one of these.
    public static func place(timeZone: String?, language: String?) -> Place? {
        all.first { $0.timeZone == timeZone && $0.language == language }
    }

    /// The languages a manual choice offers: every country's web language, once, in order.
    public static var languages: [String] {
        Array(Set(ProxyLocation.webLanguages.values).union(all.map(\.language))).sorted()
    }

    /// A language tag as a browser sends it: "de", "de-DE", "zh-Hant-TW".
    public static func isLanguageTag(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (2...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }
}
