import Foundation

/// What this iPhone may do: the one place the app's rights come from (the owner, 8 November). It does
/// not care where a subscription came from — the web site today, Apple's in-app purchase if plan B
/// comes — and nothing else in the app decides a right. The account server's signed document of
/// rights will fill it; until then a DEBUG build takes it from the tests (LUMEN_TEST_ACCESS), and
/// everything is allowed otherwise (`full`).
public struct Access: Equatable, Sendable {
    /// The plan, as the account server names it: "free" (no account or no plan), "expired" (a paid
    /// plan that ended), the Mac's "trial", "personal", "pro", "team" — or "full" before the server.
    public var plan: String
    /// Whether sessions may go through proxies.
    public var proxies: Bool
    /// How many profiles this iPhone may keep; nil: no limit of its own (a paid plan's count, shared
    /// with the Mac, comes with the server).
    public var maxProfiles: Int?
    /// Why proxies are not there, in the person's words — shown on a locked profile and in its settings.
    public var reason: String?

    public init(plan: String = "full", proxies: Bool, maxProfiles: Int? = nil, reason: String? = nil) {
        self.plan = plan
        self.proxies = proxies
        self.maxProfiles = maxProfiles
        self.reason = reason
    }

    /// Before the account server: everything.
    public static let full = Access(proxies: true)

    /// Profiles on the free plan.
    public static let freeProfiles = 2

    /// The free plan (the owner, 8 November): two profiles, no proxies — each with the whole of its
    /// isolation and its full device profile, as on any plan.
    public static var free: Access {
        // The planted fault: the free plan's proxies left on.
        Access(plan: "free", proxies: Faults.isActive(.freePlanProxies), maxProfiles: freeProfiles,
               reason: "Прокси доступны на платных тарифах.")
    }

    /// A paid plan that ended: the free plan's limits. Its profiles that lived behind a proxy stay
    /// locked (SessionLock), their data kept.
    public static let expired = Access(plan: "expired", proxies: false, maxProfiles: freeProfiles,
                                       reason: "Доступ к прокси закончился.")

    /// Whether one more profile may be made where `count` are.
    public func mayCreateProfile(having count: Int) -> Bool {
        if Faults.isActive(.profileLimitIgnored) { return true }   // the planted fault: no count kept
        guard let maxProfiles else { return true }
        return count < maxProfiles
    }

    /// The plan's name, as the person reads it (the Mac's names for the paid ones).
    public var planTitle: String {
        switch plan {
        case "free": return "Бесплатный"
        case "expired": return "Подписка закончилась"
        case "trial": return "7 дней бесплатно"
        case "personal": return "Личный"
        case "pro": return "Профессиональный"
        case "team": return "Команда"
        case "full": return "Все возможности (до входа в аккаунт)"
        default: return plan
        }
    }

    /// "Профили: 2 из 2", or "Профили: 5" with no limit.
    public func profileCounter(_ count: Int) -> String {
        maxProfiles.map { "Профили: \(count) из \($0)" } ?? "Профили: \(count)"
    }
}

/// Whether a session may open now. One that has lived behind a proxy opens only through a proxy it
/// may use: with access lost, its proxy deleted or none set, it stays locked — no page, no request
/// from the device's own address — and keeps its data. A session that never had a proxy is open.
public enum SessionLock: Equatable, Sendable {
    case open
    case locked(reason: String)

    public static func of(_ session: Session, proxyExists: Bool, access: Access) -> SessionLock {
        // The planted fault: a locked profile opens as one without a proxy — directly.
        if Faults.isActive(.lockedOpensDirect) { return .open }
        guard session.boundToProxy else { return .open }
        if !access.proxies { return .locked(reason: access.reason ?? "Прокси сейчас недоступны.") }
        if session.proxyID == nil || !proxyExists { return .locked(reason: "Прокси этого профиля больше нет в списке.") }
        return .open
    }

    public var isLocked: Bool { self != .open }
}
