import Foundation

/// What this iPhone may do: the one place the app's rights come from (the owner, 8 November). It does
/// not care where a subscription came from — the web site today, Apple's in-app purchase if plan B
/// comes — and nothing else in the app decides a right. The next step fills it from the account
/// server's signed document of rights; until then everything is allowed, and the tests set it
/// (LUMEN_TEST_ACCESS, DEBUG builds).
public struct Access: Equatable, Sendable {
    /// Whether sessions may go through proxies.
    public var proxies: Bool
    /// Why not, in the person's words — shown on a locked profile.
    public var reason: String?

    public init(proxies: Bool, reason: String? = nil) {
        self.proxies = proxies
        self.reason = reason
    }

    public static let full = Access(proxies: true)
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
