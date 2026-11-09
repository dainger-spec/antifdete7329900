import CryptoKit
import Foundation

/// The signed document of rights (the account server's `docs/CONTRACT.md` §7, `docs/IPHONE.md`): what
/// this iPhone may do, and until when, without asking the server. The app checks it itself and
/// decides from it alone (`License`). The check is the Mac app's, step for step
/// (Sources/BrowserCore/License/Entitlement.swift), run on the server's own test vectors.
///
/// ```json
/// {"format": 1, "keyID": "<16 hex>", "payload": "<base64 of the document's JSON>", "signature": "<base64 Ed25519 of those bytes>"}
/// ```
public struct Entitlement: Equatable, Sendable {
    public enum Status: String, Sendable {
        case active
        case exportOnly = "export_only"
    }

    /// What a plan opens (`features`). No name — no right; a name this app does not know opens nothing
    /// and breaks nothing ("automation" is the Mac's: an iPhone has none).
    public static let browse = "browse"
    public static let proxies = "proxies"

    public var accountID: String
    public var licenseID: String
    public var deviceID: String
    public var machineID: String
    /// "trial", "personal", "pro", "team", "none" — or a newer one, shown as it came.
    public var plan: String
    public var status: Status
    /// With `exportOnly`: "no_license", "period_ended", "account_disabled", or a newer one (read as
    /// "period_ended"). Nil with `active`.
    public var exportReason: String?
    /// Profiles on the whole license (`limits.profiles`): all its devices together.
    public var profiles: Int
    /// The profiles the license's other devices reported.
    public var profilesOnOtherDevices: Int
    /// The end of the paid (or trial) period; nil when there never was one.
    public var periodEndsAt: Date?
    public var issuedAt: Date
    /// After this, the app must try to refresh the document.
    public var refreshAfter: Date
    /// Until this, the app works by this document without the server.
    public var expiresAt: Date
    /// Until this — the server still silent — work goes on with a warning.
    public var graceEndsAt: Date
    public var features: Set<String>

    public init(accountID: String = "", licenseID: String = "", deviceID: String, machineID: String, plan: String,
                status: Status, exportReason: String? = nil, profiles: Int, profilesOnOtherDevices: Int = 0,
                periodEndsAt: Date?, issuedAt: Date, refreshAfter: Date, expiresAt: Date, graceEndsAt: Date,
                features: Set<String> = []) {
        self.accountID = accountID
        self.licenseID = licenseID
        self.deviceID = deviceID
        self.machineID = machineID
        self.plan = plan
        self.status = status
        self.exportReason = exportReason
        self.profiles = profiles
        self.profilesOnOtherDevices = profilesOnOtherDevices
        self.periodEndsAt = periodEndsAt
        self.issuedAt = issuedAt
        self.refreshAfter = refreshAfter
        self.expiresAt = expiresAt
        self.graceEndsAt = graceEndsAt
        self.features = features
    }

    /// How many profiles this iPhone may use: the license's limit less what its other devices
    /// reported, never below 0 (§8.4).
    public var allowedProfilesHere: Int { max(0, profiles - profilesOnOtherDevices) }
}

/// The result of checking a document, by the contract's steps (§7.4) — the same names as the
/// `verify` field of the server's test vectors.
public enum EntitlementCheck: Equatable, Sendable {
    case valid(Entitlement)
    case notADocument
    case newerFormat
    case unknownKey
    case badSignature
    case wrongKind
    case newerVersion
    case wrongDevice
    case malformed

    public var name: String {
        switch self {
        case .valid: return "ok"
        case .notADocument: return "not_a_document"
        case .newerFormat: return "newer_format"
        case .unknownKey: return "unknown_key"
        case .badSignature: return "bad_signature"
        case .wrongKind: return "wrong_kind"
        case .newerVersion: return "newer_version"
        case .wrongDevice: return "wrong_device"
        case .malformed: return "malformed"
        }
    }

    public var entitlement: Entitlement? {
        if case .valid(let entitlement) = self { return entitlement }
        return nil
    }

    /// The server works and this app is too old to judge what it sent (§9.4): the stored document
    /// is kept, and the person is asked to update.
    public var meansAppOutdated: Bool {
        self == .unknownKey || self == .newerFormat || self == .newerVersion
    }
}

