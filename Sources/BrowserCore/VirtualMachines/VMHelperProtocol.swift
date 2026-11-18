import Foundation

/// What the app asks of the machines' helper (`LumenVM`, the one executable that holds Apple's
/// virtualization right), and what the helper says back.
///
/// The request is one JSON line on the helper's standard input — never arguments: it carries the
/// proxy's password — and after it the app may write commands as lines of their own
/// (`VMHelperCommand`): `stop` (close the machine: put it to sleep where the request says so,
/// else ask the guest to shut down), `shutdown` (ask the guest to shut down, whatever the request
/// says), `kill` (end it now), `hosts on` and `hosts off` (say where the machine connects, or
/// stop saying), `block <name>` (block a host from now on) and `fullscreen` (put the guest's
/// front window full screen). The helper answers with one JSON line per event on its standard
/// output, and ends when the machine has.
public struct VMHelperRequest: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Which macOS Apple offers for this Mac's virtual machines (a `catalog` event, then exit).
        case catalog
        /// Which macOS the restore image at `restoreImagePath` holds — one the person already had —
        /// and whether it runs on this Mac: a `catalog` event (its address the file's), then exit.
        case inspect
        /// Install the restore image into `machineDirectory` (the base): `progress` events, then
        /// `installed`.
        case install
        /// Start the machine in `machineDirectory` in a window: `started`, `traffic` now and then,
        /// `stopped` when it has shut down.
        case run
    }

    public struct Display: Codable, Equatable, Sendable {
        public var pixelsWide: Int
        public var pixelsHigh: Int
        public var pixelsPerInch: Int

        public init(pixelsWide: Int, pixelsHigh: Int, pixelsPerInch: Int) {
            self.pixelsWide = pixelsWide
            self.pixelsHigh = pixelsHigh
            self.pixelsPerInch = pixelsPerInch
        }

        public init(_ display: VMDisplay) {
            self.init(pixelsWide: display.pixelsWide, pixelsHigh: display.pixelsHigh, pixelsPerInch: display.pixelsPerInch)
        }
    }

    public enum Network: String, Codable, Sendable {
        /// This Mac's own connection, as any app on it has it — the helper makes the guest's
        /// connections as its own (`VMNetDirectConnector`): sites see this Mac's address, or its
        /// VPN's.
        case direct
        /// Everything through `proxy`, and nothing any other way (`VMNetCore`).
        case proxy
        /// No network card's traffic goes anywhere.
        case closed
        /// No network card at all: the base during its first-run setup. macOS's own setup then
        /// asks nothing of Apple's servers and waits for none of them — it is shorter, and does
        /// not hang where this Mac's connection (a VPN, a proxy tool) keeps the guest from them.
        case absent
    }

    public var mode: Mode
    /// `install`: the restore image's file.
    public var restoreImagePath: String?
    /// `install`, `run`: the machine's folder (`VMLibrary.MachineFiles`).
    public var machineDirectory: String?
    /// `run`: the base's folder — a machine whose folder has no disk yet is cloned from it first,
    /// with an identifier of its own.
    public var baseDirectory: String?
    public var cores: Int
    public var memoryBytes: Int64
    /// `install`: the new disk's length.
    public var diskBytes: Int64
    public var display: Display
    public var macAddress: String?
    public var network: Network
    public var proxy: ProxySettings?
    /// The machine's UDP — HTTP/3 (QUIC), WebRTC — goes out in this run: through the proxy's own
    /// UDP relay (`VMUDPRoute.throughProxy`, found by the check before the start), or, without a
    /// proxy, as this Mac's own (`direct`). Nil or false: answered "port unreachable", as a
    /// helper before this did for every datagram but DNS and the time. Not in `stamp`: the
    /// network is made anew at each start.
    public var relaysUDP: Bool?
    /// Names the machine's network answers "no such name" for (`VMRequirements.blockedHosts`).
    public var blockedHosts: [String]
    /// What the guest plays is heard on this Mac. Off: the machine keeps its speakers, silent.
    public var sound: Bool
    /// The machine's window opens full screen. Nil: as a window.
    public var fullScreen: Bool?
    /// Instant wake: `stop` puts the machine to sleep — its state saved beside its disk
    /// (`VMLibrary.MachineFiles.state`) — and a start that finds a state saved for this very
    /// request (`stateStamp`) and this very disk wakes it instead of starting its macOS. Nil or
    /// false: a state found is removed, and the machine starts and shuts down as a Mac does.
    public var keepsState: Bool?
    /// What a saved state must have been saved for to be woken by this request: the machine's
    /// hardware and the settings its macOS was started with. Anything of them changed — more
    /// memory, another language — and the machine starts anew, so that the change takes.
    public var stateStamp: String?
    /// The machine is shown as a browser: its guest's front window (Safari) is put full screen
    /// once its macOS has started, and the window covers the desktop until then.
    public var browserMode: Bool?
    /// The settings a profile's machine starts with (`VMGuestSettings.revision`), as its guest's
    /// boot script names them back once they are in place (`VMGuestStatus.readyRevision`): until
    /// then a start's window keeps the machine's screen behind a cover (`VMStartCover`). Nil: no
    /// cover — the base system, whose window is for its setup.
    public var settingsRevision: String?
    /// The app's own "animations off" (Settings → Appearance): the cover moves nothing, as under
    /// macOS's Reduce Motion, which the helper reads itself.
    public var reducesMotion: Bool?
    /// The machine's display is put to sleep while its window has been out of sight for a while,
    /// and woken when the window is seen again (`VMScreenSleep`; the profile's choice). Nil: the
    /// display stays as the guest has it. Not in `stamp`: the guest is told while it runs, by a
    /// word in the shared folder, not at its start.
    public var sleepsScreenWhenHidden: Bool?
    /// The window's title, and its few words, in the person's language (the helper has no strings
    /// of its own): `stop`, `stopQuestion`, `stopDetail`, `stopNow`, `cancel`, `stopping`, the
    /// start's cover's (`cover.…`) — and `hint`, a line shown above the machine's screen (what is
    /// left to do in the base).
    public var windowTitle: String
    public var texts: [String: String]
    /// What the bar at the top of a profile's machine's window says of where the machine goes
    /// out (`WindowBar`); nil: the system's title bar, with the title alone (the base system).
    public var windowBar: WindowBar?

    /// The top of a profile's machine's window: where it goes out, as the app knows it at the
    /// start — the exit's country, the proxy, the exit's address, whether UDP (WebRTC, HTTP/3)
    /// goes through — and where to time the proxy's answer from (`pingHost`, `pingPort`: the proxy
    /// itself, or a link's server; nil for a machine without one). Words in the person's language,
    /// as the app sends every word of the helper's.
    public struct WindowBar: Codable, Equatable, Sendable {
        public var countryCode: String?
        public var country: String?
        /// The proxy as the person knows it ("de.proxy.example", "VLESS edge.example"), or the
        /// interface's word for no proxy.
        public var route: String
        public var exitIP: String?
        /// Whether UDP goes through in this run; nil: not said.
        public var udp: Bool?
        /// The words for it, in the bar's tooltip.
        public var udpText: String?
        public var pingHost: String?
        public var pingPort: Int?

        public init(countryCode: String? = nil, country: String? = nil, route: String, exitIP: String? = nil,
                    udp: Bool? = nil, udpText: String? = nil, pingHost: String? = nil, pingPort: Int? = nil) {
            self.countryCode = countryCode
            self.country = country
            self.route = route
            self.exitIP = exitIP
            self.udp = udp
            self.udpText = udpText
            self.pingHost = pingHost
            self.pingPort = pingPort
        }
    }

    public init(mode: Mode, restoreImagePath: String? = nil, machineDirectory: String? = nil, baseDirectory: String? = nil,
                cores: Int = 4, memoryBytes: Int64 = 4 << 30, diskBytes: Int64 = VMRequirements.diskImageBytes,
                display: Display = Display(VMDisplay.standard), macAddress: String? = nil, network: Network = .closed,
                proxy: ProxySettings? = nil, blockedHosts: [String] = [], sound: Bool = true, fullScreen: Bool? = nil,
                keepsState: Bool? = nil, stateStamp: String? = nil, browserMode: Bool? = nil,
                settingsRevision: String? = nil, reducesMotion: Bool? = nil, sleepsScreenWhenHidden: Bool? = nil,
                windowTitle: String = "", texts: [String: String] = [:]) {
        self.mode = mode
        self.restoreImagePath = restoreImagePath
        self.machineDirectory = machineDirectory
        self.baseDirectory = baseDirectory
        self.cores = cores
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.display = display
        self.macAddress = macAddress
        self.network = network
        self.proxy = proxy
        self.blockedHosts = blockedHosts
        self.sound = sound
        self.fullScreen = fullScreen
        self.keepsState = keepsState
        self.stateStamp = stateStamp
        self.browserMode = browserMode
        self.settingsRevision = settingsRevision
        self.reducesMotion = reducesMotion
        self.sleepsScreenWhenHidden = sleepsScreenWhenHidden
        self.windowTitle = windowTitle
        self.texts = texts
    }

    /// The request to start a profile's machine. A profile with a proxy never gets the direct
    /// network: without a usable proxy it is closed. `udp`: where the machine's UDP goes in this
    /// run, as the check before the start found it; nil — not decided — keeps it off.
    public static func run(profile: VMProfile, library: VMLibrary, hostCores: Int, texts: [String: String],
                           udp: VMUDPRoute? = nil) -> VMHelperRequest {
        var request = VMHelperRequest(mode: .run, machineDirectory: library.machineDirectory(for: profile.id).path,
                                      baseDirectory: library.baseDirectory.path,
                                      cores: min(profile.cores ?? VMRequirements.coresWanted, VMRequirements.cores(hostCores: hostCores)),
                                      memoryBytes: Int64(profile.memoryGB) * VMRequirements.gibibyte,
                                      display: Display(profile.display), macAddress: profile.macAddress,
                                      network: profile.proxy == nil ? .direct : .proxy, proxy: profile.proxy,
                                      blockedHosts: VMRequirements.blockedHosts + profile.blockedHosts.compactMap(VMProfile.blockedHost),
                                      sound: profile.soundEnabled, fullScreen: profile.startsFullScreen ? true : nil,
                                      keepsState: profile.instantWake ? true : nil, browserMode: profile.browserMode ? true : nil,
                                      windowTitle: profile.name, texts: texts)
        let revision = VMGuestSettings(profile: profile).revision
        request.stateStamp = request.stamp(settingsRevision: revision)
        request.settingsRevision = revision
        request.sleepsScreenWhenHidden = profile.sleepsScreenWhenHidden ? true : nil
        // UDP only by the route decided for this run, and only the way the machine's network goes:
        // a proxy's relay for a machine with a proxy, this Mac's own for one without.
        if let udp, udp.carriesUDP, (udp == .direct) == (profile.proxy == nil) { request.relaysUDP = true }
        return request
    }

    /// What a saved state of this request's machine goes with (`stateStamp`): its hardware as the
    /// framework is told of it, and the revision of the settings its macOS starts with. Not the
    /// proxy, nor what is blocked: the network is this process's own and is made anew each time.
    /// Nor sound: a machine whose state is kept has none. Nor whether its display sleeps while
    /// its window is hidden: that is said to the guest while it runs.
    public func stamp(settingsRevision: String) -> String {
        VMGuestSettings.revision(of: [
            "cores=\(cores)", "memory=\(memoryBytes)",
            "display=\(display.pixelsWide)x\(display.pixelsHigh)@\(display.pixelsPerInch)",
            "mac=\(macAddress ?? "")", "network=\(network == .absent ? "absent" : "card")",
            "settings=\(settingsRevision)",
        ])
    }

    /// One line, as the helper reads it.
    public func line() throws -> String {
        String(decoding: try JSONCoding.encoder.encode(self), as: UTF8.self)
    }

    public static func parse(_ line: String) throws -> VMHelperRequest {
        try JSONCoding.decoder.decode(VMHelperRequest.self, from: Data(line.utf8))
    }
}

