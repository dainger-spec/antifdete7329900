import Foundation
import ObjectiveC
import WebKit

/// A measurement branch only: what WebKit and CFNetwork offer, on this macOS, about the network
/// loader WebKit uses from SDK 15.0 on and about how a server's certificate is checked — WebKit's
/// features (`+[WKPreferences _features]`) and the methods of the classes that configure a data
/// store, a process pool and a URL session whose names say loader, trust, TLS, certificate,
/// revocation or fetch. Printed as LOADER lines, with the app's behaviors as built or, with
/// --sdk-everything, as Safari's.
enum LoaderInventory {
    private static let pattern = try! NSRegularExpression(
        pattern: "loader|nwloader|trust|tls|cert|ats|fetch|revocation|ocsp|aia|strict|handshake|challenge|serverauth",
        options: [.caseInsensitive])

    private static func matches(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let everything = arguments.contains("--sdk-everything")
        print("LOADER behaviors: \(everything ? "every one on (Safari's)" : "as built")")
        features()
        for className in ["_WKWebsiteDataStoreConfiguration", "WKWebsiteDataStore", "WKProcessPool", "_WKProcessPoolConfiguration",
                          "WKWebViewConfiguration", "WKPreferences", "NSURLSessionConfiguration", "__NSCFURLSessionConfiguration",
                          "NSURLSession", "NSURLSessionTask", "NSMutableURLRequest"] {
            methods(of: className)
        }
        values()
        exit(0)
    }

    /// WebKit's features whose key or name matches, with the default and this process's value.
    private static func features() {
        let selector = NSSelectorFromString("_features")
        guard (WKPreferences.self as AnyObject).responds(to: selector),
              let list = (WKPreferences.self as AnyObject).perform(selector)?.takeUnretainedValue() as? [NSObject] else {
            print("LOADER features: +[WKPreferences _features] not there")
            return
        }
        let preferences = WKPreferences()
        let isEnabled = NSSelectorFromString("_isEnabledForFeature:")
        typealias IsEnabled = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let check = class_getInstanceMethod(WKPreferences.self, isEnabled).map {
            unsafeBitCast(method_getImplementation($0), to: IsEnabled.self)
        }
        print("LOADER features: \(list.count) in all")
        for feature in list {
            let key = kvc(feature, "key") as? String ?? "?"
            let name = kvc(feature, "name") as? String ?? "?"
            guard matches(key) || matches(name) else { continue }
            let status = (kvc(feature, "status") as? NSNumber)?.intValue ?? -1
            let byDefault = (kvc(feature, "defaultValue") as? NSNumber)?.boolValue
            let here = check.map { $0(preferences, isEnabled, feature) }
            print("LOADER feature \(key) — \"\(name)\": status \(status), default \(byDefault.map { String($0) } ?? "?"), "
                  + "in a new WKPreferences \(here.map { String($0) } ?? "?")")
        }
    }

    /// The instance and class methods of `className` whose names match, with their type encodings.
    private static func methods(of className: String) {
        guard let type: AnyClass = NSClassFromString(className) else {
            print("LOADER class \(className): not there")
            return
        }
        let targets: [(String, AnyClass?)] = [("-", type), ("+", object_getClass(type))]
        for (sign, target) in targets {
            guard let target else { continue }
            var count: UInt32 = 0
            guard let list = class_copyMethodList(target, &count) else { continue }
            defer { free(list) }
            for index in 0..<Int(count) {
                let name = NSStringFromSelector(method_getName(list[index]))
                guard matches(name) else { continue }
                let types = method_getTypeEncoding(list[index]).map { String(cString: $0) } ?? "?"
                print("LOADER method \(sign)[\(className) \(name)] \(types)")
            }
        }
    }

    /// What a new data store configuration and the default URL session configuration hold for the
    /// matching properties that answer key-value coding.
    private static func values() {
        var objects: [(String, NSObject)] = [("URLSessionConfiguration.default", URLSessionConfiguration.default)]
        if let type = NSClassFromString("_WKWebsiteDataStoreConfiguration") as? NSObject.Type {
            objects.append(("_WKWebsiteDataStoreConfiguration (persistent)", type.init()))
        }
        for (label, object) in objects {
            // The properties of the object's class and of each class above it.
            var type: AnyClass? = object_getClass(object)
            var seen = Set<String>()
            while let current = type, current != NSObject.self {
                var count: UInt32 = 0
                if let list = class_copyPropertyList(current, &count) {
                    for index in 0..<Int(count) {
                        let name = String(cString: property_getName(list[index]))
                        guard matches(name), seen.insert(name).inserted else { continue }
                        let value = object.responds(to: NSSelectorFromString(name))
                            ? String(describing: kvc(object, name) ?? "nil") : "(no getter of that name)"
                        print("LOADER value \(label).\(name) (\(NSStringFromClass(current))) = \(value)")
                    }
                    free(list)
                }
                type = class_getSuperclass(current)
            }
        }
    }

    /// Key-value coding only where the object answers the key's getter: an unknown key raises.
    private static func kvc(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }
}
