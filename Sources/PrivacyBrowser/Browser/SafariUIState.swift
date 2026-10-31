import Foundation
import ObjectiveC
import os

/// What Safari's chrome keeps through the standard defaults — its window's frame, its toolbar,
/// sidebar and favorites bar, the start page's sections, some WebKit preferences — kept in the
/// profile's own home, where the rest of its Safari state is: `<home>/Library/Preferences/<bundle
/// id>.plist`, a domain named by its path, which cfprefsd keeps at that path, and which is sealed
/// into the vault with the home when the profile stops. Until this, they went to this app's own
/// domain in the account's real home: one file for every profile and the manager, outside the
/// vault (the menu walk: 52 to 58 keys a walk, runs 456 and 468). Every profile starts once from
/// Safari's own defaults for them (the owner's decision).
enum SafariUIState {
    private static var defaults: UserDefaults?
    private static var domain: String?
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariUIState")

    /// In a profile's process, before Safari's frameworks load and before the application exists:
    /// from here on the standard defaults are the profile's own.
    static func keepInProfileHome(_ home: String) {
        guard defaults == nil, let bundleID = Bundle.main.bundleIdentifier else { return }
        let folder = home + "/Library/Preferences"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + bundleID
        let selector = NSSelectorFromString("standardUserDefaults")
        guard let profileDefaults = UserDefaults(suiteName: path),
              let method = class_getClassMethod(UserDefaults.self, selector) else {
            log.error("The standard defaults could not be the profile's: Safari's window state goes to the app's own domain")
            return
        }
        let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in profileDefaults }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        defaults = profileDefaults
        domain = path
        log.notice("Safari's window state is kept in the profile's home")
    }

    /// As the profile's process quits, once its windows are gone and before its home is sealed: the
    /// domain written to its file here and now. cfprefsd writes its files a moment later, by when
    /// the manager may be sealing the home (CI run 488 read a domain's file just after a
    /// synchronize: the change was not in it yet).
    static func saveBeforeSealing() {
        guard let defaults, let domain else { return }
        defaults.synchronize()
        guard let values = defaults.persistentDomain(forName: domain), !values.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: domain + ".plist"), options: .atomic)
        } catch {
            log.error("Safari's window state could not be written before the seal: \(error.logKind, privacy: .public)")
        }
    }
}
