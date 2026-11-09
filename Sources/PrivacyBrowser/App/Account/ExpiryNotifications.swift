import AppKit
import BrowserCore
import os
import UserNotifications

/// The subscription's reminders through the system's notifications, for an account signed in with a
/// key alone — no email, so no letter can say the period is ending (the owner, 2 November).
///
/// Offered once by itself (`ExpiryReminders.shouldOffer`): right after a key connected this Mac, or
/// when the first warning before the period's end appears. The app's own line comes first — why it
/// asks at all — and only "Remind me" leads to the system's question. Whatever the answer, the
/// offer is not made again by itself; nothing else changes when it is refused, and the banner warns
/// as before. Settings › Account offers it again. The reminders come a week and a day before the
/// period's end (`ExpiryReminders.reminders`), set again whenever that end moves.
@MainActor
enum ExpiryNotifications {
    /// The offer was made on this Mac (not a secret: whether a question was asked).
    static let offeredKey = "PBExpiryRemindersOffered"
    private static let identifiers = ExpiryReminders.Reminder.Kind.allIdentifiers
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "Reminders")
    /// The period's end the pending reminders were set for: set again only when it moves. The first
    /// time in a process they are set again whatever it is (reminders an earlier run left).
    private static var scheduledFor: Date?
    private static var reconciled = false
    /// A bare executable (`swift run`) has no bundle for the system's notifications to belong to,
    /// and the notification center refuses it.
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var offered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    enum Status: Equatable {
        /// The system's question was never answered.
        case notAsked
        case allowed
        /// Turned off in System Settings, or "Don't Allow" at the system's question.
        case refused
    }

    static func status() async -> Status {
        guard available else { return .refused }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notAsked
        case .denied: return .refused
        default: return .allowed
        }
    }

    private static func isKeyAccount(_ license: LicenseModel) -> Bool {
        license.record.isSignedIn && license.record.signedInWith == .key
    }

    /// At `moment`: the offer when it is due, and the reminders kept to the period's end.
    static func update(at moment: ExpiryReminders.Moment, license: LicenseModel) {
        let periodEnding = license.state?.banners.contains { banner in
            if case .periodEnding = banner { return true }
            return false
        } ?? false
        // An email linked to the purchase (§11.1): letters remind of the period's end, the offer — "we have
        // no other way to remind you" — would not be true.
        if ExpiryReminders.shouldOffer(at: moment, signedInWithKey: isKeyAccount(license) && license.hasNoEmail, alreadyOffered: offered,
                                       periodEnding: periodEnding) {
            offered = true
            Task { await offer(license: license) }
        } else {
            Task { await reschedule(license: license) }
        }
    }

    /// The app's line, then — asked for — the system's question.
    private static func offer(license: LicenseModel) async {
        guard await status() == .notAsked else {
            await reschedule(license: license)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("reminders.offer.title")
        alert.informativeText = L("reminders.offer.why")
        alert.addButton(withTitle: L("reminders.offer.allow"))
        alert.addButton(withTitle: L("reminders.offer.notNow"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            log.notice("Subscription reminders: not wanted")
            return
        }
        await ask(license: license)
    }

    /// Settings › Account's "Turn On": the row says why already; the system's question.
    static func turnOnFromSettings(license: LicenseModel) async {
        offered = true
        await ask(license: license)
    }

    private static func ask(license: LicenseModel) async {
        guard available else { return }
        if (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true {
            log.notice("Subscription reminders: allowed")
        } else {
            log.notice("Subscription reminders: refused at the system's question")
        }
        reconciled = false
        await reschedule(license: license)
    }

    /// The pending reminders as the license now says: a week and a day before its period's end,
    /// for a key account that allowed them; none otherwise (signed out, an email account, no period).
    static func reschedule(license: LicenseModel) async {
        let end = isKeyAccount(license) ? license.state?.entitlement?.periodEndsAt : nil
        guard available, !reconciled || end != scheduledFor else { return }
        reconciled = true
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        scheduledFor = nil
        guard let end, await status() == .allowed else { return }
        for reminder in ExpiryReminders.reminders(periodEndsAt: end, now: Date()) {
            let content = UNMutableNotificationContent()
            content.title = reminder.kind == .week ? L("reminders.week.title") : L("reminders.day.title")
            content.body = String(format: L("reminders.body"), LicenseText.date(reminder.periodEndsAt))
            content.sound = .default
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.at)
            let request = UNNotificationRequest(identifier: reminder.kind.identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
            do {
                try await center.add(request)
            } catch {
                log.error("A subscription reminder could not be set: \(error.logKind, privacy: .public)")
            }
        }
        scheduledFor = end
    }
}

extension ExpiryReminders.Reminder.Kind {
    /// The system's identifier of this reminder: a new one replaces the old.
    var identifier: String { "io.lumenbrowser.reminder." + rawValue }
    static var allIdentifiers: [String] { [Self.week.identifier, Self.day.identifier] }
}
