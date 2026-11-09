import Foundation

/// Where this iPhone stands with the account server (the server's `docs/CONTRACT.md` §8, `docs/IPHONE.md`).
public enum LicenseMode: String, Equatable, Sendable {
    /// No device token: the free level, by the app's own rule (two profiles, no proxies).
    case notSignedIn
    /// Signed in, and no document that passes the check: the free level until the server answers.
    case unverified
    /// The document is in force: its features, its limits.
    case full
    /// The same, with a warning: the document has expired and the server has not answered since.
    case grace
    /// The paid period named in the document ended while the server was silent.
    case periodEnded
    /// The server has been silent past the document's last day.
    case unreachable
}

/// The decision: what the iPhone may do (`Access`, the one place rights come from) and why.
public struct LicenseState: Equatable, Sendable {
    public var mode: LicenseMode
    public var access: Access

    public init(mode: LicenseMode, access: Access) {
        self.mode = mode
        self.access = access
    }
}

/// The decision of §8.2 as an iPhone makes it (the owner and the lead, 9 November): the rights are the
/// document's `features` and `limits`, never the plan's name or the status — the server writes the
/// free level into the document itself (plan "none" or export-only: features ["browse"], two
/// profiles). The app's own rule is used only where there is no document to read: not signed in, a
/// document that does not pass the check, one that ran out with the server silent.
public enum License {
    /// `signedIn`: a device token is stored. `entitlement`: the stored document once it passed every
    /// check, nil when there is none or it did not pass. `t`: the effective time (`EffectiveClock`).
    public static func state(signedIn: Bool, entitlement: Entitlement?, at t: Date) -> LicenseState {
        guard signedIn else { return LicenseState(mode: .notSignedIn, access: .free) }
        guard let p = entitlement else {
            return LicenseState(mode: .unverified, access: ownFree(plan: "unverified",
                reason: "Права на этом iPhone не удаётся проверить. Прокси недоступны, пока сервер Lumen не ответит."))
        }
        // The planted fault: a document is in force for ever.
        if !Faults.isActive(.documentNeverExpires) {
            guard t < p.graceEndsAt else {
                return LicenseState(mode: .unreachable, access: ownFree(plan: "unreachable",
                    reason: "Lumen давно не получал ответа сервера. Прокси недоступны, пока сервер Lumen не ответит."))
            }
            if p.status == .active {
                // A paid (or trial) period that ended with the server silent: what it opened is over.
                guard let end = p.periodEndsAt, t < end else { return LicenseState(mode: .periodEnded, access: .expired) }
            }
        }
        var browse = p.features.contains(Entitlement.browse)
        var proxies = p.features.contains(Entitlement.proxies)
        var profiles = p.allowedProfilesHere
        if Faults.isActive(.featuresFromPlan) {   // the planted fault: the plan's name decides, not its features
            browse = true
            proxies = p.status == .active
        }
        if Faults.isActive(.freeLimitOwnRule), p.status == .exportOnly {   // the planted fault: the app's own count
            profiles = Access.freeProfiles
        }
        let access = Access(plan: planName(p), proxies: proxies, maxProfiles: profiles,
                            reason: reason(p, browse: browse, proxies: proxies), browse: browse)
        return LicenseState(mode: t < p.expiresAt ? .full : .grace, access: access)
    }

    /// The free level by the app's own rule, under another name and reason.
    static func ownFree(plan: String, reason: String) -> Access {
        var access = Access.free
        access.plan = plan
        access.reason = reason
        return access
    }

    /// The plan as the plan's screen names it (`Access.planTitle`).
    static func planName(_ p: Entitlement) -> String {
        guard p.status == .exportOnly else { return p.plan }
        switch p.exportReason {
        case "no_license": return "free"
        case "account_disabled": return "disabled"
        default: return "expired"
        }
    }

    /// Why something is closed, in the person's words; nil when nothing is.
    static func reason(_ p: Entitlement, browse: Bool, proxies: Bool) -> String? {
        if browse && proxies { return nil }
        if p.status == .exportOnly {
            switch p.exportReason {
            case "no_license": return browse ? "Прокси доступны на платных тарифах." : "Выберите тариф, чтобы работать с профилями."
            case "account_disabled": return "Аккаунт заблокирован, напишите в поддержку."
            default: return browse ? "Оплаченный период закончился. Прокси недоступны." : "Оплаченный период закончился."
            }
        }
        return browse ? "В вашем тарифе нет прокси." : "В вашем тарифе сайты на iPhone не открываются."
    }

