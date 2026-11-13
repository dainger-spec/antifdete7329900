import Foundation

/// What the app tells a machine's macOS before it starts, and what the guest tells back: two small
/// text files in the folder the machine shares with the app (`VMLibrary.shareDirectory`), read and
/// written inside the guest by its boot script (Resources/VMGuest/lumen-guest.sh), which runs as
/// root.
///
/// Because a root script reads it, the file is as plain as a file gets — `KEY=value` lines — and
/// every value is checked here against what it may be before it is written: a time zone is a time
/// zone, a language a language tag, the start page an http(s) address with nothing a shell could
/// take for more. The script never evaluates a line; it only compares keys and uses values as
/// arguments.
public struct VMGuestSettings: Equatable, Sendable {
    /// Changes whenever anything below does: the guest applies a revision once.
    public var revision: String
    public var timeZone: String?
    /// BCP 47 ("de-DE"); the locale ("de_DE") is made from it.
    public var language: String?
    public var hostName: String
    public var startURL: String?
    /// The computer's name as the person wrote it ("Anna's MacBook Air"); the host name is made
    /// from it. Nil: the host name stands for both. (Tools 2.)
    public var computerName: String?
    /// The system's appearance and accent colour. Nil: left as they are. (Tools 2.)
    public var appearance: VMAppearance?
    public var accent: VMAccent?
    /// Safari is opened when the machine has started. (Tools 2; before them it always is.)
    public var opensSafari: Bool
    /// The desktop picture is the one the app left beside this file (`wallpaperFileName`). (Tools 3.)
    public var wallpaper: Bool

    public init(timeZone: String?, language: String?, hostName: String, startURL: String?, computerName: String? = nil,
                appearance: VMAppearance? = nil, accent: VMAccent? = nil, opensSafari: Bool = true, wallpaper: Bool = false) {
        self.timeZone = timeZone.flatMap { Self.isTimeZone($0) ? $0 : nil }
        self.language = language.flatMap { LocalePlaces.isLanguageTag($0) ? $0 : nil }
        self.computerName = computerName.flatMap(Self.computerName)
        // A computer's own name names its host too: "Anna's MacBook Air" is "Annas-MacBook-Air".
        self.hostName = Self.hostName(self.computerName.map { $0.replacingOccurrences(of: " ", with: "-") } ?? hostName)
        self.startURL = startURL.flatMap(Self.startURL)
        self.appearance = appearance
        self.accent = accent
        self.opensSafari = opensSafari
        self.wallpaper = wallpaper
        revision = ""
        revision = Self.revision(of: lines(withRevision: false))
    }

    /// The settings a profile's machine starts with.
    public init(profile: VMProfile) {
        self.init(timeZone: profile.timeZoneIdentifier, language: profile.language,
                  hostName: profile.display.id.hasPrefix("macbook-air") ? "MacBook-Air"
                      : profile.display.id.hasPrefix("macbook-pro") ? "MacBook-Pro"
                      : profile.display.id.hasPrefix("imac") ? "iMac" : "Mac-mini",
                  startURL: profile.startURL, computerName: profile.computerName,
                  appearance: profile.appearance.flatMap(VMAppearance.init(rawValue:)),
                  accent: profile.accent.flatMap(VMAccent.init(rawValue:)), opensSafari: profile.opensSafari,
                  wallpaper: profile.lumenWallpaper)
    }

    public static let fileName = "lumen-settings.env"
    public static let statusFileName = "lumen-status.env"
    /// Lumen's desktop picture for the machine's screen, which the app draws and leaves in the
    /// shared folder; the boot script sets it when `LUMEN_WALLPAPER` is 1.
    public static let wallpaperFileName = "lumen-wallpaper.png"

    /// The file's text.
    public var text: String { lines(withRevision: true).joined(separator: "\n") + "\n" }

    private func lines(withRevision: Bool) -> [String] {
        var lines: [String] = []
        if withRevision { lines.append("LUMEN_REVISION=\(revision)") }
        if let timeZone { lines.append("LUMEN_TIMEZONE=\(timeZone)") }
        if let language {
            lines.append("LUMEN_LANGUAGE=\(language)")
            lines.append("LUMEN_LOCALE=\(Self.locale(for: language))")
        }
        lines.append("LUMEN_HOSTNAME=\(hostName)")
        if let computerName { lines.append("LUMEN_COMPUTER_NAME=\(computerName)") }
        if let appearance { lines.append("LUMEN_APPEARANCE=\(appearance.rawValue)") }
        if let accent { lines.append("LUMEN_ACCENT=\(accent.number.map(String.init) ?? VMAccent.multicolor.rawValue)") }
        lines.append("LUMEN_OPEN_SAFARI=\(opensSafari ? 1 : 0)")
        lines.append("LUMEN_WALLPAPER=\(wallpaper ? 1 : 0)")
        if let startURL { lines.append("LUMEN_START_URL=\(startURL)") }
        return lines
    }

