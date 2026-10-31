import Foundation
import ObjectiveC
import os

/// What Safari's chrome saves through the standard defaults — its window's frame, its toolbar,
/// sidebar and favorites bar, the start page's sections, some WebKit preferences, the dates of its
/// own updates — kept in the profile's own home, sealed into the vault with the rest of Safari's
/// state of the profile. Until this it went to this app's own domain in the account's real home:
/// one file for every profile and the manager, outside the vault (the menu walk: 53 keys on macOS
/// 26 and 56 on 27, CI run 496). Every profile starts once from Safari's own defaults for them
/// (the owner's decision).
///
/// The standard defaults of a profile's process are made a domain named by a path in its home,
/// before Safari's frameworks load: `<home>/Library/PrivacyBrowser/SafariUIState`, which cfprefsd
/// keeps in the file at that path. Not under the home's `Library/Preferences`: a domain named by a
/// path there is the account's own domain of that name (runs 496 and 503, macOS 26 and 27).
///
/// The file is what the domain holds. As the process starts, the domain is made what the file
/// restored with the home says, or empty without one: cfprefsd keeps a domain in memory after its
/// file is gone, and an ephemeral profile's next run, or a run on a home restored from an older
/// archive, would otherwise start from what an earlier run left there. As the process exits, the
/// domain is written to the file: cfprefsd writes it a moment after a change (run 488), and the
/// manager seals the home as soon as the process has exited.
enum SafariUIState {
    private static var defaults: UserDefaults?
    /// The domain, by its path; nil until `keepInProfileHome`.
    private(set) static var domain: String?
    /// The keys the file held as the process started: what Safari's chrome saved in the profile's
    /// earlier runs, restored with its home.
    private(set) static var savedKeys: [String] = []
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariUIState")

    /// The domain of the profile whose home is `home`, by its path.
    static func domain(inHome home: String) -> String {
        home + "/Library/PrivacyBrowser/SafariUIState"
    }

    /// In a profile's process, before Safari's frameworks load and before the application exists:
    /// from here on the standard defaults are the profile's own.
    static func keepInProfileHome(_ home: String) {
        guard defaults == nil else { return }
        let path = domain(inHome: home)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard let profileDefaults = UserDefaults(suiteName: path),
              let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) else {
            log.error("Safari's window state stays in this app's own domain: the profile's domain could not be made")
            return
        }
        let saved = NSDictionary(contentsOfFile: path + ".plist") as? [String: Any] ?? [:]
        let original = UserDefaults.standard
        let cached = profileDefaults.persistentDomain(forName: path)?.count ?? 0
        if !NSDictionary(dictionary: profileDefaults.persistentDomain(forName: path) ?? [:]).isEqual(to: saved) {
            profileDefaults.setPersistentDomain(saved, forName: path)
        }
        savedKeys = saved.keys.sorted()
        let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in profileDefaults }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        defaults = profileDefaults
        domain = path
        atexit { SafariUIState.writeOut() }
        SafariUIStateMeasure.started(path: path, suite: profileDefaults, original: original, cached: cached, saved: saved.count)
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
            log.error("Safari's window state could not be written before the seal: \(error.logKind, privacy: .public)")
        }
        SafariUIStateMeasure.lateWrite(defaults)
    }
}