    /// The profiles that stay open when there are more than the plan allows: the first ones by when
    /// they were made here — the oldest first, the same moment broken by the profile's id (§8.4).
    /// The rest are locked; none is deleted. `allowed` nil: no limit.
    public static func withinLimit(_ sessions: [Session], allowed: Int?) -> Set<UUID> {
        guard let allowed, !Faults.isActive(.overLimitOpens) else { return Set(sessions.map(\.id)) }
        let ordered = sessions.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id.uuidString.lowercased() < b.id.uuidString.lowercased()
        }
        return Set(ordered.prefix(max(0, allowed)).map(\.id))
    }
}

/// The time the decision is made at (§8.3): this iPhone's clock, never earlier than a floor that only
/// moves forward. Setting the clock back does not bring time back.
public struct EffectiveClock: Codable, Equatable, Sendable {
    public var floorTime: Date
    public var floorUptime: TimeInterval

    public init(floorTime: Date, floorUptime: TimeInterval) {
        self.floorTime = floorTime
        self.floorUptime = floorUptime
    }

    /// The effective time now, `wall` being this iPhone's clock and `uptime` its uptime; the floor
    /// moves to it. An uptime below the floor's: the iPhone was restarted — the floor stays.
    public mutating func now(wall: Date, uptime: TimeInterval) -> Date {
        if Faults.isActive(.clockRollbackTrusted) { return wall }   // the planted fault: the bare clock
        let advanced = uptime >= floorUptime ? floorTime.addingTimeInterval(uptime - floorUptime) : floorTime
        let t = max(wall, advanced)
        floorTime = t
        floorUptime = uptime
        return t
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

    /// While the app runs: when the document asks for it, or when there is none to read.
    public static func refreshDue(entitlement: Entitlement?, at t: Date) -> Bool {
        guard let p = entitlement else { return true }
        return t >= p.refreshAfter
    }
}

/// What the app keeps about this iPhone's place in a license (§4.2) — in the Keychain, as one item.
public struct AccountRecord: Codable, Equatable, Sendable {
    public var format: Int
    /// The address the person signed in with: shown on the plan's screen, sent nowhere.
    public var email: String
    public var deviceID: String
    /// Four characters for the person: the same code the site's cabinet shows for this iPhone.
    public var code: String
    public var deviceToken: String
    /// The last accepted envelope, as it came.
    public var entitlement: Data?
    public var clock: EffectiveClock
    /// The server's time at the last successful answer.
    public var lastSuccessAt: Date?
    /// The last refresh brought a document this app cannot judge (§9.4): the person is asked to update.
    public var appOutdated: Bool

    public init(email: String, deviceID: String, code: String, deviceToken: String, entitlement: Data?,
                clock: EffectiveClock, lastSuccessAt: Date?, appOutdated: Bool = false) {
        self.format = 1
        self.email = email
        self.deviceID = deviceID
        self.code = code
        self.deviceToken = deviceToken
        self.entitlement = entitlement
        self.clock = clock
        self.lastSuccessAt = lastSuccessAt
        self.appOutdated = appOutdated
    }
}

/// What goes to the account server and what comes back, as bytes (§2, §3, §5, §6).
public enum AccountWire {
    /// The body of an activation (§6.1) and of a refresh (§6.2): an iPhone says it is one
    /// (`platform: "ios"`, `docs/IPHONE.md` §2.1) — it takes no Mac's place in the license.
    public static func deviceBody(machineID: String, profileCount: Int, appVersion: String) -> Data {
        var body: [String: Any] = ["machineID": machineID, "profileCount": profileCount, "appVersion": appVersion]
        // The planted fault: the platform left out — the server would count this iPhone as a Mac.
        if !Faults.isActive(.activationWithoutPlatform) { body["platform"] = "ios" }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// The body of a sign-in (§5.2).
    public static func loginBody(email: String, password: String, robotToken: String?) -> Data {
        var body: [String: Any] = ["email": email, "password": password]
        if let robotToken, !robotToken.isEmpty { body["robotToken"] = robotToken }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// A refusal as the server words it (§3): `{"error": {"code": …, …}}`. Nil: not the server's
    /// answer at all (a captive portal's page, a cut body) — "unreachable" (§9.3).
    public struct Refusal: Equatable, Sendable {
        public var code: String
        public var retryAfter: Int?
        /// With a refusal for the license's limit of phones: how many it allows, when the server says.
        public var phones: Int?

        public init(code: String, retryAfter: Int? = nil, phones: Int? = nil) {
            self.code = code
            self.retryAfter = retryAfter
            self.phones = phones
        }
    }

    public static func refusal(_ data: Data) -> Refusal? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any], let code = error["code"] as? String, !code.isEmpty else { return nil }
        let limits = error["limits"] as? [String: Any]
        let phones = (error["phones"] as? Int) ?? (limits?["phones"] as? Int) ?? (error["devices"] as? [Any]).flatMap { $0.isEmpty ? nil : $0.count }
        return Refusal(code: code, retryAfter: error["retryAfter"] as? Int, phones: phones)
    }

