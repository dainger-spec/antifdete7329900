import Foundation

/// What the core's errors carry in detail (`CoreError.io("rename config.bin failed: errno 28")`,
/// `.invalidConfiguration("proxy port out of range")`), said in the person's language.
///
/// The core writes its details in English, for the log. They used to follow the translated sentence
/// in parentheses whatever the interface's language: a Russian window said «Недопустимые настройки
/// (proxy port out of range)», and a failed write «Ошибка чтения или записи (rename … failed: errno
/// 28)» — English, and a system's code, in front of a person who can do nothing with either (a
/// tester, 17 November). Now a detail is said in words of the interface's language when it is one
/// the person can act on (`known`), a system's error number by what it means (`errnoText`), and
/// otherwise not at all: the sentence alone, without the code's words. The log keeps them.
enum ErrorDetailText {
    /// A detail in the interface's language, or nil when it is not one to show.
    static func text(_ detail: String) -> String? {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let known = known(trimmed) { return known }
        if let reason = errnoText(trimmed) { return reason }
        if let network = networkText(trimmed) { return network }
        // A detail the app itself wrote in the interface's language (the editor's own checks pass
        // `L(...)` as the detail): shown as it is.
        if !looksTechnical(trimmed), isInInterfaceLanguage(trimmed) { return trimmed }
        return nil
    }

    /// Whether `text` reads as the interface's language: Russian has Cyrillic in it; English is
    /// the core's own words, shown only when they are not a code's.
    static func isInInterfaceLanguage(_ text: String, language: String = Localization.languageCode) -> Bool {
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return language == "ru" ? cyrillic : !cyrillic
    }

    /// A system's or a program's words: an error number, an error domain, a type's name, a path.
    static func looksTechnical(_ text: String) -> Bool {
        let markers = ["errno", "Error Domain=", "Code=", "NSError", "NSPOSIX", "(error ", "Error(", "Error.", "UserInfo", "0x",
                       "/Users/", "/private/", "/var/", "/tmp/", "Library/", ".bin", ".json", ".plist", "PBSA", "KDF", "Argon2", "PBKDF2"]
        return markers.contains { text.contains($0) }
    }

