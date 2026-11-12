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
    case checkWithoutDeadline    // the proxy check has no deadline of its own: one that gets no answer spins for ever
    // A dead proxy: the most dangerous breakage is a session quietly going direct
    case deadHTTPDropped         // an HTTP proxy whose check failed is left off: its session goes direct
    case deadSOCKSDropped        // the same for a SOCKS5 proxy
    case recheckDropsProxy       // a re-check that finds a proxy dead takes it off its sessions
    case failoverOn              // the relay falls back to a direct connection when the proxy cannot carry one
    // The relay must not become a new hole
    case relayOpen               // the relay takes connections without its password: any app on the device can use it
    case relayOnNetwork          // the relay listens on every interface and takes connections from anywhere
    case relayResolvesLocally    // the relay looks a site's name up on the device and hands the proxy its address
    case relayFailoverOn         // the data store's relay with allowFailover = true: a dead relay lets the system go direct
    case relayGapDirect          // while the relay starts again, the data store is left with no proxy at all
    case pathChangeKeepsConnections // a network change leaves the relay's connections open on the old network
    case lockedOpensDirect       // a profile that lived behind a proxy opens directly when its proxy may not be used
    // Plans (rights from Access)
    case profileLimitIgnored     // the plan's profile limit is not kept: a free iPhone makes a third profile
    case freePlanProxies         // the free plan's proxies left on: a free profile goes through a proxy
    case noBrowseOpens           // a document without "browse" (a blocked account) opens profiles like the free level
    case textsNotTranslated      // the English table is not asked: an English iPhone reads Russian
    case unpaidPlanNamed         // a plan is named to a person who has paid for none ("Бесплатный")
    case profileTokenLowercase   // a synced profile's label is made of its UUID in lower case (the Mac writes upper)
    case syncHeaderOfAnotherVault // the sync takes a vault header the server gave for another vault id
    case spaceRefusalStopsSync    // a 413 or 507 about one object stops the whole sync run
    case syncedProxyNotBound      // a Mac profile with a proxy comes to the iPhone without it — it would open directly
    case syncReadWrites           // the read-only sync step lets the engine write back to the server
    // The account (rights from the server's signed document)
    case signatureNotChecked     // a document's signature is not checked: anyone's payload is taken
    case wrongDeviceAccepted     // a document of another device or another iPhone is taken
    case unknownFeatureRejected  // a feature name this app does not know makes the document unreadable
    case featuresFromPlan        // the rights come from the plan's status, not from the document's features
    case freeLimitOwnRule        // signed in without a plan, the profile count is the app's own, not the document's
    case documentNeverExpires    // a document is in force for ever: its last day and the period's end are not looked at
    case clockRollbackTrusted    // the decision is made by the bare clock: set back, it brings a document back
    case overLimitOpens          // profiles beyond the plan's count open like the rest
    case activationWithoutPlatform // the activation does not say "ios": the server counts the iPhone as a Mac
    case phoneLimitUnexplained   // the refusal for the license's limit of phones is shown without its reason
    case robotCheckNotShown      // a sign-in that asks for the robot check gets its words and no check
    case revokedStaysSignedIn    // the server says the iPhone is unlinked, and the app keeps its token and document
    // The network-switch probe (the instrument for the real iPhone)
    case probeBlind              // the probe never learns the device's own addresses: it can see no leak
    case probeTrustsUnknown      // an answer from an address the probe does not know counts as through the proxy
    // Session settings
    case settingsNotSaved        // a session's settings are not written
    case userAgentIgnored        // the chosen User-Agent is not given to the web view
    case workerHookTimeZoneOnly  // blob workers hooked only with a replaced time zone (page-shim.js before 8 November)
    case profileDefaultsReal     // a new session's canvas, WebGL and audio are left real: not profiled by default
    case timeZoneIgnored         // the page keeps the device's time zone
    case noiseUnstable           // the canvas noise seed changes on every read
    case canvasNoiseLowBit       // the canvas noise flips a colour's low bit, which a canvas cannot hold at partial alpha: its PNG reads back otherwise
    case noWebPageNamespace      // no extension controller: pages lack window.browser, which Safari gives every page
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
