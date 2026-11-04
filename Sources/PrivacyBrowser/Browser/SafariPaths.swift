import Foundation
import MachO
import os

/// Where Safari's frameworks keep a profile's Safari state — its history index, icons, top sites,
/// per-site settings, content-blocker statistics — in a profile's own process: in the profile's
/// home, never in the user's.
///
/// A profile's process gets the profile's home through `CFFIXED_USER_HOME`, which everything that
/// asks the process for its home follows. Safari's frameworks do not ask: Safari runs in a sandbox
/// container whose home is the container, while its data lives in the account's real
/// ~/Library/Safari, so its code finds that folder from the account's real home. Measured in CI
/// (scripts/disk_check.py): the hosted chrome wrote — and deleted — in the real ~/Library/Safari
/// while a profile ran. That is the profile's browsing in the user's own Safari, outside every
/// encrypted archive, and the user's Safari data read into, and changed by, a profile.
///
/// Two answers, each the fallback of the other:
///   1. Every path getter of Safari's frameworks — a method with no argument that returns an
///      object, implemented in one of Safari's images — answers with the profile's home in place
///      of the real one for anything under the real ~/Library (`redirectGetters`).
///   2. The kernel refuses the process any read or write in the real Safari's places
///      (`ProfileNetworkGuard`), so a path found some other way fails instead of reaching them.
enum SafariPaths {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariPaths")

    /// The account's real home, which `CFFIXED_USER_HOME` does not change.
    static var realHome: String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }

    /// The getters `redirectGetters` patched, as "-[Class selector]" (the network report).
    private(set) static var redirected: [String] = []

    /// Patches the path getters of every Safari image loaded, and the ones Safari's images add to
    /// Foundation's classes, so that a path under `realHome`/Library comes back under `home`.
    /// Runs once, right after Safari's frameworks are loaded and before any of their code runs.
    static func redirectGetters(from realHome: String, to home: String) {
        guard redirected.isEmpty, realHome != home else { return }
        let library = realHome + "/Library/"
        var classes: [AnyClass] = []
        for index in 0..<_dyld_image_count() {
            guard let image = _dyld_get_image_name(index), isSafariImage(String(cString: image)) else { continue }
            var count: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(image, &count) else { continue }
            for position in 0..<Int(count) {
                if let cls = objc_lookUpClass(names[position]) { classes.append(cls) }
            }
            free(names)
        }
        // Safari's categories on Foundation's classes are implemented in Safari's images too.
        classes += [FileManager.self, NSURL.self, NSString.self, Bundle.self, UserDefaults.self, ProcessInfo.self]
        for cls in classes {
            for owner in [cls, object_getClass(cls)].compactMap({ $0 }) {
                var count: UInt32 = 0
                guard let methods = class_copyMethodList(owner, &count) else { continue }
                defer { free(methods) }
                for position in 0..<Int(count) {
                    let method = methods[position]
                    guard isPathGetter(method) else { continue }
                    redirect(method, of: owner, library: library, realHome: realHome, home: home)
                }
            }
        }
        log.notice("\(redirected.count, privacy: .public) path getters of Safari's frameworks answer with the profile's home")
    }

    private static func isSafariImage(_ path: String) -> Bool {
        path.range(of: "/Safari", options: .caseInsensitive) != nil
    }

    /// No argument, an object back, a name that says path, and Safari's own code.
    private static func isPathGetter(_ method: Method) -> Bool {
        let name = String(cString: sel_getName(method_getName(method)))
        guard !name.contains(":"),
              ["Directory", "Path", "Folder", "Home", "Library", "Location", "URL"].contains(where: name.contains),
              !["init", "new", "copy", "mutableCopy", "alloc"].contains(where: name.hasPrefix) else { return false }
        var type = [CChar](repeating: 0, count: 4)
        method_getReturnType(method, &type, type.count)
        guard type[0] == 0x40, type[1] == 0 else { return false } // "@": an object, not a block
        var info = Dl_info()
        guard dladdr(unsafeBitCast(method_getImplementation(method), to: UnsafeRawPointer.self), &info) != 0,
              let image = info.dli_fname else { return false }
        return isSafariImage(String(cString: image))
    }

    private static func redirect(_ method: Method, of owner: AnyClass, library: String, realHome: String, home: String) {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let selector = method_getName(method)
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let replacement: @convention(block) (AnyObject) -> Unmanaged<AnyObject>? = { receiver in
            let result = original(receiver, selector)
            guard let value = result?.takeUnretainedValue() else { return result }
            if let url = value as? NSURL, url.isFileURL, let path = url.path, (path + "/").hasPrefix(library) {
                let moved = NSURL(fileURLWithPath: home + path.dropFirst(realHome.count), isDirectory: url.hasDirectoryPath)
                return Unmanaged.passRetained(moved as AnyObject).autorelease()
            }
            if let string = value as? NSString, (string as String).hasPrefix(library) {
                let moved = NSString(string: home + (string as String).dropFirst(realHome.count))
                return Unmanaged.passRetained(moved as AnyObject).autorelease()
            }
            return result
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        let kind = class_isMetaClass(owner) ? "+" : "-"
        redirected.append("\(kind)[\(NSStringFromClass(owner)) \(NSStringFromSelector(selector))]")
    }

    /// The real Safari's places, as a sandbox profile's filter: the folders Safari keeps its data
    /// in, its container, caches, website data, cookies, preferences and group containers.
    static func sandboxFilter(realHome: String) -> String {
        let library = realHome + "/Library"
        let escaped = NSRegularExpression.escapedPattern(for: library)
        let folders = ["Safari", "Cookies", "SafariSafeBrowsing"]
        // Every com.apple.Safari* name: the containers, caches and stores of Safari's services too.
        let prefixed = ["Containers", "Caches", "WebKit", "HTTPStorages", "Preferences"]
        return (folders.map { "(subpath \"\(library)/\($0)\")" }
            + prefixed.map { "(regex #\"^\(escaped)/\($0)/com\\.apple\\.Safari\")" }
            + ["(regex #\"^\(escaped)/Group Containers/[^/]*[Ss]afari\")"]).joined(separator: " ")
    }
}
