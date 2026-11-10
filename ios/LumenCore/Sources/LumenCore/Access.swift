import Foundation

/// What this iPhone may do: the one place the app's rights come from (the owner, 8 November). It does
/// not care where a paid plan came from — the web site today, Apple's in-app purchase if plan B
/// comes — and nothing else in the app decides a right. The account server's signed document of
/// rights fills it (`License.state`); without an account it is the free level (`free`). A DEBUG build
/// may take it from a test instead (LUMEN_TEST_ACCESS).
public struct Access: Equatable, Sendable {
    /// The plan, as the account server names it — "trial", "personal", "pro", "team" — or the app's
    /// own name for where it stands: "free" (no account, or an account without a plan), "expired" (a
    /// paid period that ended), "disabled", "unverified", "unreachable"; "full" is the tests' own.
    public var plan: String
    /// Whether profiles may open sites at all (the document's "browse").
    public var browse: Bool
    /// Whether sessions may go through proxies (the document's "proxies").
    public var proxies: Bool
    /// How many profiles this iPhone may keep; nil: no limit of its own (a paid plan's count, shared
    /// with the Mac, comes with the server).
    public var maxProfiles: Int?
    /// Why something is closed, in the person's words — shown on a locked profile and in its settings.
    public var reason: String?

    public init(plan: String = "full", proxies: Bool, maxProfiles: Int? = nil, reason: String? = nil, browse: Bool = true) {
        self.plan = plan
        self.browse = browse
        self.proxies = proxies
        self.maxProfiles = maxProfiles
        self.reason = reason
    }

    #if DEBUG
    /// Everything: what a DEBUG build has unless a test asks otherwise (LUMEN_TEST_ACCESS). A release
    /// build has no such value at all — there the rights come from the account, or are the free
    /// level (the lead, 10 November); ios/scripts/release_rules.py checks the built release too.
    public static let full = Access(proxies: true)
    #endif

    /// Profiles on the free plan.
    public static let freeProfiles = 2

    /// The free level by the app's own rule — an iPhone that is not signed in (the owner, 8 and
    /// 9 November): two profiles, no proxies — each with the whole of its isolation and its full
    /// device profile, as on any plan. Signed in, the same comes from the server's document.
    public static var free: Access {
        // The planted fault: the free plan's proxies left on.
        Access(plan: "free", proxies: Faults.isActive(.freePlanProxies), maxProfiles: freeProfiles,
               reason: "Прокси доступны на платных тарифах.")
    }

    /// A paid period that ended: the free level's limits. Its profiles that lived behind a proxy stay
    /// locked (SessionLock), their data kept.
    public static let expired = Access(plan: "expired", proxies: false, maxProfiles: freeProfiles,
                                       reason: "Оплаченный период закончился. Прокси недоступны.")

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
        case "expired": return "Оплаченный период закончился"
        case "disabled": return "Аккаунт заблокирован"
        case "unverified": return "Права не проверены"
        case "unreachable": return "Нет ответа сервера Lumen"
        case "trial": return "7 дней бесплатно"
        case "personal": return "Личный"
        case "pro": return "Профессиональный"
        case "team": return "Команда"
        case "full": return "Все возможности (проверочная сборка)"
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
/// from the device's own address — and keeps its data. A session that never had a proxy is open —
/// unless the rights open no sites at all, or it is one profile more than the plan allows
/// (`License.withinLimit`): locked too, its data kept.
public enum SessionLock: Equatable, Sendable {
    case open
    case locked(reason: String)

    public static func of(_ session: Session, proxyExists: Bool, access: Access, overLimit: Bool = false) -> SessionLock {
        if !access.browse { return .locked(reason: access.reason ?? "Сайты сейчас не открываются.") }
        if overLimit {
            let limit = access.maxProfiles.map { " (\($0))" } ?? ""
            return .locked(reason: "Профиль сверх числа профилей тарифа\(limit). Он и его данные сохранены.")
        }
        // The planted fault: a locked profile opens as one without a proxy — directly.
        if Faults.isActive(.lockedOpensDirect) { return .open }
        guard session.boundToProxy else { return .open }
        if !access.proxies { return .locked(reason: access.reason ?? "Прокси сейчас недоступны.") }
        if session.proxyID == nil || !proxyExists { return .locked(reason: "Прокси этого профиля больше нет в списке.") }
        return .open
    }

    public var isLocked: Bool { self != .open }
}
