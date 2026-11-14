import Foundation

/// A profile that is a whole Mac: its own macOS in a virtual machine, with the real Safari in it.
///
/// Where an ordinary profile is a set of website data inside one macOS — this Mac's — a virtual
/// machine's profile has a system of its own: its own disk, keychain, caches, DNS cache, serial
/// number and network card. Nothing of it is in the same operating system as another profile, and
/// nothing a page reads is changed by a script: the time zone and the language are the guest
/// system's own settings (docs/VM.md).
///
/// The price is the machine: gigabytes of disk and of memory per profile, a start measured in
/// tens of seconds, and Apple's limit of two macOS virtual machines running at once on one Mac.
///
/// Kept in `vms.bin` at the vault's root (`VMProfiles`), encrypted like the proxy list: this Mac's,
/// never synced, not in a profile's export. The machine itself — its disk — is in the library
/// (`VMLibrary`), which is not encrypted by the vault (docs/VM.md says so, and why).
public struct VMProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var lastLaunchedAt: Date?
    /// The proxy the whole machine goes out through — every connection of the guest system, not
    /// only Safari's (`VMNetCore`). Nil: this Mac's own connection (NAT), sites see this Mac's IP.
    public var proxy: ProxySettings?
    /// The guest system's time zone (IANA) and language (BCP 47), which Safari in it reports as
    /// any Mac's Safari does. Nil: left as the base system has them.
    public var timeZoneIdentifier: String?
    public var language: String?
    /// Where the proxy came out when the profile was last saved with it (ISO 3166-1 alpha-2), for
    /// the list to show; the time zone and language above were taken from it when they follow it.
    public var countryCode: String?
    /// The time zone and language follow the proxy's country (set from the proxy's last check when
    /// the profile is saved). False: the person's own choice above.
    public var localeFollowsProxy: Bool
    /// The screen the guest has (`VMDisplay.presets`, by id): a real Mac's, since a page reads it.
    public var displayID: String
    /// Memory of the machine, GiB (`VMRequirements.memoryChoices`).
    public var memoryGB: Int
    /// The network card's address: its own, so two machines never share one.
    public var macAddress: String
    /// The page Safari opens when the machine has started. Nil: Safari as it was left.
    public var startURL: String?
    public var notes: String
    /// The machine's processors. Nil: as a Mac has them (`VMRequirements.coresWanted` — Safari
    /// tells a page at most eight). Fewer spare this Mac, and are fewer than any Mac of today has.
    public var cores: Int?
    /// What the guest plays is heard on this Mac. Off: the machine still has its speakers (a Mac
    /// without any is not one), and nothing comes out of them.
    public var soundEnabled: Bool
    /// The guest system's appearance, which a page reads (`prefers-color-scheme`): `VMAppearance`'s
    /// raw value. Nil: as the base system has it.
    public var appearance: String?
    /// The guest system's accent colour — and with it the colour of selected text —
    /// (`VMAccent`'s raw value). Nil: as the base system has it. A new machine gets one at
    /// random, as Macs differ in it.
    public var accent: String?
    /// The computer's name in the guest ("Anna's MacBook Air"). Nil: by the Mac its screen is.
    public var computerName: String?
    /// Safari opens when the machine has started.
    public var opensSafari: Bool
    /// The machine's colour in the list (an index into the profiles' palette). Nil: by its id.
    public var colorIndex: Int?
    /// The machine's desktop picture is Lumen's, drawn by the app for its screen (tools 3). Off:
    /// the picture is left as it is in the machine.
    public var lumenWallpaper: Bool
    /// The region of the guest system's formats — dates, numbers, the week — where it is not the
    /// language's own: English as someone in Germany has it is "en" with "DE". ISO 3166, two
    /// letters. Nil: the language's own. Used when the language is set by hand.
    public var regionCode: String?
    /// The clock: `VMHourCycle`'s raw value, "12" or "24". Nil: left as the system has it.
    public var hourCycle: String?
    /// The first day of the week, 1 (Sunday) … 7 (Saturday). Nil: left as the system has it.
    public var firstWeekday: Int?
    /// Where the Dock is (`VMDockPosition`), whether it hides itself, and its size (`VMDockSize`).
    /// Each nil: left as it is. A page reads what the Dock leaves of the screen (`screen.avail…`).
    public var dockPosition: String?
    public var dockAutohide: Bool?
    public var dockSize: String?
    /// When scroll bars show (`VMScrollBars`). Nil: left to the system, which decides by the
    /// pointing device — and a machine's is a mouse to it, so its bars always show and take a
    /// page's width, where a MacBook's, with its trackpad, show only while scrolling.
    public var scrollBars: String?
    /// More pages Safari opens at start, after `startURL` (at most `VMProfile.moreStartURLsLimit`).
    public var moreStartURLs: [String]
    /// Names the machine's network answers "no such name" for — a name itself and every name
    /// under it — beside the app's own list (`VMRequirements.blockedHosts`).
    public var blockedHosts: [String]
    /// The machine's window opens full screen.
    public var startsFullScreen: Bool
    /// A machine without a proxy: its time zone and language follow where this Mac's own
    /// connection comes out (its VPN, when one is on), found at every start. The person's own
    /// choice, off unless made: finding it is a request from this Mac to a service that says where
    /// an address is. Off: the Mac's time zone and the base system's language (or set by hand,
    /// `localeFollowsProxy` off). With a proxy it means nothing: `localeFollowsProxy` does.
    public var localeFollowsConnection: Bool

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), lastLaunchedAt: Date? = nil,
                proxy: ProxySettings? = nil, timeZoneIdentifier: String? = nil, language: String? = nil,
                countryCode: String? = nil, localeFollowsProxy: Bool = true,
                displayID: String = VMDisplay.standard.id, memoryGB: Int = VMRequirements.standardMemoryGB,
                macAddress: String = VMProfile.randomMACAddress(), startURL: String? = nil, notes: String = "",
                cores: Int? = nil, soundEnabled: Bool = true, appearance: String? = nil, accent: String? = nil,
                computerName: String? = nil, opensSafari: Bool = true, colorIndex: Int? = nil, lumenWallpaper: Bool = true,
                regionCode: String? = nil, hourCycle: String? = nil, firstWeekday: Int? = nil, dockPosition: String? = nil,
                dockAutohide: Bool? = nil, dockSize: String? = nil, scrollBars: String? = nil, moreStartURLs: [String] = [],
                blockedHosts: [String] = [], startsFullScreen: Bool = false, localeFollowsConnection: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
        self.proxy = proxy
        self.timeZoneIdentifier = timeZoneIdentifier
        self.language = language
        self.countryCode = countryCode
        self.localeFollowsProxy = localeFollowsProxy
        self.displayID = displayID
        self.memoryGB = memoryGB
        self.macAddress = macAddress
        self.startURL = startURL
        self.notes = notes
        self.cores = cores
        self.soundEnabled = soundEnabled
        self.appearance = appearance
        self.accent = accent
        self.computerName = computerName
        self.opensSafari = opensSafari
        self.colorIndex = colorIndex
        self.lumenWallpaper = lumenWallpaper
        self.regionCode = regionCode
        self.hourCycle = hourCycle
        self.firstWeekday = firstWeekday
        self.dockPosition = dockPosition
        self.dockAutohide = dockAutohide
        self.dockSize = dockSize
        self.scrollBars = scrollBars
        self.moreStartURLs = moreStartURLs
        self.blockedHosts = blockedHosts
        self.startsFullScreen = startsFullScreen
        self.localeFollowsConnection = localeFollowsConnection
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, lastLaunchedAt, proxy, timeZoneIdentifier, language, countryCode, localeFollowsProxy,
             displayID, memoryGB, macAddress, startURL, notes, cores, soundEnabled, appearance, accent, computerName,
             opensSafari, colorIndex, lumenWallpaper, regionCode, hourCycle, firstWeekday, dockPosition, dockAutohide, dockSize,
             scrollBars, moreStartURLs, blockedHosts, startsFullScreen, localeFollowsConnection
    }

    /// Tolerant of what a later version adds or an earlier one lacked: defaults for what is absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        lastLaunchedAt = try c.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
        proxy = try c.decodeIfPresent(ProxySettings.self, forKey: .proxy)
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        localeFollowsProxy = try c.decodeIfPresent(Bool.self, forKey: .localeFollowsProxy) ?? true
        displayID = try c.decodeIfPresent(String.self, forKey: .displayID) ?? VMDisplay.standard.id
        memoryGB = try c.decodeIfPresent(Int.self, forKey: .memoryGB) ?? VMRequirements.standardMemoryGB
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? VMProfile.randomMACAddress()
        startURL = try c.decodeIfPresent(String.self, forKey: .startURL)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        // What a list of before these settings does not have: as a machine was then.
        cores = try c.decodeIfPresent(Int.self, forKey: .cores)
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance)
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        computerName = try c.decodeIfPresent(String.self, forKey: .computerName)
        opensSafari = try c.decodeIfPresent(Bool.self, forKey: .opensSafari) ?? true
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
        lumenWallpaper = try c.decodeIfPresent(Bool.self, forKey: .lumenWallpaper) ?? true
        regionCode = try c.decodeIfPresent(String.self, forKey: .regionCode)
        hourCycle = try c.decodeIfPresent(String.self, forKey: .hourCycle)
        firstWeekday = try c.decodeIfPresent(Int.self, forKey: .firstWeekday)
        dockPosition = try c.decodeIfPresent(String.self, forKey: .dockPosition)
        dockAutohide = try c.decodeIfPresent(Bool.self, forKey: .dockAutohide)
        dockSize = try c.decodeIfPresent(String.self, forKey: .dockSize)
        scrollBars = try c.decodeIfPresent(String.self, forKey: .scrollBars)
        moreStartURLs = try c.decodeIfPresent([String].self, forKey: .moreStartURLs) ?? []
        blockedHosts = try c.decodeIfPresent([String].self, forKey: .blockedHosts) ?? []
        startsFullScreen = try c.decodeIfPresent(Bool.self, forKey: .startsFullScreen) ?? false
        localeFollowsConnection = try c.decodeIfPresent(Bool.self, forKey: .localeFollowsConnection) ?? false
    }

    /// How many pages Safari may be told to open at start beside the first.
    public static let moreStartURLsLimit = 5
    /// How many names of its own a machine may have blocked.
    public static let blockedHostsLimit = 200

    /// A name to block as the network takes one: lowercase, without a leading "*." or dot, made
    /// of labels of letters, digits and hyphens with a dot between them ("ads.example.com").
    /// Nil for anything else — an address, a name without a dot, a URL.
    public static func blockedHost(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("*.") { name.removeFirst(2) }
        while name.hasPrefix(".") { name.removeFirst() }
        while name.hasSuffix(".") { name.removeLast() }
        guard (3...253).contains(name.utf8.count) else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.unicodeScalars.allSatisfy(allowed.contains),
                  !label.hasPrefix("-"), !label.hasSuffix("-") else { return nil }
        }
        // Four numbers are an address, not a name.
        guard !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return name
    }

    /// A network card's address as a machine may have one: six bytes in hex with colons, the
    /// first marking it locally administered and not a group's ("02:…", "06:…", "0a:…", "0e:…").
    public static func isMACAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }),
              let first = UInt8(parts[0], radix: 16) else { return false }
        return first & 0x02 != 0 && first & 0x01 == 0
    }

    /// The screen, as one of the presets (an id this version does not know: the standard one).
    public var display: VMDisplay { VMDisplay.preset(displayID) }

    /// A network card's address of the machine's own: random, marked locally administered and
    /// unicast (the second-lowest bit of the first byte set, the lowest clear), as Apple's
    /// framework makes them — no page can read it; it only has to differ between machines.
    public static func randomMACAddress() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomMACAddress(using: &generator)
    }

    public static func randomMACAddress<G: RandomNumberGenerator>(using generator: inout G) -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255, using: &generator) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// The name as kept: one line, 1–64 characters.
    public static func validatedName(_ name: String) throws -> String {
        let line = name.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else {
            throw CoreError.invalidConfiguration("a virtual machine's name must be 1–64 characters")
        }
        return trimmed
    }

    /// What must hold before the profile is saved: a name, a usable proxy (TLS to the proxy itself
    /// is not carried by the machine's network yet, `VMNetCore`), a known time zone, a language tag,
    /// an http(s) start page.
    public func validate() throws {
        _ = try Self.validatedName(name)
        if let proxy {
            try proxy.validate()
            if proxy.tlsToProxy {
                throw CoreError.invalidConfiguration("a virtual machine cannot use a proxy reached over TLS (an https:// proxy) yet")
            }
        }
        if let timeZoneIdentifier, !VMGuestSettings.isTimeZone(timeZoneIdentifier) {
            throw CoreError.invalidConfiguration("unknown time zone")
        }
        if let language, !LocalePlaces.isLanguageTag(language) {
            throw CoreError.invalidConfiguration("the language is not a language tag")
        }
        if let startURL, VMGuestSettings.startURL(startURL) == nil {
            throw CoreError.invalidConfiguration("the start page must be an http or https address")
        }
        guard VMRequirements.memoryChoices.contains(memoryGB) else {
            throw CoreError.invalidConfiguration("memory out of range")
        }
        if let cores, !VMRequirements.coreChoices.contains(cores) {
            throw CoreError.invalidConfiguration("processors out of range")
        }
        if let appearance, VMAppearance(rawValue: appearance) == nil {
            throw CoreError.invalidConfiguration("unknown appearance")
        }
        if let accent, VMAccent(rawValue: accent) == nil {
            throw CoreError.invalidConfiguration("unknown accent colour")
        }
        if let computerName, VMGuestSettings.computerName(computerName) == nil {
            throw CoreError.invalidConfiguration("the computer's name must be 1–40 Latin letters, digits, spaces, hyphens or apostrophes")
        }
        if notes.count > 2000 {
            throw CoreError.invalidConfiguration("the note is too long")
        }
        if let regionCode, !(regionCode.count == 2 && regionCode.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }) {
            throw CoreError.invalidConfiguration("the region must be a country's two letters")
        }
        if let hourCycle, VMHourCycle(rawValue: hourCycle) == nil {
            throw CoreError.invalidConfiguration("the clock is 12 or 24 hours")
        }
        if let firstWeekday, !(1...7).contains(firstWeekday) {
            throw CoreError.invalidConfiguration("the first day of the week is 1 to 7")
        }
        if let dockPosition, VMDockPosition(rawValue: dockPosition) == nil {
            throw CoreError.invalidConfiguration("unknown Dock position")
        }
        if let dockSize, VMDockSize(rawValue: dockSize) == nil {
            throw CoreError.invalidConfiguration("unknown Dock size")
        }
        if let scrollBars, VMScrollBars(rawValue: scrollBars) == nil {
            throw CoreError.invalidConfiguration("unknown scroll bar setting")
        }
        guard moreStartURLs.count <= Self.moreStartURLsLimit, moreStartURLs.allSatisfy({ VMGuestSettings.startURL($0) != nil }) else {
            throw CoreError.invalidConfiguration("every start page must be an http or https address, and there may be \(Self.moreStartURLsLimit + 1) of them")
        }
        guard blockedHosts.count <= Self.blockedHostsLimit, blockedHosts.allSatisfy({ Self.blockedHost($0) == $0 }) else {
            throw CoreError.invalidConfiguration("a blocked name must be a host name such as ads.example.com")
        }
        guard Self.isMACAddress(macAddress) else {
            throw CoreError.invalidConfiguration("the network card's address must be six hex bytes, locally administered (02:…)")
        }
    }

    /// The profile with its time zone, language and country taken from where its proxy came out
    /// (the proxy's last check in the list), when they follow the proxy and the check knows them;
    /// otherwise as it is.
    public func followingProxy(check: ProxyCheckResult?) -> VMProfile {
        guard localeFollowsProxy, proxy != nil, let check, check.isAlive else { return self }
        return taking(check)
    }

    /// The same for a machine without a proxy whose time zone and language the person has said
    /// follow this Mac's own connection (`localeFollowsConnection`): `exit` is where that
    /// connection came out. Otherwise — a proxy, the choice not made, set by hand, or nothing
    /// found — as it is.
    public func followingConnection(exit: ProxyCheckResult?) -> VMProfile {
        guard proxy == nil, localeFollowsProxy, localeFollowsConnection, let exit, exit.isAlive else { return self }
        return taking(exit)
    }

    /// Whether this machine's time zone and language are to be found from this Mac's connection
    /// before it starts.
    public var asksWhereTheConnectionComesOut: Bool { proxy == nil && localeFollowsProxy && localeFollowsConnection }

    private func taking(_ check: ProxyCheckResult) -> VMProfile {
        var updated = self
        if let zone = check.timeZoneIdentifier, VMGuestSettings.isTimeZone(zone) { updated.timeZoneIdentifier = zone }
        if let country = check.countryCode?.uppercased() {
            updated.countryCode = country
            if let language = ProxyLocation.webLanguages[country] { updated.language = language }
        }
        return updated
    }
}

