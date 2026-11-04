#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The key of a license bought without registration: `LMK-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`, 22 random
/// characters and 2 check characters in Crockford's base32 (the server's `internal/ident`, its
/// `docs/CONTRACT.md` §18). For such an account the key is everything — no email, no password, no
/// name — so it is kept as carefully as the master password (the owner, 1 November): never in
/// settings, logs, diagnostics or error reports.
///
/// The value never says itself: interpolated, printed, dumped or mirrored it shows `LMK-…` and no
/// more (`description`, `debugDescription`, `customMirror`). Its text comes out only through
/// `unredacted()`, called in two places — the request that carries it and the vault's file that
/// keeps it — which `scripts/check_account_key.py` holds to.
public struct AccountKey: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let canonical: String

    /// A key as a person typed or pasted it, when it reads as one — as the server reads it: case does
    /// not matter; hyphens, spaces and dashes are ignored; the prefix may be left out; I and L are
    /// read as 1 and O as 0. Nil when it does not read — a character that cannot be there, a wrong
    /// length, check characters that do not match: a typo, caught here before anything is sent.
    public init?(typed text: String) {
        guard let canonical = CrockfordCode.parse(text, kind: .key) else { return nil }
        self.canonical = canonical
    }

    /// A key read back from where the app keeps it (the vault): its canonical text.
    init?(stored text: String) {
        guard let canonical = CrockfordCode.parse(text, kind: .key), canonical == text else { return nil }
        self.canonical = canonical
    }

    /// The key's text, `LMK-XXXX-…`: only for the request that sends it to the server and the
    /// vault's file that keeps it (scripts/check_account_key.py).
    public func unredacted() -> String { canonical }

    public var description: String { "LMK-…" }
    public var debugDescription: String { "AccountKey(LMK-…)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The code of a purchase without registration, `LPC-XXXX-XXXX-XXXX-XXXX-XXXX` (18 random characters
/// and 2 check characters, the server's `docs/CONTRACT.md` §18). With the key it proves who paid: an
/// email is linked and the key replaced only with both (§11.1) — the code is with the one who paid and
/// usually not with whoever got hold of the key. The app never keeps it: asked of the person each time,
/// sent in the request's body, forgotten. It never says itself, as the key does not.
public struct PurchaseCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let canonical: String

    /// A purchase code as it was typed, read as the server reads it (§18); nil — a typo.
    public init?(typed text: String) {
        guard let canonical = CrockfordCode.parse(text, kind: .purchaseCode) else { return nil }
        self.canonical = canonical
    }

    /// The code's text: only for the request that carries it (scripts/check_account_key.py).
    public func unredacted() -> String { canonical }

    public var description: String { "LPC-…" }
    public var debugDescription: String { "PurchaseCode(LPC-…)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The key typed in this session, kept only to be compared with the master password about to be set
/// (§10.1, the owner's rule): the key goes to the server at every activation and passes Cloudflare, so
/// it must not lock what the server must not read. Not the key itself: an HMAC of its canonical text
/// under a key made for this once — in memory only, never on disk, forgotten after the master
/// password's step. A candidate is read as a key is read (§18: case, hyphens, spaces, the prefix,
/// I/L/O) and compared in its canonical form; one that does not read as a key is not the key.
public struct AccountKeyEcho {
    private let secret: SymmetricKey
    private let code: Data

    public init(_ key: AccountKey) {
        secret = SymmetricKey(size: .bits256)
        code = Data(HMAC<SHA256>.authenticationCode(for: Data(key.unredacted().utf8), using: secret))
    }

    /// Whether `candidate`, read as a key, is this key.
    public func matches(_ candidate: String) -> Bool {
        guard let typed = AccountKey(typed: candidate) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(typed.unredacted().utf8), using: secret)
    }
}

extension AccountKey {
    /// Whether `candidate`, read as a key is read (§18), is this key: compared in canonical form, in
    /// memory (§10.1).
    public func isTyped(as candidate: String) -> Bool {
        AccountKey(typed: candidate) == self
    }
}

/// What a key field holds, before anything is sent: a key, or why not. Not the text itself in any
/// case — a typo is told without repeating what was typed.
public enum AccountKeyInput: Equatable, Sendable {
    case empty
    case key(AccountKey)
    /// A purchase code (`LPC-…`): it proves the purchase on the site, it does not sign in.
    case purchaseCode
    /// An invoice's number (`LMN-…`).
    case invoiceNumber
    /// Cyrillic letters where a key has only Latin ones and digits: the keyboard is in Russian.
    case cyrillic
    /// Not a key: a wrong character, length or check characters.
    case typo

    public static func classify(_ text: String) -> AccountKeyInput {
        let normalized = CrockfordCode.normalized(text)
        guard !normalized.isEmpty else { return .empty }
        if let key = AccountKey(typed: text) { return .key(key) }
        if CrockfordCode.parse(text, kind: .purchaseCode) != nil { return .purchaseCode }
        if CrockfordCode.parse(text, kind: .invoiceNumber) != nil { return .invoiceNumber }
        if normalized.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return .cyrillic }
        return .typo
    }
}

