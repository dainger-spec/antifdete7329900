#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The signed document of rights (the server's `docs/CONTRACT.md` §7): what this Mac may do, and
/// until when, without asking the server. The app checks it itself — never the server — and decides
/// from it alone (`LicenseDecision`), which is why it keeps working without the network for as long
/// as the document says (§8, §9.2).
///
/// ```json
/// {"format": 1, "keyID": "<16 hex>", "payload": "<base64 of the document's JSON>", "signature": "<base64 Ed25519 of those bytes>"}
/// ```
///
/// Stored as it came (`AccountRecord.entitlement`): the signature covers only the payload's bytes,
/// so the envelope may be re-encoded freely (§7.1).
public struct EntitlementEnvelope: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    /// Which key signed `payload`: the first 8 bytes of the SHA-256 of the raw Ed25519 public key,
    /// in lowercase hex (`EntitlementKeys.keyID(of:)`).
    public var keyID: String
    /// The document's JSON: exactly the bytes that were signed.
    public var payload: Data
    /// Ed25519 over `payload`.
    public var signature: Data

    public init(format: Int, keyID: String, payload: Data, signature: Data) {
        self.format = format
        self.keyID = keyID
        self.payload = payload
        self.signature = signature
    }
}

/// What a checked document says (§7.3). Only a document that passed every step of
/// `EntitlementVerifier.check` becomes one: nothing of an unchecked payload is read.
public struct Entitlement: Equatable, Sendable {
    public enum Status: String, Sendable {
        case active
        case exportOnly = "export_only"
    }

    public struct Limits: Equatable, Sendable {
        /// Profiles on the whole license: all its Macs together.
        public var profiles: Int
        /// Macs in the license.
        public var devices: Int
        /// Places in the team, the owner's included (1 outside a team).
        public var seats: Int

        public init(profiles: Int, devices: Int, seats: Int) {
            self.profiles = profiles
            self.devices = devices
            self.seats = seats
        }
    }

    /// For logs only. Empty when the server left it out: nothing is decided by these three.
    public var documentID: String
    public var accountID: String
    public var licenseID: String
    public var deviceID: String
    public var machineID: String
    /// "owner": the license is this account's own; "member": a place in a team, whose owner pays.
    /// Anything else is shown as a member's (no payment buttons).
    public var role: String
    /// "trial", "personal", "pro", "team", "none" — or a newer one, shown as it came (§13).
    public var plan: String
    public var status: Status
    /// With `exportOnly`: "no_license", "period_ended", "account_disabled", or a newer one (shown
    /// as "period_ended", §13). Nil with `active`.
    public var exportReason: String?
    public var limits: Limits
    /// The profiles the license's other active Macs reported.
    public var profilesOnOtherDevices: Int
    /// The end of the paid (or trial) period; nil when there never was one.
    public var periodEndsAt: Date?
    public var issuedAt: Date
    /// After this, the app must try to refresh the document (§9.1).
    public var refreshAfter: Date
    /// Until this, the app works by this document without the server.
    public var expiresAt: Date
    /// Until this — the server still silent — work goes on with a warning (GRACE).
    public var graceEndsAt: Date

    public init(documentID: String = "", accountID: String = "", licenseID: String = "", deviceID: String, machineID: String,
                role: String, plan: String, status: Status, exportReason: String?, limits: Limits, profilesOnOtherDevices: Int,
                periodEndsAt: Date?, issuedAt: Date, refreshAfter: Date, expiresAt: Date, graceEndsAt: Date) {
        self.documentID = documentID
        self.accountID = accountID
        self.licenseID = licenseID
        self.deviceID = deviceID
        self.machineID = machineID
        self.role = role
        self.plan = plan
        self.status = status
        self.exportReason = exportReason
        self.limits = limits
        self.profilesOnOtherDevices = profilesOnOtherDevices
        self.periodEndsAt = periodEndsAt
        self.issuedAt = issuedAt
        self.refreshAfter = refreshAfter
        self.expiresAt = expiresAt
        self.graceEndsAt = graceEndsAt
    }

    public var isOwner: Bool { role == "owner" }

    /// How long this Mac works without the server by this document: `graceEndsAt − issuedAt`
    /// (§17.1 — "без связи с сервером Lumen работает как обычно <срок>").
    public var offlineWork: TimeInterval { graceEndsAt.timeIntervalSince(issuedAt) }
}