    /// Time as the server writes it (§2): RFC 3339, UTC, no fractions of a second.
    public static func time(_ text: String?) -> Date? {
        guard let text, text.utf8.count == 20, text.hasSuffix("Z") else { return nil }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}

/// The server's states in the person's words (§17 — shown as written there, "Mac" read as "iPhone").
public enum AccountText {
    /// "Unreachable" at sign-in and activation.
    public static let unreachable = "Сервер Lumen не отвечает. Проверьте соединение и попробуйте ещё раз."
    public static let revoked = "Этот iPhone отключён от аккаунта. Войдите снова."
    public static let machineMismatch = "Похоже, данные Lumen перенесены с другого iPhone. Войдите, чтобы подключить этот."
    public static let outdated = "Обновите Lumen."
    public static let checkEmail = "У этого аккаунта было много неудачных попыток входа, поэтому мы отправили код на его почту. Введите код из письма."
    public static let codeResent = "Отправили код ещё раз — тот же, что в прошлом письме."
    public static let robotCheck = "Подтвердите, что вы не робот, и отправьте ещё раз."

    /// A refusal's text by its code; an unknown code is "something went wrong" and goes to the log.
    public static func refusal(_ refusal: AccountWire.Refusal) -> String {
        let wait = refusal.retryAfter.map { " Повторите через \(duration($0))." } ?? ""
        switch refusal.code {
        case "invalid_credentials": return "Неверная почта или пароль."
        case "unauthorized": return "Сессия закончилась. Войдите снова."
        case "account_disabled": return "Аккаунт заблокирован, напишите в поддержку."
        case "account_deletion_pending": return "Аккаунт удаляется. Отменить удаление можно на сайте."
        case "robot_check": return robotCheck
        case "robot_check_unavailable": return "Проверка «не робот» сейчас недоступна." + wait
        case "server_busy": return "Сервер Lumen сейчас очень занят." + wait
        case "rate_limited": return "Слишком много попыток." + wait
        case "invalid_code": return "Код неверный или устарел."
        case "login_expired": return "Эта попытка входа закончилась. Введите пароль ещё раз."
        case "resend_limit": return "Код в этой попытке больше не отправить. Письма нет — проверьте «Спам»."
        case "device_limit_reached", "phone_limit_reached":
            // The planted fault: the refusal shown without its reason.
            if Faults.isActive(.phoneLimitUnexplained) { return "Что-то пошло не так." }
            let count = refusal.phones.map { " (\($0))" } ?? ""
            return "К этой лицензии уже подключено наибольшее число iPhone\(count). Отключите один из них в кабинете на сайте и войдите снова."
        default: return "Что-то пошло не так."
        }
    }

    /// "45 секунд", "2 минуты", "1 час" — a wait the server named, rounded up to whole units.
    public static func duration(_ seconds: Int) -> String {
        let seconds = max(1, seconds)
        if seconds < 60 { return "\(seconds) " + plural(seconds, "секунду", "секунды", "секунд") }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes) " + plural(minutes, "минуту", "минуты", "минут") }
        let hours = (minutes + 59) / 60
        return "\(hours) " + plural(hours, "час", "часа", "часов")
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = n % 100, ones = n % 10
        if tens >= 11 && tens <= 14 { return many }
        if ones == 1 { return one }
        if ones >= 2 && ones <= 4 { return few }
        return many
    }
}
