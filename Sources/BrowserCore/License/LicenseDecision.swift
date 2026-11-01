import Foundation

/// What this Mac may do now (the server's `docs/CONTRACT.md` §8.1), decided here from the signed
/// document and this Mac's own time — never by asking the server (§1).
public enum LicenseMode: String, Equatable, Sendable {
    /// Everything the plan allows.
    case full
    /// The same, with a warning: the document has expired and the server has not answered since;
    /// work goes on until the GRACE date (`LicenseDecision.graceDate`).
    case grace
    /// Profiles open only to take their data out; nothing is deleted.
    case exportOnly = "export_only"
    /// No device token: as export-only, with "sign in" and "create an account" beside it.
    case notSignedIn = "not_signed_in"

    /// Profiles open fully and new ones may be made.
    public var allowsWork: Bool { self == .full || self == .grace }
}

/// The decision of §8.2, the profile limit of §8.4 and the dates the texts need.
public enum LicenseDecision {
    /// §8.2, in its order. `signedIn`: a device token is stored. `entitlement`: the stored document
    /// once it passed every check (`EntitlementCheck.valid`), nil when there is none or it did not
    /// pass. `t`: the effective time (`EffectiveClock`), never the bare clock.
    public static func mode(signedIn: Bool, entitlement: Entitlement?, at t: Date) -> LicenseMode {
        guard signedIn else { return .notSignedIn }
        guard let p = entitlement else { return .exportOnly }
        guard p.status == .active else { return .exportOnly }
        guard let periodEnd = p.periodEndsAt, t < periodEnd else { return .exportOnly }
        if t < p.expiresAt { return .full }
        if t < p.graceEndsAt { return .grace }
        return .exportOnly
    }

    /// How many profiles this Mac may use fully: the license's limit less what its other Macs
    /// reported, never below 0 (§8.4).
    public static func allowedProfilesHere(_ p: Entitlement) -> Int {
        max(0, p.limits.profiles - p.profilesOnOtherDevices)
    }

    /// The profiles of this Mac that open fully when there are more than `allowed`: the first ones by
    /// when they were made here — the oldest first, the same moment broken by the profile's id
    /// (§8.4). The rest open for export only; none is deleted.
    public static func fullyOpen(_ profiles: [(id: UUID, createdAt: Date)], allowed: Int) -> Set<UUID> {
        let ordered = profiles.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id.uuidString.lowercased() < b.id.uuidString.lowercased()
        }
        return Set(ordered.prefix(max(0, allowed)).map(\.id))
    }

    /// Whether a new profile may be made here: a working mode and room under the limit (§8.4).
    public static func canCreateProfile(mode: LicenseMode, entitlement: Entitlement?, profilesHere: Int) -> Bool {
        guard mode.allowsWork, let p = entitlement else { return false }
        return profilesHere < allowedProfilesHere(p)
    }

    /// The date GRACE ends: the earlier of `graceEndsAt` and the period's end — with the period's
    /// end, the mode becomes export-only before `graceEndsAt` (§8.1).
    public static func graceDate(_ p: Entitlement) -> Date {
        guard let periodEnd = p.periodEndsAt else { return p.graceEndsAt }
        return min(p.graceEndsAt, periodEnd)
    }

    /// Until when this Mac works as it does now without hearing from the server: the end of FULL
    /// and GRACE together — the GRACE date. Nil when it does not work now (export-only, not signed
    /// in). What "how much offline grace is left" is measured to (the owner, 1 November).
    public static func worksWithoutServerUntil(mode: LicenseMode, entitlement: Entitlement?) -> Date? {
        guard mode.allowsWork, let p = entitlement else { return nil }
        return graceDate(p)
    }
}

/// The time the decision is made at (§8.3): this Mac's clock, never earlier than a floor that only
/// moves forward. Setting the clock back does not bring time back; time spent with the app running
/// counts even with the clock set back.
///
/// Stored: `floorTime` (UTC) and `floorUptime` (`ProcessInfo.systemUptime` at that moment).
public struct EffectiveClock: Codable, Equatable, Sendable {
    public var floorTime: Date
    public var floorUptime: TimeInterval