/// One thing the helper says: a line of JSON on its standard output.
public struct VMHelperEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case catalog, progress, installed, started, traffic, stopped, failed
        /// Where the machine connects (`hosts`): said every few seconds while the app asks for
        /// it (`hosts on`).
        case hosts
        /// A machine with instant wake was asked to close and its state could not be saved: it
        /// is being shut down instead (`failure` and `message` say why), and `stopped` follows.
        case notKept
    }

    /// One host a machine's macOS talks to (`VMNetHost`, which the app does not link).
    public struct Host: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var connections: UInt64
        public var open: Int
        public var bytesUp: UInt64
        public var bytesDown: UInt64
        /// Questions for it and connections to it refused because it is blocked.
        public var blocked: UInt64
        /// Seconds since it was last asked for or carried anything.
        public var idle: Double

        public var id: String { name }

        public init(name: String, connections: UInt64 = 0, open: Int = 0, bytesUp: UInt64 = 0, bytesDown: UInt64 = 0,
                    blocked: UInt64 = 0, idle: Double = 0) {
            self.name = name
            self.connections = connections
            self.open = open
            self.bytesUp = bytesUp
            self.bytesDown = bytesDown
            self.blocked = blocked
            self.idle = idle
        }
    }

    public var kind: Kind
    /// `catalog`: the restore image Apple offers. `installed`: the one that was installed.
    public var image: VMRestoreImage?
    /// `progress`: 0…1.
    public var fraction: Double?
    /// `traffic`: what went through the proxy since the machine started.
    public var bytesUp: UInt64?
    public var bytesDown: UInt64?
    public var connections: Int?
    /// `traffic`: why the machine's connections are not being made — a kind (`VMNetworkTrouble`),
    /// set while several in a row have failed and none has been made since: without a proxy, this
    /// Mac's way out; with one, the machine's own proxy (down, or refusing its sign-in).
    public var trouble: String?
    /// With `trouble`: the same in the helper's log's words — a range of addresses, an error's
    /// name; never a name or an address the machine asked for. Shown as a technical detail.
    public var troubleDetail: String?
    /// `traffic`, a machine without a proxy: its connections go through the proxy this Mac's own
    /// network settings name.
    public var viaSystemProxy: Bool?
    /// `failed`, `notKept`: why, in the system's own words (shown to the person as given — as
    /// the whole reason, or as a technical detail under the app's own words for `failure`).
    public var message: String?
    /// `failed`, `notKept`: the kind of reason, where it is one the app has words for in the
    /// person's language — `VMFailureKind`'s raw value.
    public var failure: String?
    /// `started`: the machine was woken from a saved state — it is as it was closed.
    public var woke: Bool?
    /// `started`: a saved state was there and was not used — `VMWakeRefusal`'s raw value.
    public var notWoken: String?
    /// `stopped`: the machine was put to sleep — its state is saved for its next start.
    public var asleep: Bool?
    /// `hosts`: where the machine connects, the host seen last first.
    public var hosts: [Host]?

    public init(kind: Kind, image: VMRestoreImage? = nil, fraction: Double? = nil, bytesUp: UInt64? = nil,
                bytesDown: UInt64? = nil, connections: Int? = nil, trouble: String? = nil, troubleDetail: String? = nil,
                viaSystemProxy: Bool? = nil, message: String? = nil, woke: Bool? = nil, notWoken: String? = nil,
                asleep: Bool? = nil, hosts: [Host]? = nil, failure: String? = nil) {
        self.kind = kind
        self.image = image
        self.fraction = fraction
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.connections = connections
        self.trouble = trouble
        self.troubleDetail = troubleDetail
        self.viaSystemProxy = viaSystemProxy
        self.message = message
        self.woke = woke
        self.notWoken = notWoken
        self.asleep = asleep
        self.hosts = hosts
        self.failure = failure
    }

    /// The kind of a `failed` or `notKept` event's reason; nil when it names none the app knows.
    public var failureKind: VMFailureKind? { failure.flatMap(VMFailureKind.init(rawValue:)) }

    public func line() -> String {
        (try? JSONCoding.encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"kind":"failed"}"#
    }

    /// The event a line of the helper's output is; nil for anything else it printed.
    public static func parse(_ line: String) -> VMHelperEvent? {
        guard line.hasPrefix("{") else { return nil }
        return try? JSONCoding.decoder.decode(VMHelperEvent.self, from: Data(line.utf8))
    }
}

