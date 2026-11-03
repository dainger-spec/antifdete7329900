import BrowserCore
import Foundation

/// The license's texts as the server's `docs/CONTRACT.md` §17 writes them — word for word, in the
/// interface's language, under the contract's keys (`contract.…` in the localization) — with its
/// substitutions (§17.1): dates in the Mac's time zone, durations in days, hours or minutes with
/// the words' right forms, numbers of profiles. Durations and limits come from the server's answers
/// and the document, never from numbers written here.
enum LicenseText {
    // MARK: §17.1

    /// `<дата>`: the long date and the short time.
    static func date(_ date: Date) -> String {
        date.shown(date: .long, time: .shortened)
    }

    /// `<когда>`: "today at 09:12", "yesterday at …", else `<дата>`.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.shown(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(format: L("license.when.today"), time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: L("license.when.yesterday"), time)
        }
        return self.date(date)
    }

    /// `<время>`: the time alone, for what ends within the hour (a sign-in's code, §5.2).
    static func time(_ date: Date) -> String {
        date.shown(date: .omitted, time: .shortened)
    }

    /// `<срок до …>`: from now until `date`, its seconds rounded up to a minute (§17.1).
    static func durationUntil(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        return duration(TimeInterval(minutes * 60))
    }

    /// `<дата кратко>`: "29 November"; with the year when it is not this one.
    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Localization.locale
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "d MMMM" : "d MMM y") // l10n: not text
        return formatter.string(from: date)
    }

    /// `<когда кратко>`: "today", "yesterday", else `<дата кратко>`.
    static func shortWhen(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return L("license.shortWhen.today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L("license.shortWhen.yesterday")
        }
        return shortDate(date, now: now)
    }

    /// `<срок>`: in days when it divides by a day, else in hours when it divides by an hour, else in
    /// minutes rounded up.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        if whole > 0, whole % 86_400 == 0 { return count(whole / 86_400, "day") }
        if whole > 0, whole % 3_600 == 0 { return count(whole / 3_600, "hour") }
        return count(Int((Double(whole) / 60).rounded(.up)), "minute")
    }

    /// What is left until a moment (`Countdown`): "6 дней 23 часа", "5 hours 12 minutes" — not
    /// `<срок>`, which is for lengths the server configures.
    static func remaining(_ seconds: TimeInterval) -> String {
        Countdown.parts(seconds).map { count($0.value, $0.unit.rawValue) }.joined(separator: " ")
    }

    /// A number and its noun in the right form: `day`, `hour`, `minute`, `profile`, `time`.
    static func count(_ number: Int, _ noun: String) -> String {
        String(format: L("license.unit.\(noun).\(form(number))"), number)
    }

    /// Russian: 1, 21, 31… (but 11) — one; 2–4, 22–24… (but 12–14) — few; the rest — many.
    /// English: 1 — one, else many.
    static func form(_ number: Int) -> String {
        guard Localization.languageCode == "ru" else { return number == 1 ? "one" : "many" }
        let tens = number % 100, units = number % 10
        if units == 1 && tens != 11 { return "one" }
        if (2...4).contains(units) && !(12...14).contains(tens) { return "few" }
        return "many"
    }

    /// `<тариф>`: the plan's name; an unknown plan as it came (§13).
    static func plan(_ plan: String) -> String {
        switch plan {
        case "trial", "personal", "pro", "team": return L("license.plan.\(plan)")
        default: return plan
        }
    }

    // MARK: §17.4 — banners

    /// The banner's text, word for word. `ownerEmail`: the team's owner (`GET /v1/account`), when
    /// known. `withoutEmail`: an account bought without registration — the warning of the period's
    /// end adds that no letter will come.
    static func banner(_ banner: LicenseBanner, ownerEmail: String? = nil, withoutEmail: Bool = false) -> String {
        switch banner {
        case .deviceRevoked: return L("contract.device.revoked")
        case .machineMismatch: return L("contract.device.machine_mismatch")
        case .notSignedIn: return L("contract.mode.not_signed_in")
        case .accountDisabled: return L("contract.error.account_disabled")
        case let .periodEnded(owner, endedAt):
            let when = endedAt.map(date) ?? "—"
            if owner { return String(format: L("contract.export.period_ended"), when) }
            if let ownerEmail { return String(format: L("contract.export.period_ended.member"), when, ownerEmail) }
            return String(format: L("contract.export.period_ended.member.noEmail"), when)
        case .noLicense: return L("contract.export.no_license")
        case let .grace(outdated, lastSuccessAt, until):
            return String(format: L(outdated ? "contract.mode.grace.outdated" : "contract.mode.grace.unreachable"),
                          lastSuccessAt.map(date) ?? "—", date(until))
        case let .expired(outdated, lastSuccessAt):
            return String(format: L(outdated ? "contract.mode.expired.outdated" : "contract.mode.expired.unreachable"),
                          lastSuccessAt.map(date) ?? "—")
        case .unverified: return L("contract.mode.unverified")
        case .appOutdated: return L("contract.app.outdated")
        case let .clockSkew(seconds): return String(format: L("contract.clock.skew"), duration(seconds))
        case let .periodEnding(owner, endsAt, _):
            let text = String(format: L(owner ? "contract.period.ending" : "contract.period.ending.member"), date(endsAt))
            return withoutEmail ? text + " " + L("license.periodEnding.noEmail") : text
        case let .trialStarted(until): return String(format: L("contract.trial.started"), date(until))
        case let .renewalFailing(since, reason, status, until):
            return String(format: L("license.renewal.failing"), date(since), renewalFailure(reason, status: status), date(until))
        }
    }

    /// Why the renewals fail, in a few words: no answer, the server's error, an answer not taken.
    static func renewalFailure(_ reason: LicenseClient.RefreshFailure.Reason, status: Int?) -> String {
        switch reason {
        case .noAnswer: return L("license.renewal.reason.noAnswer")
        case .server: return String(format: L("license.renewal.reason.server"), status.map(String.init) ?? "?")
        case .unusableAnswer: return L("license.renewal.reason.unusable")
        }
    }

    // MARK: §17.4 — the sidebar's line

    /// The line about the rights at the foot of the sidebar: title and caption, short dates.
    static func sidebar(_ state: LicenseState, record: AccountRecord, now: Date = Date()) -> (title: String, caption: String) {
        switch state.mode {
        case .notSignedIn:
            return (L("contract.sidebar.notSignedIn.title"), L("contract.sidebar.notSignedIn.caption"))
        case .grace:
            let until = state.entitlement.map { shortDate(LicenseDecision.graceDate($0), now: now) } ?? "—"
            return (L(record.appOutdated ? "contract.sidebar.grace.outdated.title" : "contract.sidebar.grace.title"),
                    String(format: L("contract.sidebar.grace.caption"), until))
        case .exportOnly:
            let reason = state.entitlement.flatMap { LicenseBanners.exportReason($0, at: state.now) }
            // A document that would let this Mac work, its grace over: the connection's (or the
            // app's age) is the title, export only the caption.
            if state.entitlement != nil, reason == nil {
                return (L(record.appOutdated ? "contract.sidebar.grace.outdated.title" : "contract.sidebar.grace.title"),
                        L("contract.sidebar.export.title"))
            }
            let caption: String
            switch reason {
            case "no_license"?: caption = L("contract.sidebar.export.noLicense")
            case "account_disabled"?: caption = L("contract.sidebar.export.accountDisabled")
            case nil: caption = L("contract.sidebar.export.notChecked")
            default: caption = L("contract.sidebar.export.periodEnded")
            }
            return (L("contract.sidebar.export.title"), caption)
        case .full:
            guard let p = state.entitlement else { return (L("contract.sidebar.export.title"), L("contract.sidebar.export.notChecked")) }
            let end = p.periodEndsAt.map { shortDate($0, now: now) } ?? "—"
            if p.plan == "trial" {
                return (L("contract.sidebar.trial.title"), String(format: L("contract.sidebar.trial.caption"), end, count(p.limits.profiles, "profile")))
            }
            let checked = record.lastSuccessAt.map { shortWhen($0, now: now) } ?? "—"
            return (String(format: L("contract.sidebar.full.title"), plan(p.plan), end), String(format: L("contract.sidebar.full.caption"), checked))
        }
    }

    // MARK: §17.4 — the profile limit

    static func limitProfiles(_ p: Entitlement) -> String {
        String(format: L(p.isOwner ? "contract.limit.profiles" : "contract.limit.profiles.member"),
               plan(p.plan), count(p.limits.profiles, "profile"), "\(p.profilesOnOtherDevices)", "\(LicenseDecision.allowedProfilesHere(p))")
    }

    // MARK: §17.3 — a sign-in's code (§5.2)

    /// `login.code_terms`: when the letter went out, until when its code works, how many times it may
    /// still be typed — all from the server's answer (an older server's: counted from when it came).
    static func loginCodeTerms(_ code: LoginCode, now: Date = Date()) -> String {
        String(format: L("contract.login.code_terms"), code.codeSentAt.map { when($0, now: now) } ?? "—",
               code.codeExpiresAt.map(time) ?? "—", code.codeAttempts.map { count($0, "time") } ?? "—")
    }

    /// What is said about sending the code again, now: when it can be (`login.resend_wait`), that it
    /// cannot any more (`login.resends_used`), or nothing — it can be now, or this server has no resend.
    static func loginResendNote(_ code: LoginCode, now: Date = Date()) -> String? {
        if code.resendsUsed { return String(format: L("contract.login.resends_used"), code.codeExpiresAt.map(time) ?? "—") }
        if code.canResend, let at = code.resendAvailableAt, at > now { return String(format: L("contract.login.resend_wait"), durationUntil(at, now: now)) }
        return nil
    }

    // MARK: §17.5 — signing out

    /// `signout.consequences`, with the license's unlink cooldown when the server said it (§6.1,
    /// §6.2); without one — a server older than v2026.11.04, whose sign-out has none — the text as the
    /// contract had it then.
    static func signOutConsequences(cooldownSeconds: Int?) -> String {
        guard let cooldownSeconds, cooldownSeconds > 0 else { return L("contract.signout.consequences.withoutCooldown") }
        return String(format: L("contract.signout.consequences"), duration(TimeInterval(cooldownSeconds)))
    }

    // MARK: §17.2 — errors

    /// What a failed request says (§3, §17.2, §17.7), by its code — never by the server's message.
    /// `withKey`: the request carried the license's key (`account_deletion_pending` then has its own text).
    /// `passwordOnly`: a form where no email is typed (a key replaced with the account's password):
    /// `invalid_credentials` is then the password's alone.
    static func error(_ failure: AccountFailure, withKey: Bool = false, passwordOnly: Bool = false) -> String {
        switch failure {
        case .unreachable:
            return L("contract.error.unreachable")
        case .document(let check):
            return check.meansAppOutdated ? L("contract.app.outdated") : L("contract.error.unreachable")
        case .server(let error):
            switch error.code {
            case "rate_limited": return String(format: L("contract.error.rate_limited"), duration(TimeInterval(error.retryAfter ?? 60)))
            case "invalid_email": return L("contract.error.invalid_email")
            case "invalid_password": return L("contract.error.invalid_password")
            case "invalid_credentials":
                return L(passwordOnly ? "contract.error.invalid_credentials.password" : "contract.error.invalid_credentials")
            case "robot_check": return L("contract.error.robot_check")
            case "robot_check_unavailable":
                return String(format: L("contract.error.robot_check_unavailable"), duration(TimeInterval(error.retryAfter ?? 60)))
            case "server_busy": return String(format: L("contract.error.server_busy"), duration(TimeInterval(error.retryAfter ?? 60)))
            case "login_expired": return L("contract.error.login_expired")
            case "unauthorized": return L("contract.error.unauthorized")
            case "account_disabled": return L("contract.error.account_disabled")
            case "account_deletion_pending":
                return withKey ? L("contract.error.account_deletion_pending.key") : L("contract.error.account_deletion_pending")
            case "invalid_key": return L("contract.key.typo")
            case "key_not_found": return L("contract.key.not_found")
            case "invalid_purchase_code": return L("contract.purchase_code.typo")
            case "invalid_request" where error.field == "purchaseCode": return L("contract.purchase_code.typo")
            case "proof_refused": return L("contract.error.proof_refused")
            case "email_already_linked": return L("contract.error.email_already_linked")
            case "no_key": return L("contract.error.no_key")
            case "invalid_code": return L("contract.error.invalid_code")
            case "letters_busy":
                return String(format: L("contract.error.letters_busy"), duration(TimeInterval(error.retryAfter ?? 60)))
            case "unlink_cooldown":
                return String(format: L("contract.error.unlink_cooldown"), error.availableAt.map(date) ?? "—")
            case "device_limit_reached":
                return L(error.unlinkAvailableAt == nil ? "contract.activation.device_limit" : "contract.activation.device_limit_later")
            default:
                // A 4xx this version does not know: the contract's catch-all; 5xx never reach here.
                return L("contract.error.invalid_request")
            }
        }
    }
}