/// The guest system's clock.
public enum VMHourCycle: String, CaseIterable, Sendable {
    case twelve = "12"
    case twentyFour = "24"
}

/// Where the guest's Dock is.
public enum VMDockPosition: String, CaseIterable, Sendable {
    case bottom, left, right
}

/// The guest's Dock's size; `tileSize` is macOS's own number for it (`tilesize`, in points).
public enum VMDockSize: String, CaseIterable, Sendable {
    case small, medium, large

    public var tileSize: Int {
        switch self {
        case .small: return 36
        case .medium: return 52
        case .large: return 72
        }
    }
}

/// When the guest's scroll bars show, as System Settings › Appearance has it; `systemName` is
/// macOS's own word for it (`AppleShowScrollBars`).
public enum VMScrollBars: String, CaseIterable, Sendable {
    /// By the pointing device: with a mouse always, with a trackpad while scrolling.
    case automatic
    case whenScrolling
    case always

    public var systemName: String {
        switch self {
        case .automatic: return "Automatic"
        case .whenScrolling: return "WhenScrolling"
        case .always: return "Always"
        }
    }

    /// What a new machine gets: a MacBook has a trackpad, and its bars show only while scrolling —
    /// a machine left to the system would show them always, as no MacBook does. A desktop Mac's
    /// are left to the system (a mouse: always).
    public static func standard(for display: VMDisplay) -> VMScrollBars? {
        display.id.hasPrefix("macbook") ? .whenScrolling : nil
    }
}