/// Why a machine without a proxy has no way out, as the helper's `traffic` event names it — the
/// kinds of `VMNetDirectConnector.Trouble`, which the app does not link.
public enum VMNetworkTrouble: String, Codable, Sendable, CaseIterable {
    /// This Mac finds no address for the names the machine asks for.
    case nameNotFound
    /// The names resolve, on this Mac, to this Mac itself or a local network.
    case notPublic
    /// The addresses do not take the connections.
    case unreachable
    /// The proxy this Mac's network settings name does not take the connections.
    case proxyUnreachable
    /// That proxy answers, and says no.
    case proxyRefused
    /// This Mac's proxy is set by a configuration file (PAC) or found on the network (WPAD),
    /// which a machine cannot follow: its network stays closed, as for a proxy that is down.
    case proxyConfigurationFile
    /// The machine's own proxy (its profile's) does not answer: down since the start's check, or
    /// no longer at its address. Nothing goes out past it.
    case ownProxyUnreachable
    /// The machine's own proxy refuses its sign-in: the password changed, or the plan ran out.
    case ownProxyLogin
    /// The machine's own proxy answers in another protocol than its entry names.
    case ownProxyNotUnderstood

    /// How many connections must fail one after another, none made since, before the machine is
    /// said to have no way out: a page's one dead address is not that.
    public static let failuresBeforeSaying: UInt64 = 4

