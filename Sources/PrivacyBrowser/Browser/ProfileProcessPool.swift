import Foundation
import WebKit

/// The WebKit process pool of one running profile: its web content processes, and the service and
/// shared workers its pages start, belong to that profile alone.
///
/// Why a pool of its own rather than WebKit's shared one:
///   * Time zone. `_WKProcessPoolConfiguration.timeZoneOverride` (WebKit SPI, macOS 13+) is handed
///     to every process the pool launches, which sets it process-wide before any script runs
///     (`WebProcess::initializeWebProcess` → `WTF::setTimeZoneOverride`). The page, its frames,
///     dedicated, shared and service workers, `Date` and `Intl` (and `Temporal`, where WebKit exposes it) then report the
///     profile's zone as the engine's own values. The JavaScript shim reaches only the page and the
///     workers it makes from a blob (docs/ISOLATION_AND_LIMITATIONS.md §6).
///   * Workers. WebKit gives the service and shared workers of a pool the User-Agent of the page
///     that set one last (`WebPageProxy::setUserAgent` → `WebProcessPool::updateRemoteWorkerUserAgent`).
///     In one shared pool, a profile's workers could carry another running profile's User-Agent.
///
/// PLATFORM LIMITATION: private API. Pools other than the shared one are deprecated (the public
/// headers say they have no effect; WebKit still uses the pool a configuration names), and the
/// override is SPI. Each is used only when this WebKit has it. Otherwise the profile runs in the
/// shared pool and the shim keeps the time zone; the shim also checks, at document start, whether
/// the engine already reports the profile's zone (`PrivacyScripts`), so a process the override did
/// not reach still gets it. The self-test reports which applies.
@MainActor
enum ProfileProcessPool {
    struct Pool {
        /// A `WKProcessPool` (typed as `NSObject`: the class is deprecated in the public SDK).
        let processPool: NSObject
        /// The zone every process of this pool runs in; nil when none was asked for or set.
        let timeZone: String?
    }

    /// Profiles started while this is set use WebKit's shared pool and keep the time zone in the
    /// shim (self-test: the JavaScript fallback is checked as well as the engine).
    static var isDisabledForTesting = false

    private static let configurationClass = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type
    private static let poolClass: AnyClass? = NSClassFromString("WKProcessPool")
    private static let timeZoneSetter = NSSelectorFromString("setTimeZoneOverride:")
    /// `+[WKProcessPool _processPoolWithConfiguration:]`: newer WebKit only (not macOS 26.6).
    private static let factory = NSSelectorFromString("_processPoolWithConfiguration:")
    /// `-[WKProcessPool _initWithConfiguration:]`, the designated initializer since macOS 10.10.
    private static let initializer = NSSelectorFromString("_initWithConfiguration:")
    private static let allocator = NSSelectorFromString("alloc")

    /// This WebKit can give a profile a pool of its own.
    static var isAvailable: Bool {
        guard configurationClass != nil, let poolClass else { return false }
        return class_getClassMethod(poolClass, factory) != nil || class_getInstanceMethod(poolClass, initializer) != nil
    }

    /// Which of the private pieces this WebKit has (self-test information).
    static var availability: String {
        let pieces: [(String, Bool)] = [
            ("_WKProcessPoolConfiguration", configurationClass != nil),
            ("timeZoneOverride", configurationClass?.instancesRespond(to: timeZoneSetter) == true),
            ("+_processPoolWithConfiguration:", poolClass.map { class_getClassMethod($0, factory) != nil } ?? false),
            ("-_initWithConfiguration:", poolClass.map { class_getInstanceMethod($0, initializer) != nil } ?? false),
        ]
        return pieces.map { "\($0.0) \($0.1 ? "yes" : "no")" }.joined(separator: ", ")
    }

    /// This WebKit can run a pool's processes in a time zone of its choosing.
    static var supportsTimeZoneOverride: Bool {
        isAvailable && configurationClass?.instancesRespond(to: timeZoneSetter) == true
    }

    /// A new pool for a profile, its processes in `timeZone` (an IANA identifier) when this WebKit
    /// allows it. Nil without the SPI: the profile then uses WebKit's shared pool.
    static func make(timeZone: String?) -> Pool? {
        guard !isDisabledForTesting, isAvailable, let configurationClass, let poolClass else { return nil }
        let configuration = configurationClass.init()
        var applied: String?
        // WebKit ignores a zone ICU does not know (`WTF::setTimeZoneOverride` returns false): the
        // pages would then run in the Mac's zone without a shim. Only known zones are handed over.
        if let timeZone, TimeZone(identifier: timeZone) != nil, configuration.responds(to: timeZoneSetter) {
            configuration.setValue(timeZone, forKey: "timeZoneOverride")
            applied = configuration.value(forKey: "timeZoneOverride") as? String
        }
        guard let pool = makePool(poolClass, configuration) else { return nil }
        return Pool(processPool: pool, timeZone: applied)
    }

    private static func makePool(_ poolClass: AnyClass, _ configuration: NSObject) -> NSObject? {
        if let method = class_getClassMethod(poolClass, factory) {
            // +[WKProcessPool _processPoolWithConfiguration:]: an autoreleased pool.
            typealias Factory = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
            let make = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            return make(poolClass as AnyObject, factory, configuration)?.takeUnretainedValue() as? NSObject
        }
        // [[WKProcessPool alloc] _initWithConfiguration:], with ARC's init rules by hand: alloc returns
        // the instance retained, the initializer takes it over and returns the pool retained (or nil,
        // having released it).
        guard let allocMethod = class_getClassMethod(poolClass, allocator),
              let initMethod = class_getInstanceMethod(poolClass, initializer) else { return nil }
        typealias Alloc = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        typealias Initializer = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> UnsafeMutableRawPointer?
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initializer.self)
        guard let allocated = alloc(poolClass as AnyObject, allocator),
              let pool = initialize(allocated, initializer, configuration) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pool).takeRetainedValue() as? NSObject
    }

    /// Web views made from `configuration` (and the popups WebKit makes from theirs) run in `pool`.
    static func assign(_ pool: NSObject, to configuration: WKWebViewConfiguration) {
        configuration.setValue(pool, forKey: "processPool")
    }

    /// The pool the web views of `configuration` run in (self-test).
    static func pool(of configuration: WKWebViewConfiguration) -> NSObject? {
        configuration.value(forKey: "processPool") as? NSObject
    }
}
