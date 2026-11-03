import Foundation

/// A token the server gave — the device's (`lmd_…`) or a session's (`lms_…`). Written to its file as
/// it is; never says itself anywhere else: interpolated, printed, dumped or mirrored it shows its
/// prefix and "…" (as `AccountKey` does), so that no log line, error or report can carry it.
public struct ServerToken: Codable, Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// For the `Authorization` header only.
    public func unredacted() -> String { value }

    public var isEmpty: Bool { value.isEmpty }
    public var description: String { value.hasPrefix("lm") && value.count > 4 ? String(value.prefix(4)) + "…" : "…" }
    public var debugDescription: String { "ServerToken(\(description))" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// This Mac's account state (`account.json`, the server's `docs/CONTRACT.md` §4.2): beside the vault,
/// outside it — the rights are checked before the vault is unlocked — and outside every profile;
/// owner-only (0600), read and written only by the app's own process, never a profile's.
///
/// Never in it: the account's password, a license key (an account without an email keeps its key in
/// the vault, `AccountKeyVault`), anything of a profile.
public struct AccountRecord: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public struct Session: Codable, Equatable, Sendable {
        public var sessionToken: ServerToken?
        public var expiresAt: Date?
        public var idleTimeoutSeconds: Int?

        public init(sessionToken: ServerToken?, expiresAt: Date?, idleTimeoutSeconds: Int?) {
            self.sessionToken = sessionToken
            self.expiresAt = expiresAt
            self.idleTimeoutSeconds = idleTimeoutSeconds
        }
    }

    /// How this Mac was signed in — what the account screen offers depends on it (a password reset
    /// by email, or a key that has none). Not the server's: the app's own note.
    public enum SignInMethod: String, Codable, Equatable, Sendable {
        case email
        case key
    }

    public var format: Int
    public var deviceID: String?
    /// The device's four characters (`B119`), the same the account's page on the site shows.
    public var code: String?
    public var deviceToken: ServerToken?
    /// The last document accepted, as it came (§7.1).
    public var entitlement: EntitlementEnvelope?
    /// The effective time's floor (§8.3).
    public var floorTime: Date?
    public var floorUptime: TimeInterval?
    /// The server's time at the last successful contact (§4.2): for GRACE's text.
    public var lastSuccessAt: Date?
    /// The last refresh got a document this app cannot judge (§9.4); any accepted one clears it.
    public var appOutdated: Bool
    public var session: Session?
    /// Only for a Mac connected with a key: an email is linked to the purchase (`emailLinked` of the
    /// last `POST /v1/anonymous/license`, §4.2, §11.1) — it chooses the account screen's text and
    /// "Lost your key?"'s while the server is out of reach. Not a secret.
    public var emailLinked: Bool?

    // The app's own notes, beside the contract's fields.

    public var signedInWith: SignInMethod?
    /// Why this Mac was signed out by the server (§9.4), for the banner, until the next sign-in.
    public var signedOutReason: SignedOutReason?
    /// The clock's difference from the server's at the last contact, when over ten minutes (§8.3).
    public var clockSkewSeconds: Double?
    /// The license whose trial banner the person closed (`trial.started`, §8.5).
    public var trialNoticeClosedFor: String?
    /// False: the person chose "don't remember the key" when signing in with it (§10.1) — the vault
    /// keeps no copy, one kept before is removed at the next unlock, and the key is asked for each
    /// time it is needed. Absent: the key is remembered (the contract's default). Not a secret.
    public var rememberKey: Bool?

    /// The license's unlink cooldown, as the last activation or refresh said it (§6.1, §6.2): for
    /// `signout.consequences`. Nil from a server older than v2026.11.04, whose sign-out has none.
    public var unlinkCooldownSeconds: Int?
    /// The period-end warning the person closed (`period.ending`, §8.5 item 10).
    public var periodEndingClosed: PeriodEndingClosed?
    /// The label this Mac was connected with (what the field held: this Mac's name to begin with),
    /// sent again with each renewal. Nil for a Mac connected before 3 November: this Mac's name is
    /// sent then (the owner: "по умолчанию подставляй имя Mac из системы"). Not a secret.
    public var label: String?
    /// How many profiles this Mac had when the vault was last open: what a renewal says before the
    /// vault is opened again (the number is known only inside it). A number, nothing of a profile.
    public var profileCount: Int?
    /// The renewals that failed since the last one that brought a document: since when, the last
    /// one, and why (the owner, 3 November: a failure is said, never silence). Nil after a renewal
    /// that brought one.
    public var renewalFailure: RenewalFailure?

    public struct RenewalFailure: Codable, Equatable, Sendable {
        public var since: Date
        public var lastAt: Date
        public var reason: LicenseClient.RefreshFailure.Reason
        /// The server's HTTP status, when it answered with an error.
        public var status: Int?

        public init(since: Date, lastAt: Date, reason: LicenseClient.RefreshFailure.Reason, status: Int?) {
            self.since = since
            self.lastAt = lastAt
            self.reason = reason
            self.status = status
        }
    }

    /// The key is kept in the vault (§10.1): the default, unless the person chose otherwise.
    public var keepsKey: Bool { rememberKey != false }

    /// Which `period.ending` was closed: for which end of the period, at which of its two warnings —
    /// the week before, or the last day (§8.5 item 10). Closed during the week, it comes back for the
    /// last day; closed on the last day, not again before the next end. A renewal moves the end, and
    /// with it the count starts anew.
    public struct PeriodEndingClosed: Codable, Equatable, Sendable {
        public var endsAt: Date
        /// The last day's warning.
        public var final: Bool

        public init(endsAt: Date, final: Bool) {
            self.endsAt = endsAt
            self.final = final
        }

        /// This closing hides the warning for `endsAt` at its `final` level.
        public func hides(endsAt end: Date, final isFinal: Bool) -> Bool {
            endsAt == end && (final || !isFinal)
        }
    }

    public init() {
        format = Self.currentFormat
        appOutdated = false
    }

    enum CodingKeys: String, CodingKey {
        case format, deviceID, code, deviceToken, entitlement, floorTime, floorUptime, lastSuccessAt, appOutdated, session, emailLinked
        case signedInWith, signedOutReason, clockSkewSeconds, trialNoticeClosedFor, rememberKey, unlinkCooldownSeconds, periodEndingClosed
        case label, profileCount, renewalFailure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? 1
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        deviceToken = try container.decodeIfPresent(ServerToken.self, forKey: .deviceToken)
        entitlement = try container.decodeIfPresent(EntitlementEnvelope.self, forKey: .entitlement)
        floorTime = try container.decodeIfPresent(Date.self, forKey: .floorTime)
        floorUptime = try container.decodeIfPresent(TimeInterval.self, forKey: .floorUptime)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        appOutdated = try container.decodeIfPresent(Bool.self, forKey: .appOutdated) ?? false
        session = try container.decodeIfPresent(Session.self, forKey: .session)
        signedInWith = try container.decodeIfPresent(SignInMethod.self, forKey: .signedInWith)
        signedOutReason = try container.decodeIfPresent(SignedOutReason.self, forKey: .signedOutReason)
        clockSkewSeconds = try container.decodeIfPresent(Double.self, forKey: .clockSkewSeconds)
        trialNoticeClosedFor = try container.decodeIfPresent(String.self, forKey: .trialNoticeClosedFor)
        emailLinked = try container.decodeIfPresent(Bool.self, forKey: .emailLinked)
        rememberKey = try container.decodeIfPresent(Bool.self, forKey: .rememberKey)
        // Notes of their own: one that does not read is left out, not the whole file.
        unlinkCooldownSeconds = try? container.decodeIfPresent(Int.self, forKey: .unlinkCooldownSeconds)
        periodEndingClosed = try? container.decodeIfPresent(PeriodEndingClosed.self, forKey: .periodEndingClosed)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        profileCount = try? container.decodeIfPresent(Int.self, forKey: .profileCount)
        renewalFailure = try? container.decodeIfPresent(RenewalFailure.self, forKey: .renewalFailure)
    }

    /// A device token is stored: this Mac is signed in (§8.2).
    public var isSignedIn: Bool { deviceToken.map { !$0.isEmpty } ?? false }

    /// The effective time's floor, when one is stored.
    public var clock: EffectiveClock? {
        get {
            guard let floorTime, let floorUptime else { return nil }
            return EffectiveClock(floorTime: floorTime, floorUptime: floorUptime)
        }
        set {
            floorTime = newValue?.floorTime
            floorUptime = newValue?.floorUptime
        }
    }

    /// Signed out: the device's token and document go (§6.3, §9.4); what the profiles hold is
    /// never touched (§1). The session goes with them; the reason stays for the banner. Signed out by
    /// the server, whether an email is linked to the purchase stays too: "Lost your key?" says by it
    /// how to get back in (§11.1) — after a key replaced elsewhere, this is when it is asked.
    public mutating func signOut(because reason: SignedOutReason?) {
        deviceID = nil
        code = nil
        deviceToken = nil
        entitlement = nil
        session = nil
        appOutdated = false
        signedInWith = nil
        clockSkewSeconds = nil
        signedOutReason = reason
        rememberKey = nil
        label = nil
        renewalFailure = nil
        if reason == nil { emailLinked = nil }
    }
}