    /// A machine with a proxy: what its row and window say once the proxy itself has failed
    /// `failuresInARow` of the guest's connections one after another (`VMNetCounters` in the
    /// helper), with `kind` the network's word for why — `unreachable`, `login`, `notUnderstood`
    /// (`VMNetProxyTrouble`'s raw values). Nil below `failuresBeforeSaying`, and for a kind this
    /// version has no words for. A proxy that says a site cannot be reached is not counted there.
    public static func ofMachineProxy(failuresInARow: UInt64, kind: String?) -> VMNetworkTrouble? {
        guard failuresInARow >= failuresBeforeSaying, let kind else { return nil }
        switch kind {
        case "unreachable": return .ownProxyUnreachable
        case "login": return .ownProxyLogin
        case "notUnderstood": return .ownProxyNotUnderstood
        default: return nil
        }
    }
}

/// What the app writes to the helper after its request, a line each.
public enum VMHelperCommand: Equatable, Sendable {
    /// Close the machine: put it to sleep where the request keeps its state, else shut it down.
    case stop
    /// Shut the machine's macOS down, whatever the request says of its state.
    case shutdown
    /// End the machine now.
    case kill
    /// Say where the machine connects every few seconds (`VMHelperEvent.Kind.hosts`), or stop.
    case hosts(Bool)
    /// Block a host name, and every name under it, from now on.
    case block(String)
    /// Put the guest's front window full screen (the key a person would press for it).
    case fullScreen

