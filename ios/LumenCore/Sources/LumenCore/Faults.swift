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
    case backIgnored             // the back button does nothing
    case forwardIgnored          // the forward button does nothing
    case reloadIgnored           // the reload button does nothing
    // Proxies
    case proxyNotApplied         // a session's proxy never reaches its relay: the session goes direct
    case proxyChangeNotLive      // one proxy changed for another takes effect only after a relaunch
    case proxyChangeKeepsConnections // a proxy change leaves the relay's open connections on their old route
    case proxyChangeDropsTabs    // a proxy change closes the session's tabs and opens one empty tab
    case proxyPasswordNotSaved   // the password is not kept
    case passwordAutofill        // the proxy form closes with its login and password still in it: iOS offers to save them
    // A dead proxy: the most dangerous breakage is a session quietly going direct
    case deadHTTPDropped         // an HTTP proxy whose check failed is left off: its session goes direct
    case deadSOCKSDropped        // the same for a SOCKS5 proxy
    case recheckDropsProxy       // a re-check that finds a proxy dead takes it off its sessions
    case failoverOn              // the relay falls back to a direct connection when the proxy cannot carry one
    // The relay must not become a new hole
    case relayOpen               // the relay takes connections without its password: any app on the device can use it
    case relayOnNetwork          // the relay listens on every interface and takes connections from anywhere
    case relayResolvesLocally    // the relay looks a site's name up on the device and hands the proxy its address
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
