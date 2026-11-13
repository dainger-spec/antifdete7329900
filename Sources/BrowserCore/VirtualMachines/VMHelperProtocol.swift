import Foundation

/// What the app asks of the machines' helper (`LumenVM`, the one executable that holds Apple's
/// virtualization right), and what the helper says back.
///
/// The request is one JSON line on the helper's standard input — never arguments: it carries the
/// proxy's password — and after it the app may write `stop` (ask the guest to shut down) or `kill`
/// (end it now) as lines of their own. The helper answers with one JSON line per event on its
/// standard output, and ends when the machine has.
public struct VMHelperRequest: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Which macOS Apple offers for this Mac's virtual machines (a `catalog` event, then exit).
        case catalog
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
        /// This Mac's own connection (Apple's NAT): sites see this Mac's address.
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
    /// Names the machine's network answers "no such name" for (`VMRequirements.blockedHosts`).
    public var blockedHosts: [String]
    /// The window's title, and its few words, in the person's language (the helper has no strings
    /// of its own): `stop`, `stopQuestion`, `stopDetail`, `stopNow`, `cancel`, `stopping` — and
    /// `hint`, a line shown above the machine's screen (what is left to do in the base).
    public var windowTitle: String
    public var texts: [String: String]

    public init(mode: Mode, restoreImagePath: String? = nil, machineDirectory: String? = nil, baseDirectory: String? = nil,
                cores: Int = 4, memoryBytes: Int64 = 4 << 30, diskBytes: Int64 = VMRequirements.diskImageBytes,
                display: Display = Display(VMDisplay.standard), macAddress: String? = nil, network: Network = .closed,
                proxy: ProxySettings? = nil, blockedHosts: [String] = [],
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
        self.windowTitle = windowTitle
        self.texts = texts
    }

    /// The request to start a profile's machine. A profile with a proxy never gets the direct
    /// network: without a usable proxy it is closed.
    public static func run(profile: VMProfile, library: VMLibrary, hostCores: Int, texts: [String: String]) -> VMHelperRequest {
        VMHelperRequest(mode: .run, machineDirectory: library.machineDirectory(for: profile.id).path,
                        baseDirectory: library.baseDirectory.path,
                        cores: VMRequirements.cores(hostCores: hostCores),
                        memoryBytes: Int64(profile.memoryGB) * VMRequirements.gibibyte,
                        display: Display(profile.display), macAddress: profile.macAddress,
                        network: profile.proxy == nil ? .direct : .proxy, proxy: profile.proxy,
                        blockedHosts: VMRequirements.blockedHosts, windowTitle: profile.name, texts: texts)
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
    /// `failed`: why, in the system's own words (shown to the person as given).
    public var message: String?

    public init(kind: Kind, image: VMRestoreImage? = nil, fraction: Double? = nil, bytesUp: UInt64? = nil,
                bytesDown: UInt64? = nil, connections: Int? = nil, message: String? = nil) {
        self.kind = kind
        self.image = image
        self.fraction = fraction
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.connections = connections
        self.message = message
    }

    public func line() -> String {
        (try? JSONCoding.encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"kind":"failed"}"#
    }

    /// The event a line of the helper's output is; nil for anything else it printed.
    public static func parse(_ line: String) -> VMHelperEvent? {
        guard line.hasPrefix("{") else { return nil }
        return try? JSONCoding.decoder.decode(VMHelperEvent.self, from: Data(line.utf8))
    }
}