    /// The line the helper reads.
    public var line: String {
        switch self {
        case .stop: return "stop"
        case .shutdown: return "shutdown"
        case .kill: return "kill"
        case .hosts(let on): return on ? "hosts on" : "hosts off"
        case .block(let name): return "block " + name
        case .fullScreen: return "fullscreen"
        }
    }

    /// The command a line is; nil for anything else. A name to block must be one the network
    /// would take (`VMProfile.blockedHost`) — whatever else follows the word is no command.
    public init?(line: String) {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        switch (words.first, words.count) {
        case ("stop", 1): self = .stop
        case ("shutdown", 1): self = .shutdown
        case ("kill", 1): self = .kill
        case ("fullscreen", 1): self = .fullScreen
        case ("hosts", 2) where words[1] == "on" || words[1] == "off": self = .hosts(words[1] == "on")
        case ("block", 2):
            guard let name = VMProfile.blockedHost(words[1]), name == words[1] else { return nil }
            self = .block(name)
        default: return nil
        }
    }
}

/// Why a saved state that was there was not used to wake a machine.
public enum VMWakeRefusal: String, Codable, Sendable, CaseIterable {
    /// Saved for other hardware or other settings than this start's: the change must take.
    case changed
    /// Not this disk's any more (the disk was written since), or not a state that reads.
    case stale
    /// The framework did not take it.
    case failed
    /// No state was there to refuse: this machine, as it is made on this Mac, cannot be saved at
    /// all (the framework says so), and is shut down when it is closed.
    case unsupported
}

