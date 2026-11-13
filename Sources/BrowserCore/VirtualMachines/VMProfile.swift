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

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), lastLaunchedAt: Date? = nil,
                proxy: ProxySettings? = nil, timeZoneIdentifier: String? = nil, language: String? = nil,
                countryCode: String? = nil, localeFollowsProxy: Bool = true,
                displayID: String = VMDisplay.standard.id, memoryGB: Int = VMRequirements.standardMemoryGB,
                macAddress: String = VMProfile.randomMACAddress(), startURL: String? = nil, notes: String = "",
                cores: Int? = nil, soundEnabled: Bool = true, appearance: String? = nil, accent: String? = nil,
                computerName: String? = nil, opensSafari: Bool = true, colorIndex: Int? = nil, lumenWallpaper: Bool = true) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, lastLaunchedAt, proxy, timeZoneIdentifier, language, countryCode, localeFollowsProxy,
             displayID, memoryGB, macAddress, startURL, notes, cores, soundEnabled, appearance, accent, computerName,
             opensSafari, colorIndex, lumenWallpaper
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
    }

    /// The profile with its time zone, language and country taken from where its proxy came out
    /// (the proxy's last check in the list), when they follow the proxy and the check knows them;
    /// otherwise as it is.
    public func followingProxy(check: ProxyCheckResult?) -> VMProfile {
        guard localeFollowsProxy, proxy != nil, let check, check.isAlive else { return self }
        var updated = self
        if let zone = check.timeZoneIdentifier, VMGuestSettings.isTimeZone(zone) { updated.timeZoneIdentifier = zone }
        if let country = check.countryCode?.uppercased() {
            updated.countryCode = country
            if let language = ProxyLocation.webLanguages[country] { updated.language = language }
        }
        return updated
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
