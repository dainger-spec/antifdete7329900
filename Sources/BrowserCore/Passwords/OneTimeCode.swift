#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// RFC 4648 Base32, as authenticator secrets are written: letters A–Z and digits 2–7.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// The bytes `text` stands for. Lenient where people are: either case, spaces and dashes
    /// between groups, padding or none. Nil for a character that is not Base32's, or for nothing.
    public static func decode(_ text: String) -> Data? {
        var bytes = Data()
        var buffer: UInt32 = 0
        var bits = 0
        var seen = false
        for scalar in text.unicodeScalars {
            if scalar == "=" || scalar == "-" || scalar.properties.isWhitespace { continue }
            let value: UInt32
            switch scalar.value {
            case 0x41...0x5A: value = scalar.value - 0x41       // A–Z
            case 0x61...0x7A: value = scalar.value - 0x61       // a–z
            case 0x32...0x37: value = scalar.value - 0x32 + 26  // 2–7
            default: return nil
            }
            seen = true
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return seen && !bytes.isEmpty ? bytes : nil
    }

    /// `data` in Base32, upper case, without padding (as authenticators show a secret).
    public static func encode(_ data: Data) -> String {
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)]) }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Why a text is not a one-time code's secret (`OneTimeCode.parse`).
public enum OneTimeCodeError: Error, Equatable, Sendable {
    /// Nothing was given.
    case empty
    /// Neither an `otpauth://` link nor a Base32 secret.
    case notASecret
    /// An `otpauth://hotp/…` link: a code counted by use, not by time. Not generated here.
    case counterBased
    /// An export of several accounts (`otpauth-migration://`), which holds no single secret.
    case severalAccounts
    /// The link names an algorithm, a number of digits or a period this cannot generate.
    case unsupported
}

/// What generates a login's one-time codes (TOTP, RFC 6238): the secret the site gave when
/// two-step sign-in was set up, and how codes are made from it. Kept in the login it belongs to
/// (`PasswordEntry.totp`), so it is sealed, synced and merged as the password is.
public struct OneTimeCode: Codable, Equatable, Sendable {
    public enum Algorithm: String, Codable, Sendable, CaseIterable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    public static let digitsAllowed = 6...8
    public static let periodsAllowed = 5...600

    /// The shared secret's bytes.
    public var secret: Data
    public var algorithm: Algorithm
    /// How many digits a code has: 6, 7 or 8.
    public var digits: Int
    /// For how many seconds one code stands.
    public var period: Int
    /// Who issued it and for which account, as the link said (shown, never used to make a code).
    public var issuer: String?
    public var account: String?

    public init?(secret: Data, algorithm: Algorithm = .sha1, digits: Int = 6, period: Int = 30,
                 issuer: String? = nil, account: String? = nil) {
        guard !secret.isEmpty, Self.digitsAllowed.contains(digits), Self.periodsAllowed.contains(period) else { return nil }
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.issuer = issuer.flatMap { $0.isEmpty ? nil : $0 }
        self.account = account.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The secret as authenticators show it: Base32 in groups of four.
    public var secretText: String {
        let text = Array(Base32.encode(secret))
        return stride(from: 0, to: text.count, by: 4).map { String(text[$0..<min($0 + 4, text.count)]) }.joined(separator: " ")
    }

    /// What a person pasted, typed or scanned: an `otpauth://totp/…` link (a QR code holds one),
    /// or the secret alone in Base32 — then SHA-1, six digits, thirty seconds, as nearly every
    /// site means when it shows only a secret.
    public static func parse(_ text: String) throws -> OneTimeCode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OneTimeCodeError.empty }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("otpauth-migration:") { throw OneTimeCodeError.severalAccounts }
        guard lowered.hasPrefix("otpauth:") else {
            guard let secret = Base32.decode(trimmed), let code = OneTimeCode(secret: secret) else { throw OneTimeCodeError.notASecret }
            return code
        }
        guard let components = URLComponents(string: trimmed) else { throw OneTimeCodeError.notASecret }
        switch (components.host ?? "").lowercased() {
        case "totp": break
        case "hotp": throw OneTimeCodeError.counterBased
        default: throw OneTimeCodeError.notASecret
        }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] { parameters[item.name.lowercased()] = item.value ?? "" }
        guard let secret = parameters["secret"].flatMap(Base32.decode) else { throw OneTimeCodeError.notASecret }
        var algorithm = Algorithm.sha1
        if let named = parameters["algorithm"], !named.isEmpty {
            guard let known = Algorithm(rawValue: named.uppercased().replacingOccurrences(of: "-", with: "")) else {
                throw OneTimeCodeError.unsupported
            }
            algorithm = known
        }
        var digits = 6, period = 30
        if let given = parameters["digits"], !given.isEmpty {
            guard let number = Int(given) else { throw OneTimeCodeError.unsupported }
            digits = number
        }
        if let given = parameters["period"], !given.isEmpty {
            guard let number = Int(given) else { throw OneTimeCodeError.unsupported }
            period = number
        }
        // The label is "Issuer:account" or the account alone; the issuer parameter wins.
        var label = components.path
        if label.hasPrefix("/") { label.removeFirst() }
        var issuer = parameters["issuer"]
        var account: String? = label
        if let colon = label.firstIndex(of: ":") {
            if issuer == nil || issuer?.isEmpty == true { issuer = String(label[..<colon]) }
            account = String(label[label.index(after: colon)...])
        }
        account = account?.trimmingCharacters(in: .whitespaces)
        issuer = issuer?.trimmingCharacters(in: .whitespaces)
        guard let code = OneTimeCode(secret: secret, algorithm: algorithm, digits: digits, period: period,
                                     issuer: issuer, account: account) else { throw OneTimeCodeError.unsupported }
        return code
    }

    /// The code that stands at `date`: digits only, with its leading zeros.
    public func code(at date: Date = Date()) -> String {
        // A file may hold what `init` would refuse: held to what can be computed.
        let digits = min(max(self.digits, Self.digitsAllowed.lowerBound), Self.digitsAllowed.upperBound)
        let seconds = max(0, date.timeIntervalSince1970)
        var counter = UInt64(seconds / Double(max(period, 1))).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let text = String(truncated % modulus)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    /// For how many more seconds the code of `date` stands (1…`period`).
    public func secondsLeft(at date: Date = Date()) -> Int {
        let period = max(self.period, 1)
        return period - Int(max(0, date.timeIntervalSince1970)) % period
    }

    /// What tells one generator from another, for a login's derived version (`PasswordEntry.currentVersion`).
    var fingerprint: String {
        [secret.base64EncodedString(), algorithm.rawValue, String(digits), String(period), issuer ?? "", account ?? ""]
            .joined(separator: "\u{1E}")
    }
}