/// The keys this app trusts for documents of rights: key id → raw Ed25519 public key (32 bytes),
/// from `PBEntitlementPublicKeys` in its `Info.plist` (§7.2).
public enum EntitlementKeys {
    /// The development server's public key, which anyone knows. A release build must not carry it
    /// (ios/scripts/release_rules.py refuses one that does).
    public static let developmentKeyID = "445c6300da0205b1"

    /// A key's id: the first 8 bytes of the SHA-256 of its raw public key, in lowercase hex.
    public static func keyID(of publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The keys a dictionary names (key id → base64). An entry whose id is not its key's, or that is
    /// not a 32-byte key, is left out.
    public static func from(_ value: Any?) -> [String: Data] {
        guard let entries = value as? [String: String] else { return [:] }
        var keys: [String: Data] = [:]
        for (id, text) in entries {
            guard let raw = Data(base64Encoded: text), raw.count == 32, keyID(of: raw) == id.lowercased() else { continue }
            keys[id.lowercased()] = raw
        }
        return keys
    }
}

/// Checking a document of rights, step by step in the contract's order (§7.4). Nothing of the
/// payload is read before its signature checks with a key this app carries.
public enum EntitlementVerifier {
    /// `document`: the envelope's JSON as it came or as it was stored. `deviceID`: this iPhone's
    /// device in the license, as the activation answered it. `machineID`: computed now (`PhoneID`).
    public static func check(_ document: Data, keys: [String: Data], deviceID: String, machineID: String) -> EntitlementCheck {
        // 1. A JSON object with a whole-number `format`.
        guard let declared = try? JSONDecoder().decode(FormatField.self, from: document) else { return .notADocument }
        // 2. A newer format is not judged.
        guard declared.format <= 1 else { return .newerFormat }
        // 3. The fields of this format: an id, a payload that is not empty, both in base64.
        guard declared.format == 1,
              let fields = try? JSONDecoder().decode(EnvelopeFields.self, from: document),
              !fields.payload.isEmpty, let payload = Data(base64Encoded: fields.payload), !payload.isEmpty,
              let signature = Data(base64Encoded: fields.signature) else { return .notADocument }
        // 4. A key this app carries.
        guard let raw = keys[fields.keyID] else { return .unknownKey }
        // 5. The signature over the payload's bytes. (The planted fault: not checked at all.)
        if !Faults.isActive(.signatureNotChecked) {
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
                  key.isValidSignature(signature, for: payload) else { return .badSignature }
        }
        // 6. A document of rights, of a version this app reads.
        guard let content = try? JSONDecoder().decode(PayloadFields.self, from: payload),
              content.kind == "lumen.entitlement" else { return .wrongKind }
        if let version = content.version, version > 1 { return .newerVersion }
        // 7. This device, on this iPhone. (The planted fault: any device's document will do.)
        guard let documentDevice = content.deviceID, let documentMachine = content.machineID else { return .wrongDevice }
        if !Faults.isActive(.wrongDeviceAccepted) {
            guard documentDevice.lowercased() == deviceID.lowercased(),
                  documentMachine.lowercased() == machineID.lowercased() else { return .wrongDevice }
        }
        // 8. Everything decided by, readable.
        guard let entitlement = content.entitlement(deviceID: documentDevice, machineID: documentMachine) else { return .malformed }
        return .valid(entitlement)
    }

    // MARK: Reading, field by field

    private struct FormatField: Decodable {
        let format: Int
    }

    private struct EnvelopeFields: Decodable {
        let format: Int
        let keyID: String
        let payload: String
        let signature: String
    }

    /// Every field optional and read on its own, so that the steps above decide in the contract's
    /// order — a field of the wrong type is a missing one, not a failure of the whole.
    private struct PayloadFields: Decodable {
        var kind: String?
        var version: Int?
        var accountID: String?
        var licenseID: String?
        var deviceID: String?
        var machineID: String?
        var plan: String?
        var status: String?
        var exportReason: String?
        var profiles: Int?
        var profilesOnOtherDevices: Int?
        var periodEndsAt: String?
        var periodEndsAtIsNull = false
        var issuedAt: String?
        var refreshAfter: String?
        var expiresAt: String?
        var graceEndsAt: String?
        var features: [String]?

