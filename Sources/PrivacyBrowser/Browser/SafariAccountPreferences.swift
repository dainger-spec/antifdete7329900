import BrowserCore
import CoreFoundation
import Foundation
import os

/// What earlier versions left in the account's ~/Library/Preferences/com.apple.Safari.plist, taken
/// out once.
///
/// From 0adc270 to dbea98c, a profile's process wrote the settings it gives Safari's own services
/// (`SafariChrome.servicePreferenceValues`) to `com.apple.Safari`, and cfprefsd kept them in that
/// file of the account's, the last profile's values winning (menu walk, CI run 457). The real Safari
/// does not read it: it keeps its settings in its container, and neither its launches nor its first
/// launch on a Mac where it had never run take anything from that file (CI run 488, measurement
/// branch claude/measure-safari-prefs, macOS 26 and 27; on the owner's Mac its AutoFill is on, the
/// file saying off). The keys are ours all the same. The one process seen reading the file is
/// AppKit's open and save panel service, for the panels' own settings, so the file itself stays:
/// once, after the vault's first unlock in a version with this, each of those keys that still holds
/// a value a profile of this vault would have written is taken out; one that holds another value
/// (changed since, by whoever) is left, as is every other key. The log says which went and which
/// stayed.
enum SafariAccountPreferences {
    /// What a key was given: the same for every profile, or after the profile's own settings.
    enum Written {
        case always(Bool)
        /// The profile's Safe Browsing setting.
        case safeBrowsing
        /// On for a profile without a proxy.
        case withoutProxy

        func value(for profile: ProfileConfiguration) -> Bool {
            switch self {
            case .always(let value): return value
            case .safeBrowsing: return profile.safeBrowsingEnabled
            case .withoutProxy: return profile.proxy == nil
            }
        }

        /// What it was given for some profile of `profiles`.
        func values(for profiles: [ProfileConfiguration]) -> Set<Bool> {
            if case .always(let value) = self { return [value] }
            return Set(profiles.map(value(for:)))
        }
    }

    /// The keys those versions wrote and what each was given, as they were then — not to follow
    /// `servicePreferenceValues`, where a key added later was never written to the file.
    static let written: [(key: String, value: Written)] = [
        ("AutoFillPasswords", .always(false)),
        ("AutoFillCreditCardData", .always(false)),
        ("AutoFillMiscellaneousForms", .always(false)),
        ("AutoFillFromAddressBook", .always(false)),
        ("UniversalSearchEnabled", .always(false)),
        ("SuppressSearchSuggestions", .always(true)),
        ("WarnAboutFraudulentWebsites", .safeBrowsing),
        ("WebKitPreferences.privateClickMeasurementEnabled", .withoutProxy),
        ("WebKitDNSPrefetchingEnabled", .withoutProxy),
        ("WebKitPreferences.dnsPrefetchingEnabled", .withoutProxy),
        ("WebsiteSpecificSearchEnabled", .always(false)),
        ("PreloadTopHit", .always(false)),
        ("CanPromptForPushNotifications", .always(false)),
        ("ExtensionsEnabled", .always(false)),
        ("AutoOpenSafeDownloads", .always(false)),
    ]

    struct Outcome: Equatable {
        /// Taken out: each held a value a profile of this vault would have written.
        var removed: [String] = []
        /// Left: each held another value.
        var left: [String] = []
    }

    /// This app's own defaults say it was done (the cleanup's version).
    static let doneKey = "SafariAccountPreferencesCleaned"
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariAccountPreferences")

    /// Once per account, after the vault is unlocked, with every profile's settings (read only
    /// then): outside the App Sandbox only — those versions' profiles ran there, and from inside it
    /// the account's file is out of reach. Nil when it had been done.
    @discardableResult
    static func removeOnce(from domain: String = "com.apple.Safari", defaults: UserDefaults = .standard,
                           profiles: () -> [ProfileConfiguration]) -> Outcome? {
        guard !AppEnvironment.isSandboxed, defaults.integer(forKey: doneKey) < 1 else { return nil }
        let outcome = remove(from: domain, profiles: profiles())
        defaults.set(1, forKey: doneKey)
        if outcome.removed.isEmpty, outcome.left.isEmpty {
            log.notice("The account's \(domain, privacy: .public) holds none of the keys earlier versions wrote")
        } else {
            let removed = outcome.removed.isEmpty ? "none" : outcome.removed.joined(separator: ", ")
            let left = outcome.left.isEmpty ? "none" : outcome.left.joined(separator: ", ")
            log.notice("Taken out of the account's \(domain, privacy: .public), as earlier versions wrote them: \(removed, privacy: .public); left, holding another value: \(left, privacy: .public)")
        }
        return outcome
    }

    /// Takes the keys out of `domain` — the user's, any host: for a process outside the App Sandbox,
    /// the file in ~/Library/Preferences — where each holds a value one of `profiles` would have
    /// written. A key that is not there is neither.
    static func remove(from domain: String = "com.apple.Safari", profiles: [ProfileConfiguration]) -> Outcome {
        let app = domain as CFString
        var outcome = Outcome()
        for (key, rule) in written {
            guard let value = CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                continue
            }
            // Written as a boolean: a number or anything else is someone else's.
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(),
               rule.values(for: profiles).contains(number.boolValue) {
                CFPreferencesSetValue(key as CFString, nil, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                outcome.removed.append(key)
            } else {
                outcome.left.append(key)
            }
        }
        if !outcome.removed.isEmpty {
            CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        return outcome
    }
}
