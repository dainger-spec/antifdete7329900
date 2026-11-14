import BrowserCore
import Foundation
import ObjectiveC
import os
import WebKit

/// The profile's geolocation answered by the engine itself, not by a script in the page
/// (docs/ISOLATION_AND_LIMITATIONS.md, "Geolocation"). On macOS WebKit has no location source of
/// its own: the app that hosts it hands it positions through `WKGeolocationManagerSetProvider`
/// (Safari does so from CoreLocation; WebGeolocationManagerProxy uses a built-in CoreLocation
/// provider on iOS only). In a profile's own process this app is that host, so it gives the engine
/// the profile's coordinates, and answers the engine's permission question the profile's way —
/// fixed coordinates allowed, "deny" denied — on whatever UI delegate Safari's code gives a web
/// view. The page then meets the engine's own `navigator.geolocation`, its own positions, errors
/// and permission states, in every frame; nothing of ours is in it.
///
/// The provider's functions are WebKit's C API, looked up at run time: where one is missing, this
/// stays off and the script does what it did before (`PrivacyScripts.patchGeolocation`). Only in a
/// profile's own process (one profile per process, as the provider is one per process).
enum NativeGeolocation {
    private typealias GetManager = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias SetProvider = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias DidChange = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias DidFail = @convention(c) (UnsafeRawPointer) -> Void
    private typealias CreatePosition = @convention(c) (Double, Double, Double, Double) -> UnsafeRawPointer?
    private typealias Release = @convention(c) (UnsafeRawPointer) -> Void

    private struct API {
        let getManager: GetManager
        let setProvider: SetProvider
        let didChange: DidChange
        let didFail: DidFail
        let createPosition: CreatePosition
        let release: Release
    }

    /// `WKGeolocationProviderV1` as WebKit declares it (WKGeolocationManager.h).
    private struct ProviderV1 {
        var version: Int32
        var clientInfo: UnsafeRawPointer?
        var startUpdating: (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void)?
        var stopUpdating: (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void)?
        var setEnableHighAccuracy: (@convention(c) (UnsafeRawPointer?, Bool, UnsafeRawPointer?) -> Void)?
    }

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "NativeGeolocation")

    private static let api: API? = {
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
            return unsafeBitCast(pointer, to: type)
        }
        guard let getManager = symbol("WKContextGetGeolocationManager", as: GetManager.self),
              let setProvider = symbol("WKGeolocationManagerSetProvider", as: SetProvider.self),
              let didChange = symbol("WKGeolocationManagerProviderDidChangePosition", as: DidChange.self),
              let didFail = symbol("WKGeolocationManagerProviderDidFailToDeterminePosition", as: DidFail.self),
              let createPosition = symbol("WKGeolocationPositionCreate", as: CreatePosition.self),
              let release = symbol("WKRelease", as: Release.self) else { return nil }
        return API(getManager: getManager, setProvider: setProvider, didChange: didChange, didFail: didFail,
                   createPosition: createPosition, release: release)
    }()

    /// What the profile says (`engage`), nil until then.
    private(set) static var setting: GeolocationSetting?
    /// The engine answers for the profile in this process: the page script leaves geolocation alone.
    static var isEngaged: Bool { setting != nil }

    private static let provider: UnsafeMutablePointer<ProviderV1> = {
        let pointer = UnsafeMutablePointer<ProviderV1>.allocate(capacity: 1)
        pointer.initialize(to: ProviderV1(
            version: 1, clientInfo: nil,
            startUpdating: { manager, _ in if let manager { NativeGeolocation.deliver(to: manager) } },
            stopUpdating: { _, _ in },
            setEnableHighAccuracy: { manager, _, _ in if let manager { NativeGeolocation.deliver(to: manager) } }))
        return pointer
    }()
    private static var installedManagers = Set<UnsafeRawPointer>()
    private static var coveredDelegateClasses = Set<String>()

    /// In a profile's own process, before its first web view: the engine answers the profile's
    /// geolocation from now on. False — the script keeps doing it — where WebKit lacks the API or
    /// the delegate setter cannot be watched.
    @discardableResult
    static func engage(_ setting: GeolocationSetting) -> Bool {
        guard self.setting == nil else { return true }
        guard api != nil else {
            log.notice("WebKit's geolocation provider API is not in this macOS: the page script answers")
            return false
        }
        let selector = NSSelectorFromString("setUIDelegate:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { webView, delegate in
            if let delegate { NativeGeolocation.coverPermission(of: delegate) }
            original(webView, selector, delegate)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        self.setting = setting
        log.notice("The engine answers this profile's geolocation")
        return true
    }

    /// Every web view of the profile (`ProfileNetworkGuard.inspect`): the provider on its engine,
    /// and the profile's answer on the delegate it already has.
    static func cover(_ webView: WKWebView) {
        guard isEngaged, let api else { return }
        // A WKProcessPool is the C API's WKContextRef in Cocoa's WebKit (the same object). Given
        // anew for each web view: whoever set a provider before (Safari's code) is replaced.
        let pool = webView.configuration.value(forKey: "processPool") as AnyObject
        if let manager = api.getManager(Unmanaged.passUnretained(pool).toOpaque()) {
            api.setProvider(manager, UnsafeRawPointer(provider))
            if installedManagers.insert(manager).inserted { log.notice("Geolocation provider given to the engine") }
        }
        if let delegate = webView.uiDelegate { coverPermission(of: delegate) }
    }

    /// The engine asks for a position: the profile's coordinates, now — or none, when it denies.
    private static func deliver(to manager: UnsafeRawPointer) {
        guard let api else { return }
        guard case let .fixed(latitude, longitude, accuracy) = setting else {
            api.didFail(manager)
            return
        }
        guard let position = api.createPosition(Date().timeIntervalSince1970, latitude, longitude, accuracy) else {
            api.didFail(manager)
            return
        }
        api.didChange(manager, position)
        api.release(position)
    }

    private static var allows: Bool {
        if case .fixed = setting { return true }
        return false
    }

    /// The engine's permission question, on the delegate's class: answered the profile's way, as
    /// Safari answers a site its settings allow or deny (WKUIDelegatePrivate, both forms).
    private static func coverPermission(of delegate: AnyObject) {
        guard isEngaged, let delegateClass = object_getClass(delegate) else { return }
        guard coveredDelegateClasses.insert(NSStringFromClass(delegateClass)).inserted else { return }
        // macOS 12+: the origin form, answered with a WKPermissionDecision (grant 1, deny 2).
        let originQuestion = NSSelectorFromString("_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:")
        typealias Decision = @convention(block) (Int) -> Void
        let byOrigin: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, Decision) -> Void = { _, _, _, _, decide in
            decide(NativeGeolocation.allows ? 1 : 2)
        }
        class_replaceMethod(delegateClass, originQuestion, imp_implementationWithBlock(byOrigin), "v@:@@@@?")
        // The older form, answered yes or no.
        let frameQuestion = NSSelectorFromString("_webView:requestGeolocationPermissionForFrame:decisionHandler:")
        typealias Allowed = @convention(block) (Bool) -> Void
        let byFrame: @convention(block) (AnyObject, AnyObject?, AnyObject?, Allowed) -> Void = { _, _, _, decide in
            decide(NativeGeolocation.allows)
        }
        class_replaceMethod(delegateClass, frameQuestion, imp_implementationWithBlock(byFrame), "v@:@@@?")
        log.notice("Geolocation permission of \(NSStringFromClass(delegateClass), privacy: .public) answered the profile's way")
    }
}