/// The guest system's appearance: what a page reads as `prefers-color-scheme`.
public enum VMAppearance: String, CaseIterable, Sendable {
    case light, dark
    /// Light by day, dark by night, as macOS's "Auto".
    case auto
}

/// The guest system's accent colour, as System Settings › Appearance offers them. The raw value
/// is what the boot script is told; `number` is macOS's own (`AppleAccentColor`).
public enum VMAccent: String, CaseIterable, Sendable {
    /// macOS's default: each app's own colour (no `AppleAccentColor` at all).
    case multicolor = "multi"
    case blue, purple, pink, red, orange, yellow, green, graphite

    /// `AppleAccentColor`; nil for multicolour, which is the key's absence.
    public var number: Int? {
        switch self {
        case .multicolor: return nil
        case .graphite: return -1
        case .red: return 0
        case .orange: return 1
        case .yellow: return 2
        case .green: return 3
        case .blue: return 4
        case .purple: return 5
        case .pink: return 6
        }
    }

    /// An accent for a new machine: macOS's default for about two machines in five, as most Macs
    /// keep it, and one of the others for the rest.
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> VMAccent {
        if Int.random(in: 0..<5, using: &generator) < 2 { return .multicolor }
        let others = allCases.filter { $0 != .multicolor }
        return others[Int.random(in: 0..<others.count, using: &generator)]
    }

