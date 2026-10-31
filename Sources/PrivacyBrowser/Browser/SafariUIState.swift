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
///
/// Measurement (run 494: with the standard defaults replaced, nothing reached the profile's home and
/// the keys still went to the app's domain): only with PB_MEASURE_UI_STATE=1, and it says what
/// happened — whether the replacement took, whether a domain named by a path writes to that path,
/// and, for each key written through NSUserDefaults, which instance it went through and from where.
enum SafariUIState {
    private static var defaults: UserDefaults?
    private static var domain: String?
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariUIState")

    /// In a profile's process, before Safari's frameworks load and before the application exists:
    /// from here on the standard defaults are the profile's own.
    static func keepInProfileHome(_ home: String) {
        guard ProcessInfo.processInfo.environment["PB_MEASURE_UI_STATE"] == "1" else { return }
        guard defaults == nil, let bundleID = Bundle.main.bundleIdentifier else { return }
        let folder = home + "/Library/Preferences"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + bundleID
        let selector = NSSelectorFromString("standardUserDefaults")
        let standard = UserDefaults.standard
        guard let profileDefaults = UserDefaults(suiteName: path),
              let method = class_getClassMethod(UserDefaults.self, selector) else {
            NSLog("UISTATE the profile's suite could not be made")
            return
        }
        let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in profileDefaults }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        defaults = profileDefaults
        domain = path
        WriteRecorder.install(standard: standard, suite: profileDefaults)
        NSLog("UISTATE the standard defaults are the profile's suite now: %@; the suite's identifier: %@; the standard's: %@",
              UserDefaults.standard === profileDefaults ? "yes" : "no",
              WriteRecorder.identifier(of: profileDefaults), WriteRecorder.identifier(of: standard))
        // The suite on its own: a canary written through it, looked for in the profile's file and
        // in the account's domain of this app.
        profileDefaults.set("canary", forKey: "PBUIStateCanary")
        profileDefaults.synchronize()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let file = path + ".plist"
            let exists = FileManager.default.fileExists(atPath: file)
            let inFile = (NSDictionary(contentsOfFile: file)?["PBUIStateCanary"]) != nil
            let inAccount = CFPreferencesCopyValue("PBUIStateCanary" as CFString, bundleID as CFString,
                                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost) != nil
            NSLog("UISTATE the canary written through the suite: the profile's file %@, the canary in it %@; in the account's %@ domain %@",
                  exists ? "exists" : "absent", inFile ? "yes" : "no", bundleID, inAccount ? "yes" : "no")
        }
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

/// Measurement: each key written through NSUserDefaults in this process, once per key and instance,
/// with the instance (the profile's suite, the standard defaults as they were, or another) and the
/// frames that wrote it.
private enum WriteRecorder {
    private static let lock = NSLock()
    private static var seen = Set<String>()
    private static var standard: UserDefaults?
    private static var suite: UserDefaults?

