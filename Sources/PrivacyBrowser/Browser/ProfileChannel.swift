import BrowserCore
import Foundation
import os

/// What the manager process and a profile's process say to each other.
///
/// The parts of this app that live in the manager — the profile list, the warm-up controls, cookie
/// import, the password and library windows — used to reach straight into a running
/// `BrowserSession`. With the profile in a process of its own there is nothing to reach into, so
/// they ask, and the profile answers.
///
/// Two one-way streams, one JSON object per line. Commands go down the child's standard input,
/// which starts with the profile's grant (`ProfileGrant`: its key and its entry in the index, and
/// not the vault's master key); events come back on the child's
/// standard output, each line prefixed, because Safari's own frameworks print there too and
/// anything unprefixed is theirs.
enum ProfileCommand: Codable {
    /// Quit, sealing on the way out — the same path as ⌘Q and SIGTERM.
    case stop
    /// Bring the profile's windows forward.
    case activate
    /// Another window of the same profile.
    case openWindow
    /// Another window of the same profile, on `url`.
    case openURL(URL)
    case showLibrary(section: String)
    case showPasswords
    case importCookies([ImportedCookie])
    /// Every cookie of the profile's store, for an export (`CookieExport`).
    case exportCookies
    case startWarmUp(WarmUpPlan)
    case stopWarmUp
    /// Run a scenario (`ScenarioRunner`) in a window of its own of this profile.
    case runScenario(ScenarioRunRequest)
    /// Stop it: a command under way finishes first.
    case stopScenario(ScenarioRunner.StopReason)
    /// Watch what the person does in this profile's pages, for a scenario (`ScenarioRecorder`).
    case startRecording
    case stopRecording
    /// Say where this profile's traffic goes (`ProfileNetworkGuard.report`); with `probe`, also
    /// fetch it once by each of the process's own ways of making a request.
    case checkNetwork(probe: URL?)
    /// The app's settings for browsing (Settings → Behavior, Downloads), sent when the process
    /// starts and whenever they change; they apply at once.
    case preferences(BrowsingPreferences)
    /// Choose every item of Safari's menu bar in turn, from item `from` on, and say what each did
    /// (`SafariMenuWalk`). Sent by the `--menu-walk` check only, never by the app.
    case walkMenu(from: Int)
    /// Close every window of the profile as its close button does — the way a person ends a
    /// profile; the last one closing quits the process, which seals. Sent by the self-test only.
    case closeWindows
    /// The manager's decision on this launch's WebRTC (`WebRTCGate`): the relay the profile's pages
    /// are given, or why there is none. A profile with a SOCKS5 proxy that wants WebRTC waits for it
    /// before it builds anything, and without it runs with WebRTC off.
    case webRTC(WebRTCLaunchMessage)
    /// Look at the data-protection keychain from inside this process (`KeychainCheck`): which of the
    /// entitlements that give one it holds, and what the keychain lets it do under the probe's own
    /// service. Sent by the self-test and the release check only, never by the app.
    case checkKeychain(KeychainProbe)
    /// Choose History › Show All History as the person does, and say what the window then shows
    /// (`HistoryWindowReader`). Sent by the self-test only, never by the app.
    case lookAtHistory
    /// Do `action` to the profile's window as a person would and say what the window then shows
    /// (`WindowProbe`). Sent by the self-test only, never by the app.
    case lookAtWindow(WindowProbeAction)
}

/// A scenario to run in a profile's process: its text and its parameters (JSON), named for its log.
struct ScenarioRunRequest: Codable, Equatable {
    var runID: UUID
    var name: String
    var source: String
    var parametersJSON: String
}

/// What the manager decided for a launch's WebRTC. With `relay`, the profile's pages are given that
/// TURN server — the manager's, on loopback (`WebRTCRelays`) — as their only ICE server, and the
/// network guard holds the profile's processes to the proxy; without it, WebRTC is off in the
/// engine, for `refusal`.
struct WebRTCLaunchMessage: Codable, Equatable {
    struct Relay: Codable, Equatable {
        var urls: [String]
        var username: String
        var credential: String
    }

    var relay: Relay?
    var refusal: WebRTCRefusal?
}

