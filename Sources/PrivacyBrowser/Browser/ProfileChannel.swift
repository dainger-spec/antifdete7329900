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
    /// Say where this profile's traffic goes (`ProfileNetworkGuard.report`); with `probe`, also
    /// fetch it once by each of the process's own ways of making a request.
    case checkNetwork(probe: URL?)
    /// The app's settings for browsing (Settings → Behavior, Downloads), sent when the process
    /// starts and whenever they change; they apply at once.
    case preferences(BrowsingPreferences)
}

enum ProfileEvent: Codable {
    /// Something the user should see, shown by the manager in its own window.
    case error(String)
    /// The profile is up and its first window is on screen; `hostsSafariChrome` says whether that
    /// window is Safari's own chrome (the self-test checks the chrome's web views use the proxy).
    case running(hostsSafariChrome: Bool)
    /// Where the warm-up of this profile has got to; sent as the run goes on, and once more when
    /// it ends. Everything the warm-up screen and the profile list show comes from here.
    case warmUp(WarmUpStatus)
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