/// What a saved state goes with, kept beside it (`VMLibrary.MachineFiles.stateInfo`): a state is
/// a machine's memory at one moment, and is good only for the very disk of that moment and the
/// very hardware — woken on a disk that has moved on, its macOS would write what it remembers
/// over what is there.
public struct VMSavedState: Codable, Equatable, Sendable {
    /// One name the machine's network gave a stand-in address for (`VMNetKnownName`): the woken
    /// machine still holds the addresses.
    public struct Name: Codable, Equatable, Sendable {
        public var name: String
        public var address: UInt32

        public init(name: String, address: UInt32) {
            self.name = name
            self.address = address
        }
    }

    /// The request's `stateStamp` when the state was saved.
    public var stamp: String
    /// The disk as it was left when the machine had stopped after the save: its length and when
    /// it was last written (seconds since 1970).
    public var diskLength: Int64
    public var diskModified: Double
    public var savedAt: Date
    public var names: [Name]

    public init(stamp: String, diskLength: Int64, diskModified: Double, savedAt: Date = Date(), names: [Name] = []) {
        self.stamp = stamp
        self.diskLength = diskLength
        self.diskModified = diskModified
        self.savedAt = savedAt
        self.names = names
    }

    /// The disk's length and last write, as a state is tied to them; nil when it cannot be asked.
    public static func mark(ofDisk url: URL) -> (length: Int64, modified: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let length = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        return (length, modified)
    }

    /// Whether a state with this note may wake a machine started by a request stamped `stamp`
    /// whose disk is at `disk` now; and if not, why.
    public func refusal(stamp: String?, disk: URL) -> VMWakeRefusal? {
        guard let stamp, stamp == self.stamp else { return .changed }
        guard let mark = Self.mark(ofDisk: disk), mark.length == diskLength, mark.modified == diskModified else { return .stale }
        return nil
    }

    public static func read(from url: URL) -> VMSavedState? {
        // A note of a megabyte is none: a full pool of names is far below that.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= 8 << 20, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder.decode(VMSavedState.self, from: data)
    }

    public func write(to url: URL) throws {
        try SecureFile.write(try JSONCoding.encoder.encode(self), to: url)
    }
}