enum ProfileEvent: Codable {
    /// Something the user should see, shown by the manager in its own window.
    case error(String)
    /// The profile is up and its first window is on screen; `hostsSafariChrome` says whether that
    /// window is Safari's own chrome (the self-test checks the chrome's web views use the proxy).
    case running(hostsSafariChrome: Bool)
    /// Sent with `running`: the interface's language this process was given (`code`), the one its
    /// bundles took — AppKit's words and, when hosted, Safari's chrome (`bundles`, `chrome`). The
    /// self-test checks them against what the profile's pages see, which is never decided by them.
    case interfaceLanguage(code: String, bundles: String, chrome: String?)
    /// Where the warm-up of this profile has got to; sent as the run goes on, and once more when
    /// it ends. Everything the warm-up screen and the profile list show comes from here.
    case warmUp(WarmUpStatus)
    /// A line of a scenario's run log, as the run goes.
    case scenarioLine(runID: UUID, ScenarioRunner.Line)
    /// How a scenario's run ended.
    case scenarioEnded(runID: UUID, ScenarioRunner.Outcome)
    /// Something the person did, or a page that loaded, while a scenario is being recorded.
    case recorded(ScenarioRecorder.Event)
    /// The answer to `importCookies`: what the profile's store did with them, or nil when the
    /// profile could not take them (it was starting or stopping).
    case cookiesImported(ProfileManager.CookieImportOutcome?)
    /// The answer to `exportCookies`; nil when the profile could not give them (starting or
    /// stopping).
    case cookiesExported([ImportedCookie]?)
    /// The answer to `checkNetwork`.
    case networkReport(ProfileNetworkReport)
    /// The profile's settings were saved in its process (a proxy location remembered, a site
    /// never to save passwords for): the manager records the new revision in the index, which
    /// only it writes (`ProfileRepository.onRevisionBump`), and shows the settings again.
    case configurationSaved
    /// Settings asked for in the profile's window (⌘, or Settings… in Safari's chrome): the
    /// manager opens its own Settings. Safari's own are built on services this process does not
    /// have, and took it down (`SafariChrome.stubChromeFeatures`).
    case showSettings
    /// The process is quitting and sealing the profile's data: the manager shows the profile as
    /// being encrypted until the process exits.
    case sealing
    /// How the profile's WebKit data was sealed, just before the process exits.
    case sealed(ProfileSealReport)
    /// No geolocation service answered through the profile's proxy: where it exits is not known,
    /// and the profile runs in the last known location's time zone and language, or this Mac's.
    case proxyLocationUnknown
    /// One step of `walkMenu`, as a line of JSON (`SafariMenuWalk`).
    case menuWalk(String)
    /// The answer to `checkKeychain`.
    case keychainReport(KeychainReport)
    /// The answer to `lookAtHistory`.
    case historyLook(HistoryWindowLook)
    /// The answer to `lookAtWindow`.
    case windowLook(WindowLook)
}

/// How a profile's WebKit data was sealed as its process quit: whether WebKit let the store go
/// (`forced` false) or it had to be sealed from under it (`WebDataStoreVault.forceSeal`), after how
/// many attempts, and how long the seal took. The self-test reads it.
struct ProfileSealReport: Codable, Equatable {
    var forced = false
    var attempts = 0
    var seconds = 0.0
    /// Pages of Safari's chrome closed before the seal (`ProfileNetworkGuard.closeEveryPage`).
    var pagesClosed = 0
}

/// One line of JSON per message, and a prefix on the way back so that Safari's own output on the
/// same stream is not mistaken for ours.
enum ProfileChannel {
    static let eventPrefix = "PBEVENT "
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileChannel")

    static func encode<Message: Encodable>(_ message: Message, prefix: String = "") -> Data? {
        guard let json = try? JSONEncoder().encode(message), let text = String(data: json, encoding: .utf8) else {
            log.error("Could not encode a message for the profile channel")
            return nil
        }
        return Data((prefix + text + "\n").utf8)
    }

    static func decode<Message: Decodable>(_ type: Message.Type, from line: String, prefix: String = "") -> Message? {
        guard line.hasPrefix(prefix) else { return nil }
        let json = String(line.dropFirst(prefix.count))
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Calls `onLine` for each complete line that arrives on `handle`, on the main actor, and
    /// `onEnd` once when the other side has closed it. Reading happens on Foundation's own queue;
    /// partial lines are kept until the rest arrives.
    static func readLines(from handle: FileHandle, onEnd: (@MainActor () -> Void)? = nil,
                          onLine: @escaping @MainActor (String) -> Void) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                if let onEnd { DispatchQueue.main.async { MainActor.assumeIsolated { onEnd() } } }
                return
            }
            for line in buffer.take(data) {
                DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
            }
        }
    }

    /// Holds what arrived before the newline that completes it.
    private final class LineBuffer: @unchecked Sendable {
        private var pending = Data()
        private let lock = NSLock()

        func take(_ data: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            pending.append(data)
            var lines: [String] = []
            while let index = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<index]
                pending = pending[pending.index(after: index)...]
                if let text = String(data: line, encoding: .utf8), !text.isEmpty { lines.append(text) }
            }
            return lines
        }
    }
}
