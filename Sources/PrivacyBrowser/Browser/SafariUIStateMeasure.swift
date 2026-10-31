import Foundation
import ObjectiveC

/// Measurement only (PB_MEASURE_UI_STATE=1), never merged: what SafariUIState's domain does in a
/// profile's process. Says whether the standard defaults are the profile's domain, what the file and
/// cfprefsd held as the process started, whether this app's own domain and the argument domain
/// answer through the standard defaults, how long cfprefsd takes to write a change to the file, and
/// every key written through NSUserDefaults, once per key and instance, with the instance it went
/// through. At exit, after SafariUIState wrote the file, one more key is left to cfprefsd alone:
/// whether it writes the file after the manager has sealed the home and removed it.
enum SafariUIStateMeasure {
    static var isOn: Bool { ProcessInfo.processInfo.environment["PB_MEASURE_UI_STATE"] == "1" }

    static func started(path: String, suite: UserDefaults, original: UserDefaults, cached: Int, saved: Int) {
        guard isOn else { return }
        NSLog("UISTATE domain %@; the file held %ld keys, cfprefsd %ld (%@)", path, saved, cached,
              cached == saved ? "the same count" : "made the file's")
        NSLog("UISTATE the standard defaults are the profile's domain: %@",
              UserDefaults.standard === suite ? "yes" : "no")
        NSLog("UISTATE this app's own domain through the standard defaults (CI's probe): %@",
              UserDefaults.standard.string(forKey: "PBUIStateAppDomainProbe") ?? "not seen")
        WriteRecorder.install(standard: original, suite: suite)
        // A canary through the domain: when cfprefsd has it in the file, and whether the account's
        // domain of this app got it. Taken out again, so that the next run's saved keys are Safari's.
        suite.set("canary", forKey: "PBUIStateCanary")
        let written = Date()
        DispatchQueue.global().async {
            var after: TimeInterval?
            for _ in 0..<200 {
                if (NSDictionary(contentsOfFile: path + ".plist")?["PBUIStateCanary"]) != nil {
                    after = Date().timeIntervalSince(written)
                    break
                }
                usleep(50_000)
            }
            let inAccount = CFPreferencesCopyValue("PBUIStateCanary" as CFString, (Bundle.main.bundleIdentifier ?? "") as CFString,
                                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost) != nil
            NSLog("UISTATE the canary: in the file %@; in the account's domain of this app: %@",
                  after.map { String(format: "after %.2f s", $0) } ?? "not within 10 s", inAccount ? "yes" : "no")
            suite.removeObject(forKey: "PBUIStateCanary")
        }
        // Once Safari's chrome has set its services' settings: the argument domain, through the
        // standard defaults, answers as itself?
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            let same = arguments.filter { key, value in (UserDefaults.standard.object(forKey: key) as AnyObject?)?.isEqual(value) == true }
            NSLog("UISTATE the argument domain through the standard defaults: %ld of its %ld keys answer as there",
                  same.count, arguments.count)
        }
    }

    /// At exit, after the file was written: one more key, left to cfprefsd.
    static func lateWrite(_ suite: UserDefaults) {
        guard isOn else { return }
        suite.set(Date().timeIntervalSince1970, forKey: "PBUIStateLateWrite")
        NSLog("UISTATE a late key left to cfprefsd as the process exits")
    }
}

/// Each key written through NSUserDefaults in this process, once per key and instance, with the
/// instance (the profile's domain, the standard defaults as they were, or another) and the frames
/// that wrote it.
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
            kind = "the profile's domain"
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
        let frames = Thread.callStackSymbols.dropFirst(3).prefix(6).map { line -> String in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { return line }
            return String(parts[1]) + " " + parts[3...].joined(separator: " ")
        }
        NSLog("UISTATE write %@ %@ through %@ from: %@", how, key, kind, frames.joined(separator: " < "))
    }
}