/// The result of checking a document, by the contract's steps (§7.4) — the same names as the
/// `verify` field of the server's test vectors (`docs/entitlement-test-vectors.json`).
public enum EntitlementCheck: Equatable, Sendable {
    case valid(Entitlement)
    /// Not an envelope: not a JSON object, no whole-number `format`, an empty or non-base64 field —
    /// a captive portal's page looks like this.
    case notADocument
    /// An envelope of a newer format: not judged (this app needs an update).
    case newerFormat
    /// Signed with a key this app does not carry.
    case unknownKey
    /// The signature does not check: the payload was changed, or another key signed it.
    case badSignature
    /// Validly signed, but not a document of rights.
    case wrongKind
    /// A payload of a newer version: not judged (this app needs an update).
    case newerVersion
    /// Another device's or another Mac's document (copied here with the app's files).
    case wrongDevice
    /// Validly signed, but a field this app decides by is missing or unreadable.
    case malformed

    /// The contract's name of this result.
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
/// from `PBEntitlementPublicKeys` in its `Info.plist` (§7.2). Not the update keys: another key,
/// another list.
public enum EntitlementKeys {
    /// The development server's public key (`docker compose up` on the server's side), which anyone
    /// knows. A release build must not carry it: the release check refuses a build that does, and
    /// the production server refuses to sign with it (§7.2).
    public static let developmentKeyID = "445c6300da0205b1"
    public static let developmentPublicKey = "/+/sbiH55nmy+2gRqQz12E0spl9L/YDWvjnecaN2M1c="

    /// A key's id: the first 8 bytes of the SHA-256 of its raw public key, in lowercase hex.
    public static func keyID(of publicKey: Data) -> String {
        UpdateKeys.keyID(of: publicKey)
    }

    /// The keys an `Info.plist` names (`PBEntitlementPublicKeys`: key id → base64). An entry whose
    /// id is not its key's, or that is not a key, is left out — as `UpdateKeys.fromInfoPlist` does.
    public static func fromInfoPlist(_ value: Any?) -> [String: Data] {
        UpdateKeys.fromInfoPlist(value)
    }
}

/// Checking a document of rights, step by step in the contract's order (§7.4). Nothing of the
/// payload is read before its signature checks with a key this app carries.
public enum EntitlementVerifier {
    /// `document`: the envelope's JSON as it came or as it was stored. `deviceID`: this Mac's device
    /// in the license, as the activation answered it. `machineID`: computed now (`MachineID`), never
    /// a stored one — a document copied to another Mac does not fit that Mac.
    public static func check(_ document: Data, keys: [String: Data], deviceID: String, machineID: String) -> EntitlementCheck {
        // 1. A JSON object with a whole-number `format`.
        guard let declared = try? JSONDecoder().decode(FormatField.self, from: document) else { return .notADocument }
        // 2. A newer format is not judged.
        guard declared.format <= EntitlementEnvelope.currentFormat else { return .newerFormat }
        // 3. The fields of this format: an id, a payload that is not empty, both in base64.
        guard declared.format == EntitlementEnvelope.currentFormat,
              let fields = try? JSONDecoder().decode(EnvelopeFields.self, from: document),
              !fields.payload.isEmpty, let payload = Data(base64Encoded: fields.payload), !payload.isEmpty,
              let signature = Data(base64Encoded: fields.signature) else { return .notADocument }
        // 4. A key this app carries.
        guard let raw = keys[fields.keyID] else { return .unknownKey }
        // 5. The signature over the payload's bytes.
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: payload) else { return .badSignature }
        // 6. A document of rights, of a version this app reads. A payload that is not a JSON object
        //    has no kind at all.
        guard let fieldsOfPayload = try? JSONDecoder().decode(PayloadFields.self, from: payload),
              fieldsOfPayload.kind == "lumen.entitlement" else { return .wrongKind }
        if let version = fieldsOfPayload.version, version > 1 { return .newerVersion }
        // 7. This device, on this Mac.
        guard let documentDevice = fieldsOfPayload.deviceID, documentDevice.lowercased() == deviceID.lowercased(),
              let documentMachine = fieldsOfPayload.machineID, documentMachine.lowercased() == machineID.lowercased() else {
            return .wrongDevice
        }
        // 8. Everything decided by, readable.
        guard let entitlement = fieldsOfPayload.entitlement(deviceID: documentDevice, machineID: documentMachine) else {
            return .malformed
        }
        return .valid(entitlement)
    }

