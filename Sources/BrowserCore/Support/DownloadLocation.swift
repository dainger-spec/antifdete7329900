import Foundation

/// Per-profile download folders: `<base>/PrivacyBrowser/<profile name>/<file>`, where the
/// app passes `~/Downloads` as `base`.
///
/// Why a folder per profile: separate work contexts should not mix their files, and the
/// user should be able to tell which context a file came from.
///
/// LIMITATION: downloads are ordinary, unencrypted files outside the profile's encrypted
/// storage. Deleting a profile does not delete them, and encrypting them would make them
/// useless to other apps. In the App Sandbox, writing to `~/Downloads` needs
/// `com.apple.security.files.downloads.read-write`.
///
/// Names are sanitized because both inputs are untrusted: a profile name is free text, and
/// `suggestedFilename` comes from the website (`Content-Disposition`). The result is always a
/// single path component: no `/`, `\`, `:`, control or bidi-override characters, no leading
/// dot (no hidden files, no `..`), no trailing dots or spaces, at most 255 UTF-8 bytes (the
/// APFS/HFS+ component limit).
public enum DownloadLocation {
    /// Used when a profile name sanitizes to nothing.
    public static let fallbackFolderName = "Profile"
    /// Used when a suggested file name sanitizes to nothing.
    public static let fallbackFileName = "download"
    /// Profile folder names are cut to this many characters (grapheme clusters).
    public static let maxFolderNameCharacters = 80
    /// Per-component limit of APFS and HFS+.
    public static let maxComponentBytes = 255

    /// A safe single path component for a profile's download folder.
    ///
    /// Two profiles with the same name share a folder; the app can pass a disambiguated name
    /// if that matters.
    public static func folderName(forProfileName profileName: String) -> String {
        let name = sanitizeComponent(profileName, maxCharacters: maxFolderNameCharacters)
        return name.isEmpty ? fallbackFolderName : name
    }

    /// `base/<appFolderName>/<sanitized profile name>/`. Does not create anything.
    public static func profileFolder(base: URL, appFolderName: String = "PrivacyBrowser", profileName: String) -> URL {
        let app = sanitizeComponent(appFolderName, maxCharacters: maxFolderNameCharacters)
        return base
            .appendingPathComponent(app.isEmpty ? "PrivacyBrowser" : app, isDirectory: true)
            .appendingPathComponent(folderName(forProfileName: profileName), isDirectory: true)
    }

    /// A destination in `folder` for a download that does not collide with an existing file:
    /// `name.ext`, then `name (1).ext`, `name (2).ext`, … A suggested name that already ends in
    /// ` (n)` continues from `n + 1`. Double extensions like `.tar.gz` stay together
    /// (`archive (1).tar.gz`); a "dot" that is not an extension (`Report v1.2 final`) is left
    /// alone (`Report v1.2 final (1)`).
    ///
    /// `fileExists` is injected so that the logic is testable and so that the caller decides
    /// how to probe (the sandboxed app may only see the folder through a security-scoped URL).
    /// Between this check and the write there is an unavoidable race; WebKit fails the download
    /// rather than overwrite if the file appears in the meantime.
    public static func uniqueFileURL(in folder: URL, suggestedFilename: String, fileExists: (URL) -> Bool) -> URL {
        // Not byte-limited yet: an over-long name is shortened in its stem, keeping the extension.
        var name = sanitizeComponent(suggestedFilename, maxCharacters: .max, maxBytes: .max)
        if name.isEmpty { name = fallbackFileName }
        let parts = splitExtension(name)
        let candidate = folder.appendingPathComponent(compose(stem: parts.stem, suffix: "", ext: parts.ext), isDirectory: false)
        guard fileExists(candidate) else { return candidate }

        var stem = parts.stem
        let ext = parts.ext
        var counter = 1
        if let (base, number) = splitCounterSuffix(stem) {
            stem = base
            counter = number &+ 1
        }
        for _ in 0..<10_000 {
            let url = folder.appendingPathComponent(compose(stem: stem, suffix: " (\(counter))", ext: ext), isDirectory: false)
            if !fileExists(url) { return url }
            counter &+= 1
        }
        // Pathological folder: fall back to a random suffix rather than loop forever.
        let random = String(UUID().uuidString.prefix(8))
        return folder.appendingPathComponent(compose(stem: stem, suffix: " (\(random))", ext: ext), isDirectory: false)
    }

