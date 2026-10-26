import Foundation

/// A small, thread-safe, rotating file log behind the app's "Show Log" command.
///
/// Why a file and not only `os_log`: Console.app is not something a user can be asked to
/// attach to a bug report, and unified logging redacts dynamic strings in release builds.
/// A plain text file that the app can reveal in Finder ("Показать лог") is.
///
/// **Privacy contract.** The log never contains page URLs, cookies, passwords or proxy
/// credentials. Callers log *events* ("profile started", "proxy check failed: NSURLErrorDomain
/// -1004"), describe any URL with `describe(url:)` (scheme and host only), and never pass
/// page content, headers or form values. As a safety net every message also goes through
/// `redact(_:)`, which masks `user:password@` in URLs and `password=`/`token=`-style values,
/// so a careless call site still does not write a credential to disk. Redaction is
/// pattern-based and cannot recognise every secret; it backs up the call-site rule above
/// and does not replace it.
///
/// **Robustness.** Logging must never crash or block the app on an I/O problem: `log` never
/// throws, and failures (full disk, deleted directory, read-only volume) drop the entry. The
/// next call retries opening the file.
///
/// **Format.** One line per entry, UTF-8:
/// `2026-10-26T12:34:56.789Z NOTICE [proxy] message`. Timestamps are UTC (ISO 8601 with
/// milliseconds). Control characters and line breaks in messages are escaped (`\n`, `\r`,
/// `\t`, `\u{1B}`), so one entry is always one line. Messages are capped at
/// `maxMessageCharacters`.
///
/// **Rotation.** When an entry would push the current file past `maxBytes`, the files shift
/// `X.log → X.1.log → X.2.log …`, keeping `keepFiles` files in total (current one included),
/// and the oldest is deleted. Files are created with mode 0600 and the directory with 0700,
/// because even redacted operational logs reveal which hosts and proxies a user works with.
public final class AppLog: @unchecked Sendable {
    public enum Level: String, Sendable, CaseIterable, Comparable {
        case debug, info, notice, error

        var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .notice: return 2
            case .error: return 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }

