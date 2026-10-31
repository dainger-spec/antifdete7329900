import Foundation
import ObjectiveC
import os

/// What Safari's chrome saves as its preferences, kept in the profile's own home and sealed into the
/// vault with the rest of Safari's state of the profile: one domain, as Safari has one, for both
/// ways Safari's code reaches it.
///
///   * The standard defaults: its window's frame, its toolbar, sidebar and favorites bar, the start
///     page's sections, some WebKit preferences, the dates of its own updates. They went to this
///     app's own domain in the account's real home — one file for every profile and the manager,
///     outside the vault (the menu walk: 53 keys on macOS 26 and 56 on 27, CI run 496).
///   * Safari's own defaults, `+[NSUserDefaults safari_browserDefaults]` (SafariCore), which outside
///     Safari's process answers with a domain named by the real Safari's container plist: the search
///     provider's keys, the start page's sections, Reader's last use, the Browsing Assistant's
///     consent and some more (run 496). The profile's sandbox refuses those writes (run 504) and stays
///     the first defense; until this, none of it was kept.
///
/// Both are a domain named by a path in the profile's home, `<home>/Library/PrivacyBrowser/
/// SafariDefaults`, which cfprefsd keeps in the file at that path. Not under the home's
/// `Library/Preferences`: a domain named by a path there is the account's own domain of that name
/// (runs 496 and 503, macOS 26 and 27). Every profile starts once from Safari's own defaults for
/// these (the owner's decision).
///
/// The file is what the domain holds. As the process starts, the domain is made what the file
/// restored with the home says, or empty without one: cfprefsd keeps a domain in memory after its
/// file is gone, and an ephemeral profile's next run, or a run on a home restored from an older
/// archive, would otherwise start from what an earlier run left. As the process exits, the domain is
/// written to the file: cfprefsd writes it a moment after a change (run 488), and the manager seals
/// the home as soon as the process has exited. Measured with a key left to cfprefsd as the process
/// exits: nothing was in the home 5, 10 and 30 seconds after its seal (runs 508 and 510).
///
/// Not covered, on macOS 26: AppKit saves the toolbar's configuration through an
/// `NSObservableDefaults` of its own, made for this app's domain before any of this runs — one key,
/// `NSToolbar Configuration BrowserStandaloneTabBarToolbarIdentifier-v3.1`, goes there (run 510; on
/// macOS 27 nothing does).
enum SafariDefaults {
    private static var defaults: UserDefaults?
    /// The domain, by its path; nil until `keepInProfileHome`.
    private(set) static var domain: String?
    /// The keys the file held as the process started: what Safari's chrome saved in the profile's
    /// earlier runs, restored with its home.
    private(set) static var savedKeys: [String] = []
    /// Safari's own accessor for its defaults, in SafariCore.
    static let browserDefaultsSelector = "safari_browserDefaults"
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariDefaults")

    /// The domain of the profile whose home is `home`, by its path.
    static func domain(inHome home: String) -> String {
        home + "/Library/PrivacyBrowser/SafariDefaults"
    }

    /// The profile's domain, once `keepInProfileHome` made it.
    static var profileDefaults: UserDefaults? { defaults }

    /// In a profile's process, before Safari's frameworks load and before the application exists:
    /// from here on the standard defaults are the profile's own.
    static func keepInProfileHome(_ home: String) {
        guard defaults == nil else { return }
        let path = domain(inHome: home)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard let profileDefaults = UserDefaults(suiteName: path),
              let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) else {
            log.error("Safari's preferences stay in this app's own domain: the profile's domain could not be made")
            return
        }
        let saved = NSDictionary(contentsOfFile: path + ".plist") as? [String: Any] ?? [:]
        if !NSDictionary(dictionary: profileDefaults.persistentDomain(forName: path) ?? [:]).isEqual(to: saved) {
            profileDefaults.setPersistentDomain(saved, forName: path)
        }
        savedKeys = saved.keys.sorted()
        let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in profileDefaults }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        defaults = profileDefaults
        domain = path
        atexit { SafariDefaults.writeOut() }
    }

    /// Right after Safari's frameworks load, before any of Safari's application exists: Safari's
    /// own defaults are the profile's domain too. Without the accessor (another Safari), Safari's code
    /// keeps naming the real Safari's container, and the sandbox keeps refusing it.
    static func keepSafarisOwnInProfileHome() {
        guard let profileDefaults = defaults else { return }
        guard let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString(browserDefaultsSelector)) else {
            log.notice("No +[NSUserDefaults safari_browserDefaults] in this Safari: what Safari's code saves there stays refused")
            return
        }
        let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in profileDefaults }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Whether Safari's own defaults are the profile's domain (for the process's report).
    static var safarisOwnAreProfiles: Bool {
        guard let defaults, class_getClassMethod(UserDefaults.self, NSSelectorFromString(browserDefaultsSelector)) != nil else { return false }
        return (UserDefaults.self as AnyObject).perform(NSSelectorFromString(browserDefaultsSelector))?.takeUnretainedValue() === defaults
    }

    /// The domain written to its file as the process exits: after the application's own end, when
    /// Safari's chrome has saved what it saves as it quits, and before the manager seals the home.
    private static func writeOut() {
        guard let defaults, let domain else { return }
        defaults.synchronize()
        let values = defaults.persistentDomain(forName: domain) ?? [:]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: domain + ".plist"), options: .atomic)
        } catch {
            log.error("Safari's preferences could not be written before the seal: \(error.logKind, privacy: .public)")
        }
    }
}