    // MARK: Sanitizing

    /// Bidirectional overrides/isolates and marks: they can make `evil\u{202E}fdp.exe` display
    /// as `evilexe.pdf`.
    private static let bidiControls: Set<UInt32> = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                                    0x2066, 0x2067, 0x2068, 0x2069, 0x061C]

    /// Path separators become spaces, whitespace runs collapse to one space, control and bidi
    /// characters are dropped, leading dots/spaces and trailing dots/spaces are trimmed, then
    /// the result is cut to `maxCharacters` and `maxBytes` (UTF-8) on a character boundary.
    static func sanitizeComponent(_ raw: String, maxCharacters: Int, maxBytes: Int = maxComponentBytes) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            let isSeparator = scalar == "/" || scalar == "\\" || scalar == ":"
            if isSeparator || scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            if scalar.properties.generalCategory == .control || bidiControls.contains(scalar.value) {
                continue
            }
            if pendingSpace, !scalars.isEmpty { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        var name = trimmed(String(scalars))
        if name.count > maxCharacters { name = String(name.prefix(maxCharacters)) }
        name = truncated(name, maxBytes: maxBytes)
        return trimmed(name)
    }

    /// Drops leading dots and spaces and trailing dots and spaces, repeatedly (`". .x. ."` → `x`).
    private static func trimmed(_ name: String) -> String {
        var characters = Substring(name)
        while let first = characters.first, first == "." || first == " " { characters.removeFirst() }
        while let last = characters.last, last == "." || last == " " { characters.removeLast() }
        return String(characters)
    }

    /// The longest prefix of whole `Character`s that fits in `maxBytes` UTF-8 bytes.
    static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            if bytes + size > maxBytes { break }
            result.append(character)
            bytes += size
        }
        return result
    }

    // MARK: Name parts

    /// `("archive", "tar.gz")`, `("photo", "JPG")`, `("README", "")`, `("v1.2 final", "")`.
    /// An extension is 1–16 letters/digits after the last dot (plus a preceding `tar.`), with a
    /// non-empty stem.
    static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard (1...16).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return (name, "") }
        let stem = name[..<dot]
        if stem.lowercased().hasSuffix(".tar"), stem.count > 4, ext.count <= 5 {
            let tarDot = stem.index(stem.endIndex, offsetBy: -4)
            return (String(stem[..<tarDot]), String(name[name.index(after: tarDot)...]))
        }
        return (String(stem), String(ext))
    }

    /// `"file (3)"` → `("file", 3)`; anything else → `nil`.
    static func splitCounterSuffix(_ stem: String) -> (String, Int)? {
        guard stem.hasSuffix(")"), let open = stem.range(of: " (", options: .backwards) else { return nil }
        let digits = stem[open.upperBound..<stem.index(before: stem.endIndex)]
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits) else { return nil }
        let base = String(stem[..<open.lowerBound])
        return base.isEmpty ? nil : (base, number)
    }

    /// `stem + suffix + "." + ext`, shortening the stem so the whole fits in 255 UTF-8 bytes.
    private static func compose(stem: String, suffix: String, ext: String) -> String {
        let tail = suffix + (ext.isEmpty ? "" : ".\(ext)")
        let budget = max(1, maxComponentBytes - tail.utf8.count)
        var base = truncated(stem, maxBytes: budget)
        while let last = base.last, last == "." || last == " " { base.removeLast() }
        if base.isEmpty { base = fallbackFileName }
        return base + tail
    }
}
