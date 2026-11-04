import Foundation

/// More of where a proxy exits than `ProxyLocation` keeps: the city and the network (its
/// autonomous system number, "AS13335", and who runs it), as the geolocation service the check
/// asked through the proxy said. Only for the Proxies screen: a profile is not set by them.
///
/// The services say it each their own way — ipinfo.io `"org": "AS13335 Cloudflare, Inc."`,
/// geojs `"asn": 13335` with `"organization_name"`, ipwho.is `"connection": {"asn": 13335,
/// "org": …}` — so the number is read from a number or from the start of a text.
public struct ProxyExitDetails: Equatable, Sendable {
    public var city: String?
    public var asn: String?
    public var organization: String?

    public init(city: String? = nil, asn: String? = nil, organization: String? = nil) {
        self.city = city
        self.asn = asn
        self.organization = organization
    }

    public static func parse(_ data: Data, cityKeyPath: [String]?, asnKeyPath: [String]?,
                             organizationKeyPath: [String]?) -> ProxyExitDetails {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return ProxyExitDetails() }
        func value(at path: [String]?) -> Any? {
            guard let path, !path.isEmpty else { return nil }
            var current: Any? = object
            for key in path { current = (current as? [String: Any])?[key] }
            return current
        }
        func text(_ value: Any?) -> String? {
            guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
            return String(string.prefix(80))
        }
        var details = ProxyExitDetails(city: text(value(at: cityKeyPath)))
        // The number: as a number, as digits, or as the "AS…" a text starts with.
        let asnValue = value(at: asnKeyPath)
        if let number = asnValue as? Int ?? (asnValue as? NSNumber)?.intValue, number > 0 {
            details.asn = "AS\(number)"
        } else if let string = text(asnValue) {
            let (asn, rest) = splitASN(string)
            details.asn = asn
            if asnKeyPath == organizationKeyPath { details.organization = rest }
        }
        if details.organization == nil, let organization = text(value(at: organizationKeyPath)) {
            let (asn, rest) = splitASN(organization)
            if details.asn == nil { details.asn = asn }
            details.organization = rest ?? (asn == nil ? organization : nil)
        }
        return details
    }

    /// "AS13335 Cloudflare, Inc." → ("AS13335", "Cloudflare, Inc."); "13335" → ("AS13335", nil);
    /// anything else → (nil, the text).
    static func splitASN(_ text: String) -> (asn: String?, rest: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(trimmed), number > 0 {
            return ("AS\(number)", nil)
        }
        let upper = trimmed.uppercased()
        guard upper.hasPrefix("AS") else { return (nil, trimmed.isEmpty ? nil : trimmed) }
        let digits = upper.dropFirst(2).prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return (nil, trimmed) }
        let rest = trimmed.dropFirst(2 + digits.count).trimmingCharacters(in: .whitespaces)
        return ("AS\(number)", rest.isEmpty ? nil : rest)
    }
}