    public init(floorTime: Date, floorUptime: TimeInterval) {
        self.floorTime = floorTime
        self.floorUptime = floorUptime
    }

    /// After a successful activation or refresh with the server's time `serverTime` (§8.3).
    public static func reset(serverTime: Date, uptime: TimeInterval) -> EffectiveClock {
        EffectiveClock(floorTime: serverTime, floorUptime: uptime)
    }

    /// The effective time now, `wall` being this Mac's clock and `uptime` its uptime; the floor moves
    /// to it. An uptime below the floor's: the Mac was restarted — the floor stays where it was.
    public mutating func now(wall: Date, uptime: TimeInterval) -> Date {
        let advanced = uptime >= floorUptime ? floorTime.addingTimeInterval(uptime - floorUptime) : floorTime
        let t = max(wall, advanced)
        floorTime = t
        floorUptime = uptime
        return t
    }

    /// The difference between this Mac's clock and the server's, when it is more than ten minutes
    /// (`clock.skew`, §8.3, §17.4); nil otherwise.
    public static func skew(wall: Date, serverTime: Date) -> TimeInterval? {
        let difference = abs(wall.timeIntervalSince(serverTime))
        return difference > 10 * 60 ? difference : nil
    }
}

/// When to ask the server for a fresh document (§9.1).
public enum RefreshSchedule {
    /// After "unreachable": 1, 5, 15, 30, 60 minutes, then every hour while the app runs.
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        let steps: [TimeInterval] = [60, 5 * 60, 15 * 60, 30 * 60, 60 * 60]
        guard failures > 0 else { return 0 }
        return steps[min(failures - 1, steps.count - 1)]
    }

    /// At launch: when the document asks for it, or the mode is not FULL.
    public static func refreshAtLaunch(mode: LicenseMode, entitlement: Entitlement?, at t: Date) -> Bool {
        guard mode != .notSignedIn else { return false }
        guard mode == .full, let p = entitlement else { return true }
        return t >= p.refreshAfter
    }

    /// Every 15 minutes, after the network came back and after a wake: when the document asks for it.
    public static func refreshDue(entitlement: Entitlement?, at t: Date) -> Bool {
        guard let p = entitlement else { return true }
        return t >= p.refreshAfter
    }

    /// When the app becomes active: if the mode is not FULL or the period ends within three days —
    /// at most once a minute (the caller keeps the minute).
    public static func refreshWhenActive(mode: LicenseMode, entitlement: Entitlement?, at t: Date) -> Bool {
        guard mode != .notSignedIn else { return false }
        guard mode == .full, let p = entitlement, let end = p.periodEndsAt else { return true }
        return end.timeIntervalSince(t) < 3 * 86_400
    }
}

/// How much is left until a moment, as a person reads it: the two largest units, rounded down —
/// "6 days 23 hours", "5 hours 12 minutes" — and never less than a minute. The contract's `<срок>`
/// names lengths the server configures, which divide evenly (§17.1: a document's 7 days); a
/// countdown seldom does, and in that form the account page said "10020 minutes" (CI run 586's
/// snapshot).
public enum Countdown {
    public enum Unit: String, Sendable { case day, hour, minute }

    public static func parts(_ seconds: TimeInterval) -> [(unit: Unit, value: Int)] {
        let total = max(60, Int(seconds.isFinite ? seconds.rounded(.down) : 60))
        let days = total / 86_400, hours = total % 86_400 / 3_600, minutes = total % 3_600 / 60
        if days > 0 { return hours > 0 ? [(.day, days), (.hour, hours)] : [(.day, days)] }
        if hours > 0 { return minutes > 0 ? [(.hour, hours), (.minute, minutes)] : [(.hour, hours)] }
        return [(.minute, max(1, minutes))]
    }
}
