import Foundation

/// Faults planted on purpose, so that every check is seen failing before it is trusted (the red run
/// before the green one). Only a DEBUG build reads them — from the environment (`LUMEN_FAULTS`, a
/// comma-separated list; the UI tests pass it to the app) or the launch arguments
/// (`-LumenFaults a,b`). A release build has none: `isActive` is always false there.
public enum Fault: String, CaseIterable, Sendable {
    // Sessions
    case sessionsNotSaved        // the catalogue is never written: a relaunch shows nothing
    case renameIgnored           // a rename is not applied
    case searchIgnoresTags       // the list's search does not look at tags
    case notesNotSaved           // a session's description is dropped
    // Browser
    case tabsNotRestored         // open tabs are not written: a relaunch shows one empty tab
    case historyNotRecorded      // visited pages never reach the history
    case searchEngineIgnored     // the address bar always searches with Google
    case sharedStore             // every session on WebKit's default store: no isolation
    case newTabNotOpened         // "new tab" selects the current one instead
    // Proxies
    case proxyNotApplied         // a session's proxy is never given to its data store
    case proxyChangeNotLive      // a new proxy takes effect only after a relaunch
    case proxyPasswordNotSaved   // the password is not kept
    case ios17GuardOff           // an HTTP proxy is used on iOS 17, where plain-http pages go around it
    case ios17LoadsAnyway        // the session is said to load nothing on iOS 17, yet its pages load
    case refusalHidden           // the session loads nothing on iOS 17 and does not say why
    case refusalSkipsBackForward // back/forward navigations (a restored tab is one) go through anyway
    // Session settings
    case settingsNotSaved        // a session's settings are not written
    case userAgentIgnored        // the chosen User-Agent is not given to the web view
    case timeZoneIgnored         // the page keeps the device's time zone
    case noiseUnstable           // the canvas noise seed changes on every read
    case unmaskedReplacement     // one replacement made plainly, as most scripts do: the natives check must see it
}

public enum Faults {
    /// Read once per process.
    public static let active: Set<Fault> = {
        #if DEBUG
        var names: [String] = []
        if let value = ProcessInfo.processInfo.environment["LUMEN_FAULTS"] { names += value.split(separator: ",").map(String.init) }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-LumenFaults"), i + 1 < args.count { names += args[i + 1].split(separator: ",").map(String.init) }
        return Set(names.compactMap { Fault(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
        #else
        return []
        #endif
    }()

    public static func isActive(_ fault: Fault) -> Bool {
        #if DEBUG
        return active.contains(fault)
        #else
        return false
        #endif
    }
}