    /// A system's error number (`errno 28`) as what it means to the person, when it is one they can
    /// do something about.
    static func errnoText(_ detail: String) -> String? {
        guard let range = detail.range(of: #"errno (\d+)"#, options: .regularExpression),
              let code = Int32(detail[range].dropFirst("errno ".count)) else { return nil }
        switch code {
        case ENOSPC, EDQUOT: return L("error.detail.diskFull")
        case EACCES, EPERM: return L("error.detail.noPermission")
        case EROFS: return L("error.detail.readOnly")
        default: return nil
        }
    }

    /// A sync request the network did not carry: the system's own sentence follows, which macOS
    /// says in the interface's language (the process's `AppleLanguages`, `applyProcessLanguage`).
    static func networkText(_ detail: String) -> String? {
        let prefix = "sync request failed: "
        if detail.hasPrefix(prefix) {
            let reason = String(detail.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !reason.isEmpty, !looksTechnical(reason) else { return L("error.detail.syncUnreachable") }
            return String(format: L("error.detail.syncUnreachable.reason"), reason)
        }
        if detail == "sync request returned no HTTP response" { return L("error.detail.syncUnreachable") }
        return nil
    }

    /// The core's details a person can act on, each in the interface's language. A detail with a
    /// number in it is matched by its words, and the number is carried over.
    static func known(_ detail: String) -> String? {
        if let key = exact[detail] { return L(key) }
        for (pattern, key) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)) else { continue }
            let values: [CVarArg] = (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: detail).map { String(detail[$0]) }
            }
            return String(format: L(key), arguments: values)
        }
        return nil
    }

    private static let exact: [String: String] = [
        // The master password, an export's password.
        "empty master password": "error.detail.emptyPassword",
        "an export needs a password": "error.detail.exportPassword",
        // A profile's settings.
        "profile name must be 1–128 characters": "error.detail.profileName",
        "start URL must be http(s) or about:": "error.detail.startURL",
        "user agent must be 1–512 printable ASCII characters": "error.detail.userAgent",
        "history retention must be 1–3650 days": "error.detail.history",
        "a language is a tag such as de-DE": "error.detail.languageTag",
        "the language is not a language tag": "error.detail.languageTag",
        "a Safari version is written like 26.0 or 26.0.1": "error.detail.safariVersion",
        "geolocation out of range": "error.detail.geolocation",
        "unknown time zone": "error.detail.timeZone",
        // A proxy.
        "proxy port out of range": "error.detail.proxyPort",
        "TLS to proxy is only supported for HTTP CONNECT proxies": "error.detail.proxyTLS",
        "proxy username and password must both be set or both empty": "error.detail.proxyCredentials",
        "only a VLESS, VMess, Trojan or Shadowsocks proxy has a link": "error.detail.proxyLinkKind",
        "a VLESS, VMess, Trojan or Shadowsocks proxy needs its link": "error.detail.proxyLinkMissing",
        "the proxy's server is not the one its link names": "error.detail.proxyLinkServer",
        "a link's proxy has its credentials in the link": "error.detail.proxyLinkCredentials",
        "this OpenVPN server asks for a user name and password": "error.detail.openVPNCredentials",
        // Sync to a server of one's own.
        "sync server URL must be absolute": "error.detail.syncURL",
        "sync server URL must use https": "error.detail.syncURLHTTPS",
        "sync server URL must not contain query, fragment or credentials": "error.detail.syncURLParts",
        "not a URL": "error.detail.syncURL",
        // Bookmarks.
        "only http(s) pages can be bookmarked": "error.detail.bookmarkURL",
        "bookmark URL must be http(s)": "error.detail.bookmarkURL",
        "bookmark no longer exists": "error.detail.bookmarkGone",
        "folder name too long": "error.detail.folderName",
        // The camera.
        "camera colour must be written like #1E2130": "error.detail.cameraColour",
        "the camera crop must be inside the source": "error.detail.cameraCrop",
        "a camera filter is out of range": "error.detail.cameraValues",
        "the camera playback is out of range": "error.detail.cameraValues",
        "the camera is set to an image but none was chosen": "error.detail.cameraNoImage",
        "the camera is set to a video but none was chosen": "error.detail.cameraNoVideo",
        // Files brought in.
        "not a Lumen profile export": "error.detail.notAnExport",
        "not a PBSA archive": "error.detail.notAnExport",
        "the profile was brought back already": "error.detail.broughtBack",
        "the profile is being brought back": "error.detail.bringingBack",
        "the profile's password vault is not empty": "error.detail.passwordsNotEmpty",
        // A virtual machine.
        "a virtual machine's name must be 1–64 characters": "error.detail.vmName",
        "a virtual machine cannot use a proxy reached over TLS (an https:// proxy) yet": "error.detail.vmProxyTLS",
        "the start page must be an http or https address": "error.detail.startURL",
        "the computer's name must be 1–40 Latin letters, digits, spaces, hyphens or apostrophes": "error.detail.vmComputerName",
        "the note is too long": "error.detail.noteLength",
        "a blocked name must be a host name such as ads.example.com": "error.detail.blockedName",
        "the network card's address must be six hex bytes, locally administered (02:…)": "error.detail.macAddress",
    ]

    /// Details with a value in them: the pattern, and the key its captures are given to in order.
    private static let patterns: [(String, String)] = [
        (#"^window size must be (\d+)–(\d+) × (\d+)–(\d+) points$"#, "error.detail.windowSize"),
        (#"^proxy host must be a bare host name or IP address, not “(.*)”$"#, "error.detail.proxyHost"),
        (#"^proxy port (-?\d+)$"#, "error.detail.proxyPortValue"),
        (#"^unknown time zone (.+)$"#, "error.detail.timeZoneNamed"),
        (#"^camera resolution must be (\d+)–(\d+) pixels each side$"#, "error.detail.cameraResolution"),
        (#"^camera frame rate must be (\d+)–(\d+) per second$"#, "error.detail.cameraFrameRate"),
        (#"^the camera image is larger than (\d+) MB$"#, "error.detail.cameraImageSize"),
        (#"^the camera video is larger than (\d+) MB$"#, "error.detail.cameraVideoSize"),
        (#"^profile export format (\d+)$"#, "error.detail.newerExport"),
        (#"^proxy list format (\d+)$"#, "error.detail.newerProxyList"),
        (#"^there are (\d+) virtual machines already$"#, "error.detail.vmLimit"),
        (#"^every start page must be an http or https address, and there may be (\d+) of them$"#, "error.detail.vmStartPages"),
    ]
}