/// The codes people copy by hand (the server's `internal/ident`): random characters in Crockford's
/// base32 — digits and letters without I, L, O, U — grouped by four, and two check characters: a
/// CRC-10 (x¹⁰+x⁹+x⁵+x⁴+x+1, 0x233; start 0; nothing reflected or inverted) over the characters'
/// 5-bit values, most significant bit first, written high 5 bits first. It catches every single
/// wrong character and every swap of two neighbouring ones.
enum CrockfordCode {
    struct Kind: Equatable {
        let prefix: String
        /// Random characters before the two check characters.
        let data: Int

        static let key = Kind(prefix: "LMK", data: 22)
        static let purchaseCode = Kind(prefix: "LPC", data: 18)
        static let invoiceNumber = Kind(prefix: "LMN", data: 18)
    }

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The text with case folded and what is ignored taken out: hyphens, dashes, spaces.
    static func normalized(_ text: String) -> String {
        let ignored: Set<Character> = ["-", " ", "\t", "\n", "\r", "\u{00A0}", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"]
        return String(text.uppercased().filter { !ignored.contains($0) })
    }

    /// The 5-bit value of each character a code may hold: the alphabet's, I and L read as 1, O as 0.
    private static let value: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (index, character) in alphabet.enumerated() { map[character] = index }
        map["I"] = 1
        map["L"] = 1
        map["O"] = 0
        return map
    }()

    static func checksum(_ values: [Int]) -> Int {
        var crc = 0
        for value in values {
            for bit in stride(from: 4, through: 0, by: -1) {
                let input = (value >> bit) & 1
                let top = (crc >> 9) & 1
                crc = (crc << 1) & 0x3ff
                if top ^ input == 1 { crc ^= 0x233 }
            }
        }
        return crc
    }

    /// The canonical form of `text` read as a code of `kind`, or nil when it does not read.
    static func parse(_ text: String, kind: Kind) -> String? {
        var characters = normalized(text)
        // The prefix may be left out; a code of another kind still fails on its length.
        if characters.hasPrefix(kind.prefix) { characters.removeFirst(kind.prefix.count) }
        guard characters.count == kind.data + 2 else { return nil }
        var values: [Int] = []
        for character in characters {
            guard let value = value[character] else { return nil }
            values.append(value)
        }
        let data = Array(values.prefix(kind.data))
        let crc = checksum(data)
        guard values[kind.data] == crc >> 5, values[kind.data + 1] == crc & 31 else { return nil }
        return format(kind, data)
    }

    static func format(_ kind: Kind, _ data: [Int]) -> String {
        let crc = checksum(data)
        let all = data + [crc >> 5, crc & 31]
        var text = kind.prefix
        for (index, value) in all.enumerated() {
            if index % 4 == 0 { text += "-" }
            text.append(alphabet[value])
        }
        return text
    }
}