    public static func random() -> VMAccent {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }
}

/// The virtual machines' profiles of this Mac: `vms.bin` at the vault's root, AES-GCM under
/// `HKDF(VMK, "virtual-machines")`, AAD `virtual-machines:v1:<vaultID>`.
public struct VMProfiles: Codable, Equatable, Sendable {
    /// More than a disk holds.
    public static let maximumProfiles = 200
    static let supportedFormat = 1

    public private(set) var profiles: [VMProfile]

    public init(profiles: [VMProfile] = []) {
        self.profiles = profiles
    }

    public func profile(_ id: UUID) -> VMProfile? { profiles.first { $0.id == id } }

    /// Adds or replaces the profile (by id), validated. A new one over the limit is refused.
    public mutating func save(_ profile: VMProfile) throws {
        try profile.validate()
        var kept = profile
        kept.name = try VMProfile.validatedName(profile.name)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = kept
        } else {
            guard profiles.count < Self.maximumProfiles else {
                throw CoreError.invalidConfiguration("there are \(Self.maximumProfiles) virtual machines already")
            }
            // Two machines never share a network card's address.
            while profiles.contains(where: { $0.macAddress.lowercased() == kept.macAddress.lowercased() }) {
                kept.macAddress = VMProfile.randomMACAddress()
            }
            profiles.append(kept)
        }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> VMProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return profiles.remove(at: index)
    }

    public mutating func markLaunched(_ id: UUID, at date: Date = Date()) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastLaunchedAt = date
    }

    private enum CodingKeys: String, CodingKey { case format, profiles }

    /// Tolerant: a profile that does not decode (a later version's) is left out rather than
    /// costing the list — and the file is then that later version's, refused before this by its
    /// format (`EncryptedDocumentFile.supportedFormat`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var list = try c.nestedUnkeyedContainer(forKey: .profiles)
        var profiles: [VMProfile] = []
        while !list.isAtEnd {
            if let profile = try? list.decode(VMProfile.self) {
                profiles.append(profile)
            } else {
                _ = try list.decode(Skipped.self)
            }
        }
        self.profiles = profiles
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.supportedFormat, forKey: .format)
        try c.encode(profiles, forKey: .profiles)
    }

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension VMProfiles {
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<VMProfiles> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("vms.bin"), key: try vault.virtualMachinesKey,
                              aad: "virtual-machines:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
    }

    /// The vault's virtual machines; none before the first was made. Throws for a copy that does
    /// not open, and for a newer version's (`CoreError.newerFormat`).
    public static func load(from vault: UnlockedVault) throws -> VMProfiles {
        try file(for: vault).load() ?? VMProfiles()
    }

    /// Writes them — never over a newer version's copy, nor over one that does not open (moved
    /// aside as `vms.bin.unreadable` first).
    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}