        /// Upper-case, padded to a fixed width so that columns line up in a text viewer.
        var label: String {
            let name = rawValue.uppercased()
            return name + String(repeating: " ", count: max(0, 6 - name.count))
        }
    }

    /// Longest message kept per entry (in `Character`s, after escaping). Longer ones end in `…`.
    public static let maxMessageCharacters = 2_000

    public let directory: URL
    public let fileName: String
    /// Size limit of one file. A single entry larger than this is still written (to a fresh file).
    public let maxBytes: Int
    /// Number of files kept, the current one included (≥ 1).
    public let keepFiles: Int

    /// The current log file (`<directory>/<fileName>`).
    public var fileURL: URL { fileURL(index: 0) }

    /// Entries below this level are dropped. Defaults to `.debug` (everything is written).
    public var minimumLevel: Level {
        get { lock.withLock { _minimumLevel } }
        set { lock.withLock { _minimumLevel = newValue } }
    }

    private let lock = NSLock()
    private var _minimumLevel: Level = .debug
    private var descriptor: Int32 = -1
    private var currentSize = 0

    public init(directory: URL, fileName: String = "PrivacyBrowser.log", maxBytes: Int = 1_000_000, keepFiles: Int = 3) {
        self.directory = directory
        self.fileName = fileName
        self.maxBytes = max(1, maxBytes)
        self.keepFiles = max(1, keepFiles)
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    // MARK: Process-wide instance

    private final class SharedSlot: @unchecked Sendable {
        let lock = NSLock()
        var log: AppLog?
    }

    private static let slot = SharedSlot()

    /// The app's log, set once at launch. `nil` (the default, and in unit tests) means
    /// "logging is off"; call sites use `AppLog.shared?.log(...)`.
    public static var shared: AppLog? {
        get { slot.lock.withLock { slot.log } }
        set { slot.lock.withLock { slot.log = newValue } }
    }

    // MARK: Writing

    /// Appends one entry. Never throws: if the file cannot be written, the entry is dropped.
    public func log(_ level: Level, _ category: String, _ message: String) {
        log(level, category, message, date: Date())
    }

    /// Same as `log(_:_:_:)` with an explicit timestamp (tests).
    func log(_ level: Level, _ category: String, _ message: String, date: Date) {
        guard level >= minimumLevel else { return }
        // Formatting (including the redaction regexes) happens outside the lock; only the
        // file operations are serialized.
        let line = Array(Self.formatLine(level: level, category: category, message: message, date: date).utf8)
        lock.withLock {
            if currentSize > 0, currentSize + line.count > maxBytes {
                rotateLocked()
            }
            guard openLocked() else { return }
            if currentSize > 0, currentSize + line.count > maxBytes {
                // First write after (re)opening an existing file, e.g. from the previous launch.
                rotateLocked()
                guard openLocked() else { return }
            }
            if writeAll(line, to: descriptor) {
                currentSize += line.count
            } else {
                // Drop the entry and the descriptor; the next entry reopens the file, which also
                // recovers once disk space is freed or the directory is restored.
                closeLocked()
            }
        }
    }

    /// One formatted entry including the trailing newline.
    static func formatLine(level: Level, category: String, message: String, date: Date) -> String {
        "\(timestamp(date)) \(level.label) [\(sanitizedCategory(category))] \(prepare(message))\n"
    }

    /// Redacts, escapes control characters and caps the length.
    static func prepare(_ message: String) -> String {
        let escaped = escapeControlCharacters(redact(message))
        guard escaped.count > maxMessageCharacters else { return escaped }
        return String(escaped.prefix(maxMessageCharacters)) + "…"
    }

    static func escapeControlCharacters(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": result.append(contentsOf: "\\n".unicodeScalars)
            case "\r": result.append(contentsOf: "\\r".unicodeScalars)
            case "\t": result.append(contentsOf: "\\t".unicodeScalars)
            default:
                // C0/C1 controls, DEL and the Unicode line/paragraph separators would break
                // the one-entry-per-line rule (or a terminal) when the log is viewed.
                if scalar.properties.generalCategory == .control
                    || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    result.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
                } else {
                    result.append(scalar)
                }
            }
        }
        return String(result)
    }

    /// Categories are short identifiers ("proxy", "profile.launch"): anything else becomes `_`.
    static func sanitizedCategory(_ category: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(category.prefix(32).map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "-" : cleaned
    }

    /// `YYYY-MM-DDTHH:MM:SS.mmmZ`. Built with `gmtime_r` rather than a shared `DateFormatter`,
    /// which avoids formatter thread-safety and locale questions.
    static func timestamp(_ date: Date) -> String {
        // One floored millisecond count, split with floor division, so that seconds and
        // milliseconds always agree (also before 1970).
        let totalMillis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let millis = Int(((totalMillis % 1000) + 1000) % 1000)
        var time = time_t((totalMillis - Int64(millis)) / 1000)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%03ldZ",
                      Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
                      Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), millis)
    }

    // MARK: Reading

    /// The newest part of the log (previous file + current file, newest last), at most
    /// `maxBytes` long and starting at a line boundary, for an in-app viewer or a bug report.
    /// Returns "" if nothing was logged yet or no complete line fits.
    public func tail(maxBytes: Int = 200_000) -> String {
        lock.withLock {
            var data = Data()
            for index in [1, 0] where index < keepFiles {
                if let chunk = try? Data(contentsOf: fileURL(index: index)) { data.append(chunk) }
            }
            return String(decoding: Self.tailBytes(data, maxBytes: maxBytes), as: UTF8.self)
        }
    }

    /// The last `maxBytes` of `data`, cut forward to the first complete line.
    static func tailBytes(_ data: Data, maxBytes: Int) -> Data {
        guard maxBytes > 0 else { return Data() }
        guard data.count > maxBytes else { return data }
        let start = data.index(data.endIndex, offsetBy: -maxBytes)
        if data[data.index(before: start)] == UInt8(ascii: "\n") {
            return data[start...]
        }
        guard let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return data[data.index(after: newline)...]
    }

    /// All log files that currently exist, newest first (for "reveal in Finder" or attaching).
    public var existingFileURLs: [URL] {
        lock.withLock {
            (0..<keepFiles).map(fileURL(index:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// `index` 0 is the current file; `n` is `<name>.n.<ext>` (or `<name>.n` without extension).
    func fileURL(index: Int) -> URL {
        guard index > 0 else { return directory.appendingPathComponent(fileName, isDirectory: false) }
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        let name = ext.isEmpty ? "\(stem).\(index)" : "\(stem).\(index).\(ext)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: File handling (lock held)

    private func openLocked() -> Bool {
        let path = fileURL.path
        if descriptor >= 0 {
            // Reopen if the file was deleted or moved away (user cleared logs while running):
            // writes to an unlinked descriptor would vanish.
            if access(path, F_OK) == 0 { return true }
            closeLocked()
        }
        do {
            try SecureFile.ensureDirectory(directory)
        } catch {
            return false
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        // `open`'s mode only applies on creation; a pre-existing file may be wider.
        _ = fchmod(fd, 0o600)
        var info = stat()
        currentSize = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        descriptor = fd
        return true
    }

    private func closeLocked() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
        currentSize = 0
    }

    private func rotateLocked() {
        closeLocked()
        let fileManager = FileManager.default
        guard keepFiles > 1 else {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        try? fileManager.removeItem(at: fileURL(index: keepFiles - 1))
        for index in stride(from: keepFiles - 2, through: 0, by: -1) {
            let source = fileURL(index: index)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if rename(source.path, fileURL(index: index + 1).path) != 0 {
                // Could not shift (permissions?): start over rather than grow without bound.
                try? fileManager.removeItem(at: source)
            }
        }
    }

    private func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }

    // MARK: Privacy helpers

    /// `scheme://host[:port]` only: no user, password, path, query or fragment. Host-less URLs
    /// (`about:blank`, `file:///…`, `data:…`) become `scheme:`. `nil` (or no scheme) becomes `-`.
    ///
    /// Use this for every URL that reaches the log. The host alone tells a support reader which
    /// site failed without recording what the user was doing there.
    public static func describe(url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return "-" }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return "\(scheme):" }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" } // IPv6 literal
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// Masks credentials that commonly leak into log messages:
    /// - `scheme://user:password@host` and bare `user:password@host` → `***@`
    /// - `password=…`, `token=…`, `secret=…`, `api_key=…`, `session…=…`, `cookie=…` (any key
    ///   containing those words, in query strings or `key=value` text) → `key=***`
    /// - `Authorization:` / `Proxy-Authorization:` / `Cookie:` / `Set-Cookie:` header lines → `***`
    /// - `Bearer <token>` / `Basic <credentials>` → `Bearer ***`
    /// - JSON members such as `"password": "…"` → `"password": "***"`
    ///
    /// Idempotent. Pattern-based by nature: it errs on the side of masking too much.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in redactions {
            // Cheap pre-check: every match of a rule contains its trigger character, and most
            // log messages contain none of them, so the regex engine is skipped for those.
            if let trigger = rule.trigger, !result.unicodeScalars.contains(trigger) { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }

    private struct Redaction {
        /// A character that every match contains; `nil` = always run.
        let trigger: Unicode.Scalar?
        let regex: NSRegularExpression
        let template: String
    }

    private static let secretWords = "password|passwd|passphrase|pwd|token|secret|api[_-]?key|apikey|auth|session|sessid|sid|cookie|signature|sig|credential"

    /// Order matters: header and JSON forms first, so the generic `key=value` rule does not
    /// split them half-way.
    private static let redactions: [Redaction] = {
        let rules: [(Unicode.Scalar?, String, String)] = [
            // scheme://user:password@host (greedy up to the last "@" of the authority).
            ("@", #"(?i)\b([a-z][a-z0-9+.-]*://)[^\s/?#]+@"#, "$1***@"),
            // user:password@host without a scheme (proxy strings typed by hand).
            ("@", #"(?<![A-Za-z0-9._%+*-])[A-Za-z0-9._%+-]+:[^\s@/]+@(?=[A-Za-z0-9\[])"#, "***@"),
            // HTTP header lines carrying credentials: mask the whole value.
            (":", #"(?i)\b(proxy-authorization|authorization|set-cookie|cookie|x-api-key|x-auth-token)(\s*:\s*)[^\r\n]*"#, "$1$2***"),
            // Bearer / Basic credentials anywhere (no single-character trigger: always runs).
            (nil, #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 ***"),
            // JSON members: "password": "…"
            ("\"", #"(?i)("[a-z0-9_.-]*(?:\#(secretWords))[a-z0-9_.-]*"\s*:\s*)"(?:[^"\\]|\\.)*""#, "$1\"***\""),
            // key=value (query strings, form bodies, "password=… token=…" in messages).
            ("=", #"(?i)([a-z0-9_.-]*(?:\#(secretWords))[a-z0-9_.-]*\s*=\s*)(?:"[^"]*"|'[^']*'|[^&\s#;,"']+)"#, "$1***"),
        ]
        return rules.compactMap { trigger, pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { Redaction(trigger: trigger, regex: $0, template: template) }
        }
    }()
}