/// `account.json`: read before the vault is unlocked, written atomically and owner-only. A file of a
/// newer format is refused and never written over; one that does not read is moved aside
/// (`account.json.unreadable`) — never deleted, never written over (docs/DESTRUCTIVE_PATHS.md).
public struct AccountFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `account.json` in `directory` (the vault's folder).
    public init(directory: URL) {
        url = directory.appendingPathComponent("account.json")
    }

    /// The record, or nil when there is no file.
    public func load() throws -> AccountRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try SecureFile.read(url)
        try DocumentFormat.check(data, supported: AccountRecord.currentFormat, what: "account.json")
        do {
            return try JSONCoding.decoder.decode(AccountRecord.self, from: data)
        } catch {
            throw CoreError.corruptData("account.json")
        }
    }

    public func save(_ record: AccountRecord) throws {
        try makeWay()
        try SecureFile.write(JSONCoding.encoder.encode(record), to: url)
    }

    /// Before a write: a newer version's file refuses it; one that does not read is moved aside.
    /// Returns where it went, when it was moved.
    @discardableResult
    public func makeWay() throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? SecureFile.read(url) else { return try SecureFile.moveAside(url, suffix: "unreadable") }
        try DocumentFormat.check(data, supported: AccountRecord.currentFormat, what: "account.json")
        if (try? JSONCoding.decoder.decode(AccountRecord.self, from: data)) == nil {
            return try SecureFile.moveAside(url, suffix: "unreadable")
        }
        return nil
    }
}