    /// Checks an envelope already decoded (`AccountRecord.entitlement`).
    public static func check(_ envelope: EntitlementEnvelope, keys: [String: Data], deviceID: String, machineID: String) -> EntitlementCheck {
        guard let document = try? JSONEncoder().encode(envelope) else { return .notADocument }
        return check(document, keys: keys, deviceID: deviceID, machineID: machineID)
    }

    /// The envelope of `document`, once `check` found it valid: what is stored.
    public static func envelope(of document: Data) -> EntitlementEnvelope? {
        guard let fields = try? JSONDecoder().decode(EnvelopeFields.self, from: document),
              let payload = Data(base64Encoded: fields.payload), let signature = Data(base64Encoded: fields.signature) else { return nil }
        return EntitlementEnvelope(format: fields.format, keyID: fields.keyID, payload: payload, signature: signature)
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
        var documentID: String?
        var accountID: String?
        var licenseID: String?
        var deviceID: String?
        var machineID: String?
        var role: String?
        var plan: String?
        var status: String?
        var exportReason: String?
        var limits: LimitsFields?
        var profilesOnOtherDevices: Int?
        var periodEndsAt: String?
        var periodEndsAtIsNull = false
        var issuedAt: String?
        var refreshAfter: String?
        var expiresAt: String?
        var graceEndsAt: String?

        struct LimitsFields: Decodable {
            var profiles: Int?
            var devices: Int?
            var seats: Int?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                profiles = try? container.decode(Int.self, forKey: Key("profiles"))
                devices = try? container.decode(Int.self, forKey: Key("devices"))
                seats = try? container.decode(Int.self, forKey: Key("seats"))
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            func string(_ name: String) -> String? { try? container.decode(String.self, forKey: Key(name)) }
            kind = string("kind")
            version = try? container.decode(Int.self, forKey: Key("version"))
            documentID = string("documentID")
            accountID = string("accountID")
            licenseID = string("licenseID")
            deviceID = string("deviceID")
            machineID = string("machineID")
            role = string("role")
            plan = string("plan")
            status = string("status")
            exportReason = string("exportReason")
            limits = try? container.decode(LimitsFields.self, forKey: Key("limits"))
            profilesOnOtherDevices = try? container.decode(Int.self, forKey: Key("profilesOnOtherDevices"))
            periodEndsAt = string("periodEndsAt")
            periodEndsAtIsNull = (try? container.decodeNil(forKey: Key("periodEndsAt"))) ?? true
            issuedAt = string("issuedAt")
            refreshAfter = string("refreshAfter")
            expiresAt = string("expiresAt")
            graceEndsAt = string("graceEndsAt")
        }

        func entitlement(deviceID: String, machineID: String) -> Entitlement? {
            guard let statusText = status, let status = Entitlement.Status(rawValue: statusText),
                  let role, let plan,
                  let profiles = limits?.profiles, let devices = limits?.devices, let seats = limits?.seats,
                  let profilesOnOtherDevices,
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
            return Entitlement(documentID: documentID ?? "", accountID: accountID ?? "", licenseID: licenseID ?? "",
                               deviceID: deviceID, machineID: machineID, role: role, plan: plan, status: status,
                               exportReason: status == .exportOnly ? (exportReason ?? "period_ended") : nil,
                               limits: Entitlement.Limits(profiles: profiles, devices: devices, seats: seats),
                               profilesOnOtherDevices: profilesOnOtherDevices, periodEndsAt: periodEndsAt, issuedAt: issuedAt,
                               refreshAfter: refreshAfter, expiresAt: expiresAt, graceEndsAt: graceEndsAt)
        }

        /// RFC 3339 in UTC, `Z`, no fractions of a second (§2) — anything else is unreadable. The
        /// form is checked here, character by character: what a parser takes besides differs by
        /// platform (macOS's took "2026-11-01T10:00:00.500Z", CI run 578; Linux's did not).
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

/// This Mac's id for the server (§4.1): computed from the hardware UUID, which is never sent.
///
/// `machineID = lowercase_hex(SHA-256(UTF-8("lumen.machine-id.v1\n" + uppercase(IOPlatformUUID))))`
public enum MachineID {
    public static func compute(platformUUID: String) -> String {
        let text = "lumen.machine-id.v1\n" + platformUUID.uppercased()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
