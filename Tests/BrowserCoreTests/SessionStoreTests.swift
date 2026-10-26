import XCTest
@testable import BrowserCore

final class SessionStoreTests: XCTestCase {
    var root: URL!
    var repo: ProfileRepository!
    var profile: ProfileSummary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-session-\(UUID().uuidString)")
        repo = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        profile = try repo.create(name: "P", configuration: ProfileConfiguration())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(for id: UUID? = nil, persistent: Bool = true) throws -> SessionStore {
        let id = id ?? profile.id
        return try repo.sessionStore(for: id, key: repo.profileKey(for: id), persistent: persistent)
    }

    private let sample = SessionState(windows: [
        .init(tabs: [.init(url: "https://mail.example.com/inbox", title: "Inbox"),
                     .init(url: "https://docs.example.com/d/1", title: nil)], selectedIndex: 1),
        .init(tabs: [.init(url: "https://news.example.org/", title: "News")]),
    ], savedAt: Date(timeIntervalSince1970: 1_700_000_000))

    func testRoundTripEncryptedOwnerOnly() throws {
        let sessions = try store()
        XCTAssertTrue(sessions.isPersistent)
        XCTAssertNil(try sessions.load(), "no session saved yet")
        try sessions.save(sample)

        let reopened = try store()
        XCTAssertEqual(try reopened.load(), sample)

        let url = repo.sessionURL(for: profile.id)
        XCTAssertEqual(url.lastPathComponent, "session.bin")
        let raw = try Data(contentsOf: url)
        for needle in ["example.com", "example.org", "Inbox"] {
            XCTAssertNil(raw.range(of: Data(needle.utf8)), "\(needle) must not be stored in plaintext")
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testNormalization() throws {
        let state = SessionState(windows: [
            .init(tabs: [.init(url: "https://user:secret@Example.COM/a?q=1#access_token=abc", title: "  A  "),
                         .init(url: "about:blank", title: "Blank"),
                         .init(url: "file:///etc/hosts"),
                         .init(url: "javascript:alert(1)"),
                         .init(url: "http://b.test/", title: "   ")], selectedIndex: 1),
            .init(tabs: [.init(url: "about:blank")], selectedIndex: 0),
            .init(tabs: [], selectedIndex: 3),
            .init(tabs: [.init(url: "https://c.test/"), .init(url: "https://d.test/")], selectedIndex: 99),
            .init(tabs: [.init(url: "https://e.test/")], selectedIndex: -5),
            .init(tabs: [.init(url: "https://long.test/" + String(repeating: "x", count: SessionState.maxURLLength))]),
        ], savedAt: Date(timeIntervalSince1970: 42))

        let normalized = state.normalized()
        XCTAssertEqual(normalized.savedAt, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(normalized.windows, [
            // Credentials and the fragment are gone; the dropped selected tab passes selection to the next kept one.
            .init(tabs: [.init(url: "https://example.com/a?q=1", title: "A"), .init(url: "http://b.test/", title: nil)],
                  selectedIndex: 1),
            .init(tabs: [.init(url: "https://c.test/"), .init(url: "https://d.test/")], selectedIndex: 1),
            .init(tabs: [.init(url: "https://e.test/")], selectedIndex: 0),
        ])
        XCTAssertEqual(normalized.normalized(), normalized, "normalisation is idempotent")

        // Selected tab dropped at the end → the last kept tab is selected.
        XCTAssertEqual(SessionState(windows: [.init(tabs: [.init(url: "https://a.test/"), .init(url: "about:blank")], selectedIndex: 1)])
            .normalized().windows.first?.selectedIndex, 0)
        XCTAssertTrue(SessionState(windows: [.init(tabs: [.init(url: "about:blank")])]).normalized().isEmpty)
    }

    func testCaps() throws {
        func window(_ count: Int, selected: Int) -> SessionState.Window {
            .init(tabs: (0..<count).map { .init(url: "https://site\($0).test/") }, selectedIndex: selected)
        }
        let state = SessionState(windows: (0..<12).map { _ in window(60, selected: 0) } + [window(60, selected: 55)])
        let normalized = state.normalized()
        XCTAssertEqual(normalized.windows.count, SessionState.maxWindows)
        XCTAssertTrue(normalized.windows.allSatisfy { $0.tabs.count == SessionState.maxTabsPerWindow })
        XCTAssertEqual(normalized.windows[0].tabs.first?.url, "https://site0.test/")

        // A selected tab beyond the cap stays in the kept range and stays selected.
        let kept = try XCTUnwrap(SessionState(windows: [window(60, selected: 55)]).normalized().windows.first)
        XCTAssertEqual(kept.tabs.count, 50)
        XCTAssertEqual(kept.tabs[kept.selectedIndex].url, "https://site55.test/")
        XCTAssertEqual(kept.tabs.last?.url, "https://site55.test/")
        let early = try XCTUnwrap(SessionState(windows: [window(60, selected: 49)]).normalized().windows.first)
        XCTAssertEqual(early.tabs.first?.url, "https://site0.test/")
        XCTAssertEqual(early.selectedIndex, 49)
    }

    func testSaveStoresNormalizedAndEmptyClears() throws {
        let sessions = try store()
        try sessions.save(SessionState(windows: [.init(tabs: [.init(url: "https://u:p@a.test/#x")])]))
        XCTAssertEqual(try store().load()?.windows.first?.tabs.first?.url, "https://a.test/")

        // Nothing restorable → the saved session is removed.
        try sessions.save(SessionState(windows: [.init(tabs: [.init(url: "about:blank")])]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.sessionURL(for: profile.id).path))
        XCTAssertNil(try sessions.load())

        try sessions.save(sample)
        try sessions.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.sessionURL(for: profile.id).path))
        XCTAssertNil(try store().load())
        try sessions.clear() // idempotent
    }

    func testWrongProfileOrKeyFails() throws {
        let other = try repo.create(name: "Other", configuration: ProfileConfiguration())
        try store().save(sample)

        // A session copied into another profile is bound to its owner's id and key.
        try FileManager.default.copyItem(at: repo.sessionURL(for: profile.id), to: repo.sessionURL(for: other.id))
        XCTAssertThrowsError(try store(for: other.id).load()) {
            XCTAssertEqual($0 as? CoreError, .authenticationFailed)
        }
        // Right file, wrong key.
        let wrongKey = try repo.sessionStore(for: profile.id, key: repo.profileKey(for: other.id))
        XCTAssertThrowsError(try wrongKey.load()) {
            XCTAssertEqual($0 as? CoreError, .authenticationFailed)
        }
        // Session key is separate from the other per-profile keys (history cannot open it).
        let key = try repo.profileKey(for: profile.id)
        let historyCodec = HistoryStore.file(url: nil, profileID: profile.id, profileKey: key)
        XCTAssertThrowsError(try historyCodec.decode(Data(contentsOf: repo.sessionURL(for: profile.id))))

        XCTAssertThrowsError(try repo.sessionStore(for: UUID(), key: key)) {
            guard case .profileNotFound = $0 as? CoreError else { return XCTFail("\($0)") }
        }
    }

    func testUnsupportedFormatIsReported() throws {
        let key = try repo.profileKey(for: profile.id)
        let codec = EncryptedDocumentFile<[String: Int]>(url: repo.sessionURL(for: profile.id),
                                                         key: key.derive(info: "session", salt: profile.id.rawBytes),
                                                         aad: "session:v1:\(profile.id.uuidString)")
        try codec.save(["format": 2])
        XCTAssertThrowsError(try store().load()) {
            guard case .unsupportedFormat = $0 as? CoreError else { return XCTFail("\($0)") }
        }
    }

    func testMemoryOnlyStoreNeverWrites() throws {
        let sessions = try store(persistent: false)
        XCTAssertFalse(sessions.isPersistent)
        try sessions.save(sample)
        XCTAssertEqual(try sessions.load(), sample)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.sessionURL(for: profile.id).path))
        XCTAssertNil(try store(persistent: false).load(), "a new memory-only store starts empty")
        try sessions.clear()
        XCTAssertNil(try sessions.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.directory(for: profile.id).path), ["config.bin"])
    }

    func testDeleteRemovesSessionAndLateSaveDoesNotResurrect() throws {
        let sessions = try store()
        try sessions.save(sample)
        try repo.delete(profile.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.sessionURL(for: profile.id).path))
        XCTAssertThrowsError(try sessions.save(sample))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.directory(for: profile.id).path))
    }

    func testSessionIsNotSynced() async throws {
        let base = root.appendingPathComponent("sync")
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        try store().save(sample)

        let report = try await SyncEngine(repository: repo, transport: transport).sync()
        XCTAssertTrue(report.pushed.contains("profile/\(profile.id.uuidString)/config"))
        XCTAssertFalse(report.pushed.contains { $0.contains("session") }, "\(report.pushed)")

        let repoB = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport,
                                                                            root: base.appendingPathComponent("B"), password: "pw"))
        _ = try await SyncEngine(repository: repoB, transport: transport).sync()
        XCTAssertEqual(repoB.list().map(\.id), [profile.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoB.sessionURL(for: profile.id).path))
        XCTAssertNil(try repoB.sessionStore(for: profile.id, key: repoB.profileKey(for: profile.id)).load())
        // Sync left this device's session alone.
        XCTAssertEqual(try store().load(), sample)
    }

    func testTolerantDecoding() throws {
        let state = try JSONCoding.decoder.decode(SessionState.self, from: Data(#"{"windows":[{"tabs":[{"url":"https://a.test/"}]},{}]}"#.utf8))
        XCTAssertEqual(state.savedAt, .distantPast)
        XCTAssertEqual(state.windows, [.init(tabs: [.init(url: "https://a.test/")], selectedIndex: 0), .init(tabs: [], selectedIndex: 0)])
        XCTAssertEqual(try JSONCoding.decoder.decode(SessionState.self, from: Data("{}".utf8)).windows, [])
    }
}
