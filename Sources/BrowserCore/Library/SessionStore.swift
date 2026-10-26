#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The open windows and tabs of a profile, saved so they can be reopened at the next launch.
///
/// Only what is needed to reopen a page is kept: the URL and a title for display before it
/// loads. Back/forward lists, form state and scroll positions are not saved.
public struct SessionState: Codable, Equatable, Sendable {
    public struct Tab: Codable, Equatable, Sendable {
        public var url: String
        public var title: String?

        public init(url: String, title: String? = nil) {
            self.url = url
            self.title = title
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var tabs: [Tab]
        public var selectedIndex: Int

        public init(tabs: [Tab], selectedIndex: Int = 0) {
            self.tabs = tabs
            self.selectedIndex = selectedIndex
        }

        private enum CodingKeys: String, CodingKey { case tabs, selectedIndex }

        /// Tolerant decoding, as for the other persisted types.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tabs = try c.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
            selectedIndex = try c.decodeIfPresent(Int.self, forKey: .selectedIndex) ?? 0
        }
    }

    public static let maxWindows = 10
    public static let maxTabsPerWindow = 50
    /// Longer URLs are dropped rather than truncated (a truncated URL is a different page).
    public static let maxURLLength = 8 * 1024

    public var windows: [Window]
    public var savedAt: Date

    public init(windows: [Window] = [], savedAt: Date = Date()) {
        self.windows = windows
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey { case windows, savedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decodeIfPresent([Window].self, forKey: .windows) ?? []
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? .distantPast
    }

    /// True when there is no tab to reopen.
    public var isEmpty: Bool { windows.allSatisfy { $0.tabs.isEmpty } }

    /// The state that is actually stored and restored:
    /// * only http(s) URLs with a host; user/password are stripped and the fragment is dropped
    ///   (fragments can carry tokens, e.g. OAuth implicit-flow `#access_token=`). Same rule as
    ///   history (`HistoryStore.normalizedURL`).
    /// * titles trimmed and capped like history titles; empty → nil.
    /// * empty windows are dropped; at most `maxWindows` windows of `maxTabsPerWindow` tabs.
    ///   When a window has too many tabs, the kept range includes the selected tab.
    /// * `selectedIndex` is clamped; if the selected tab itself is dropped, the next kept tab
    ///   (or the last one) is selected.
    public func normalized() -> SessionState {
        var kept: [Window] = []
        for window in windows where kept.count < Self.maxWindows {
            if let clean = window.normalized() { kept.append(clean) }
        }
        return SessionState(windows: kept, savedAt: savedAt)
    }
}

extension SessionState.Tab {
    func normalized() -> SessionState.Tab? {
        guard url.utf8.count <= SessionState.maxURLLength, let parsed = URL(string: url),
              let clean = HistoryStore.normalizedURL(parsed), clean.utf8.count <= SessionState.maxURLLength else { return nil }
        let cleanTitle = HistoryStore.cleanTitle(title)
        return SessionState.Tab(url: clean, title: cleanTitle.isEmpty ? nil : cleanTitle)
    }
}

extension SessionState.Window {
    func normalized() -> SessionState.Window? {
        guard !tabs.isEmpty else { return nil }
        let selected = min(max(selectedIndex, 0), tabs.count - 1)
        var kept: [SessionState.Tab] = []
        var keptSelected = 0
        for (index, tab) in tabs.enumerated() {
            if index == selected { keptSelected = kept.count }
            if let clean = tab.normalized() { kept.append(clean) }
        }
        guard !kept.isEmpty else { return nil }
        keptSelected = min(keptSelected, kept.count - 1)
        let limit = SessionState.maxTabsPerWindow
        if kept.count > limit {
            let start = keptSelected < limit ? 0 : keptSelected - limit + 1
            kept = Array(kept[start ..< start + limit])
            keptSelected -= start
        }
        return SessionState.Window(tabs: kept, selectedIndex: keptSelected)
    }
}

/// On-disk document, versioned like the other per-profile documents.
struct SessionDocument: Codable, Equatable {
    var format = 1
    var session: SessionState

    init(session: SessionState) {
        self.session = session
    }

    private enum CodingKeys: String, CodingKey { case format, session }

    /// Checks `format` before the payload, so a file from a newer build reports
    /// `unsupportedFormat` instead of a decoding error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        guard format == 1 else { throw CoreError.unsupportedFormat("session format \(format)") }
        session = try c.decode(SessionState.self, forKey: .session)
    }
}

/// A profile's last session (`session.bin`), encrypted at rest with
/// `HKDF(profileKey, "session")`, AAD `"session:v1:<profileID>"`.
///
/// Device-local: the open tabs of one Mac are not synced (`ProfileSyncFile` does not list
/// this file). It lives in the profile directory, so deleting the profile deletes it.
/// Ephemeral profiles get a memory-only store (`url == nil`) that never writes.
///
/// Thread-safe; saves are serialised, so the last `save` call wins.
public final class SessionStore: @unchecked Sendable {
    private let file: EncryptedDocumentFile<SessionDocument>
    private let lock = NSLock()
    /// The last saved state; the only copy for memory-only stores.
    private var memory: SessionState?

    static func file(url: URL?, profileID: UUID, profileKey: SymmetricKey) -> EncryptedDocumentFile<SessionDocument> {
        EncryptedDocumentFile(url: url, key: profileKey.derive(info: "session", salt: profileID.rawBytes),
                              aad: "session:v1:\(profileID.uuidString)")
    }

    init(file: EncryptedDocumentFile<SessionDocument>) {
        self.file = file
    }

    public var isPersistent: Bool { file.url != nil }

    /// The saved session, normalised, or `nil` when there is nothing to reopen. Throws when the
    /// file exists but cannot be authenticated or decoded (wrong key or profile, tampering,
    /// newer format); the caller should then start with a fresh window.
    public func load() throws -> SessionState? {
        try lock.withLock {
            let stored: SessionState?
            if file.url != nil {
                stored = try file.load()?.session
            } else {
                stored = memory
            }
            guard let state = stored?.normalized(), !state.isEmpty else { return nil }
            return state
        }
    }

    /// Normalises and stores `state`. A state with no restorable tab removes the saved session
    /// instead, so the next launch starts fresh.
    ///
    /// Refuses to recreate a missing profile directory: a late save from a profile that was
    /// deleted meanwhile must not leave a `session.bin` behind.
    public func save(_ state: SessionState) throws {
        let clean = state.normalized()
        try lock.withLock {
            guard !clean.isEmpty else {
                try removeLocked()
                return
            }
            if let url = file.url {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw CoreError.io("profile directory for \(url.lastPathComponent) no longer exists")
                }
                try file.save(SessionDocument(session: clean))
            }
            memory = clean
        }
    }

    /// Forgets the saved session (and removes the file).
    public func clear() throws {
        try lock.withLock { try removeLocked() }
    }

    /// Caller must hold `lock`.
    private func removeLocked() throws {
        memory = nil
        guard let url = file.url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CoreError.io("remove \(url.lastPathComponent): \(error)")
        }
    }
}