    static func install(standard: UserDefaults, suite: UserDefaults) {
        self.standard = standard
        self.suite = suite

        typealias SetObject = @convention(c) (AnyObject, Selector, AnyObject?, NSString) -> Void
        let setObject = NSSelectorFromString("setObject:forKey:")
        if let method = class_getInstanceMethod(UserDefaults.self, setObject) {
            let original = unsafeBitCast(method_getImplementation(method), to: SetObject.self)
            let replacement: @convention(block) (AnyObject, AnyObject?, NSString) -> Void = { this, value, key in
                WriteRecorder.note(this, key as String, "setObject")
                original(this, setObject, value, key)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        typealias SetBool = @convention(c) (AnyObject, Selector, Bool, NSString) -> Void
        let setBool = NSSelectorFromString("setBool:forKey:")
        if let method = class_getInstanceMethod(UserDefaults.self, setBool) {
            let original = unsafeBitCast(method_getImplementation(method), to: SetBool.self)
            let replacement: @convention(block) (AnyObject, Bool, NSString) -> Void = { this, value, key in
                WriteRecorder.note(this, key as String, "setBool")
                original(this, setBool, value, key)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        typealias SetInteger = @convention(c) (AnyObject, Selector, Int, NSString) -> Void
        let setInteger = NSSelectorFromString("setInteger:forKey:")
        if let method = class_getInstanceMethod(UserDefaults.self, setInteger) {
            let original = unsafeBitCast(method_getImplementation(method), to: SetInteger.self)
            let replacement: @convention(block) (AnyObject, Int, NSString) -> Void = { this, value, key in
                WriteRecorder.note(this, key as String, "setInteger")
                original(this, setInteger, value, key)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        typealias SetDouble = @convention(c) (AnyObject, Selector, Double, NSString) -> Void
        let setDouble = NSSelectorFromString("setDouble:forKey:")
        if let method = class_getInstanceMethod(UserDefaults.self, setDouble) {
            let original = unsafeBitCast(method_getImplementation(method), to: SetDouble.self)
            let replacement: @convention(block) (AnyObject, Double, NSString) -> Void = { this, value, key in
                WriteRecorder.note(this, key as String, "setDouble")
                original(this, setDouble, value, key)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        typealias SetFloat = @convention(c) (AnyObject, Selector, Float, NSString) -> Void
        let setFloat = NSSelectorFromString("setFloat:forKey:")
        if let method = class_getInstanceMethod(UserDefaults.self, setFloat) {
            let original = unsafeBitCast(method_getImplementation(method), to: SetFloat.self)
            let replacement: @convention(block) (AnyObject, Float, NSString) -> Void = { this, value, key in
                WriteRecorder.note(this, key as String, "setFloat")
                original(this, setFloat, value, key)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        typealias SetURL = @convention(c) (AnyObject, Selector, AnyObject?, NSString) -> Void
        let setURL = NSSelectorFromString("setURL:forKey:")
        if let method = class_getInstanceMethod(UserDefaults.self, setURL) {
            let original = unsafeBitCast(method_getImplementation(method), to: SetURL.self)
            let replacement: @convention(block) (AnyObject, AnyObject?, NSString) -> Void = { this, value, key in
                WriteRecorder.note(this, key as String, "setURL")
                original(this, setURL, value, key)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        typealias Remove = @convention(c) (AnyObject, Selector, NSString) -> Void
        let remove = NSSelectorFromString("removeObjectForKey:")
        if let method = class_getInstanceMethod(UserDefaults.self, remove) {
            let original = unsafeBitCast(method_getImplementation(method), to: Remove.self)
            let replacement: @convention(block) (AnyObject, NSString) -> Void = { this, key in
                WriteRecorder.note(this, key as String, "remove")
                original(this, remove, key)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// The suite an instance reads and writes, from its ivar where this Foundation has one.
    static func identifier(of instance: UserDefaults) -> String {
        for name in ["_identifier_", "_identifier"] {
            if let ivar = class_getInstanceVariable(UserDefaults.self, name) {
                return (object_getIvar(instance, ivar) as? String) ?? "nil"
            }
        }
        return "?"
    }

    static func note(_ instance: AnyObject, _ key: String, _ how: String) {
        let kind: String
        if instance === suite {
            kind = "the profile's suite"
        } else if instance === standard {
            kind = "the standard defaults as they were"
        } else if let defaults = instance as? UserDefaults {
            kind = "another instance (suite \(identifier(of: defaults)))"
        } else {
            kind = "an object of class \(NSStringFromClass(type(of: instance)))"
        }
        lock.lock()
        let first = seen.insert(key + "|" + kind).inserted
        lock.unlock()
        guard first else { return }
        // The frames below this one and the replacement: image and symbol, as the stack names them.
        let frames = Thread.callStackSymbols.dropFirst(3).prefix(9).map { line -> String in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { return line }
            return String(parts[1]) + " " + parts[3...].joined(separator: " ")
        }
        NSLog("UISTATE write %@ %@ through %@ from: %@", how, key, kind, frames.joined(separator: " < "))
    }
}