        struct LimitsFields: Decodable {
            var profiles: Int?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                profiles = try? container.decode(Int.self, forKey: Key("profiles"))
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            func string(_ name: String) -> String? { try? container.decode(String.self, forKey: Key(name)) }
            kind = string("kind")
            version = try? container.decode(Int.self, forKey: Key("version"))
            accountID = string("accountID")
            licenseID = string("licenseID")
            deviceID = string("deviceID")
            machineID = string("machineID")
            plan = string("plan")
            status = string("status")
            exportReason = string("exportReason")
            profiles = (try? container.decode(LimitsFields.self, forKey: Key("limits")))?.profiles
            profilesOnOtherDevices = try? container.decode(Int.self, forKey: Key("profilesOnOtherDevices"))
            periodEndsAt = string("periodEndsAt")
            periodEndsAtIsNull = (try? container.decodeNil(forKey: Key("periodEndsAt"))) ?? true
            issuedAt = string("issuedAt")
            refreshAfter = string("refreshAfter")
            expiresAt = string("expiresAt")
            graceEndsAt = string("graceEndsAt")
            // A list of names; anything else there (not a list, a list of other things) opens nothing.
            features = try? container.decode([String].self, forKey: Key("features"))
        }

        func entitlement(deviceID: String, machineID: String) -> Entitlement? {
            guard let statusText = status, let status = Entitlement.Status(rawValue: statusText), let plan,
                  let profiles, let profilesOnOtherDevices,
                  let issuedAt = issuedAt.flatMap(Self.time), let refreshAfter = refreshAfter.flatMap(Self.time),
                  let expiresAt = expiresAt.flatMap(Self.time), let graceEndsAt = graceEndsAt.flatMap(Self.time) else { return nil }
            // `periodEndsAt` may be null — there was no period — but never an unreadable time.
            let periodEndsAt: Date?
            if let text = self.periodEndsAt {
                guard let time = Self.time(text) else { return nil }
                periodEndsAt = time
            } else {
                guard periodEndsAtIsNull else { return nil }
                periodEndsAt = nil
            }
            let names = Set(features ?? [])
            // The planted fault: a name this app does not know makes the whole document unreadable.
            if Faults.isActive(.unknownFeatureRejected), !names.subtracting([Entitlement.browse, Entitlement.proxies]).isEmpty {
                return nil
            }
            return Entitlement(accountID: accountID ?? "", licenseID: licenseID ?? "", deviceID: deviceID, machineID: machineID,
                               plan: plan, status: status,
                               exportReason: status == .exportOnly ? (exportReason ?? "period_ended") : nil,
                               profiles: profiles, profilesOnOtherDevices: profilesOnOtherDevices, periodEndsAt: periodEndsAt,
                               issuedAt: issuedAt, refreshAfter: refreshAfter, expiresAt: expiresAt, graceEndsAt: graceEndsAt,
                               features: names)
        }

        /// RFC 3339 in UTC, `Z`, no fractions of a second (§2) — anything else is unreadable. The
        /// form is checked here, character by character, as the Mac app does.
        static func time(_ text: String) -> Date? {
            let characters = Array(text.utf8)
            guard characters.count == 20 else { return nil }
            for (index, character) in characters.enumerated() {
                let expected: UInt8?
                switch index {
                case 4, 7: expected = UInt8(ascii: "-")
                case 10: expected = UInt8(ascii: "T")
                case 13, 16: expected = UInt8(ascii: ":")
                case 19: expected = UInt8(ascii: "Z")
                default: expected = nil
                }
                if let expected {
                    guard character == expected else { return nil }
                } else {
                    guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(character) else { return nil }
                }
            }
            return try? Date.ISO8601FormatStyle().parse(text)
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// This iPhone's id for the server (`docs/IPHONE.md` §2.1): a random identifier the app makes once
/// and keeps in the Keychain — it outlives a reinstall, which `identifierForVendor` does not — and
/// never sends as it is:
///
/// `machineID = lowercase_hex(SHA-256(UTF-8("lumen.machine-id.ios.v1\n" + id)))`
public enum PhoneID {
    public static func machineID(of id: String) -> String {
        SHA256.hash(data: Data(("lumen.machine-id.ios.v1\n" + id).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A new random identifier: 32 random bytes, in lowercase hex.
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