    /// A short, stable name for a set of lines (FNV-1a, 64 bits, in hex): not a secret, only "has
    /// this changed".
    static func revision(of lines: [String]) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in lines.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// An IANA time zone as its name is written — letters, digits, `_`, `+`, `-` and `/` between
    /// parts ("America/Argentina/Buenos_Aires", "Etc/GMT+3") — and one this system knows.
    public static func isTimeZone(_ text: String) -> Bool {
        guard (1...64).contains(text.count), !text.hasPrefix("/"), !text.hasSuffix("/"), !text.contains("//"), !text.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-/")
        guard text.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return TimeZone(identifier: text) != nil
    }

    /// "de-DE" → "de_DE"; "en" → "en"; a script tag is left out ("zh-Hant-TW" → "zh_TW").
    public static func locale(for language: String) -> String {
        let parts = language.split(separator: "-").map(String.init)
        guard let first = parts.first else { return language }
        if let region = parts.dropFirst().last(where: { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }) {
            return first.lowercased() + "_" + region.uppercased()
        }
        return first.lowercased()
    }

    /// A host name as macOS takes one: letters, digits and hyphens, 1–32, no hyphen at an end.
    public static func hostName(_ text: String) -> String {
        let kept = String(text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }.map(Character.init))
        let trimmed = String(kept.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    /// A computer's name the script may hand to `scutil`: 1–40 Latin letters, digits, spaces,
    /// hyphens and apostrophes ("Anna's MacBook Air"), nothing else — a quote, a dollar sign or a
    /// letter of another script is refused rather than cleaned (the person sees what was kept).
    public static func computerName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(trimmed.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -'")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains), !trimmed.contains("  ") else { return nil }
        return trimmed
    }

    /// The start page as the guest is given it: an http(s) address, written by `URLComponents` (so
    /// percent-encoded), at most 2000 characters, and with none of the characters a shell or a
    /// `KEY=value` line gives a meaning to. Nil for anything else.
    public static func startURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
              let written = components.url?.absoluteString, written.count <= 2000 else { return nil }
        let refused = CharacterSet(charactersIn: " \t\r\n\"'`$;|<>(){}!*").union(CharacterSet(charactersIn: "\u{5C}"))
        guard written.unicodeScalars.allSatisfy({ $0.isASCII && !refused.contains($0) && $0.value >= 0x21 }) else { return nil }
        return written
    }
}

/// What the guest's script wrote back (`lumen-status.env`): its version, the system's, and which
/// settings it has applied. Read tolerantly: unknown keys are ignored, a value is only ever shown
/// or compared.
public struct VMGuestStatus: Equatable, Sendable {
    public var toolsVersion: Int?
    public var systemVersion: String?
    public var systemBuild: String?
    public var safariVersion: String?
    public var appliedRevision: String?
    /// What came of Lumen's desktop picture (tools 4): "off", "none" (no picture in the shared
    /// folder), "set", "kept" (set at an earlier start and left alone since) or "failed".
    public var wallpaperState: String?
    /// With "failed": what the guest's system said, as it said it.
    public var wallpaperNote: String?
    /// The one-time setup inside the guest has finished (the installer's last line).
    public var setupDone: Bool

    /// The guest could not put Lumen's picture on its desktop.
    public var wallpaperFailed: Bool { wallpaperState == "failed" }

    public init(text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).prefix(64) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...]).prefix(120)
            // Shown to the person: printable ASCII only.
            guard value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }) else { continue }
            values[key] = String(value)
        }
        toolsVersion = values["LUMEN_TOOLS_VERSION"].flatMap(Int.init)
        systemVersion = values["LUMEN_MACOS_VERSION"]
        systemBuild = values["LUMEN_MACOS_BUILD"]
        safariVersion = values["LUMEN_SAFARI_VERSION"]
        appliedRevision = values["LUMEN_APPLIED_REVISION"]
        wallpaperState = values["LUMEN_WALLPAPER_STATE"]
        wallpaperNote = values["LUMEN_WALLPAPER_NOTE"]
        setupDone = values["LUMEN_SETUP_DONE"] == "1"
    }
}
