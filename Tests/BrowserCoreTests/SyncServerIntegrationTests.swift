import XCTest
@testable import BrowserCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The real client against the real server (`server/pbsync_server.py`), not the stub.
/// Runs when `PB_SYNC_SERVER_URL` (e.g. `http://127.0.0.1:18443`) and `PB_SYNC_SERVER_TOKEN`
/// (a token for vault `*`) are set; CI starts the server for it. Skipped otherwise.
final class SyncServerIntegrationTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-realsync-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func transport(vaultID: UUID, token: String? = nil) throws -> HTTPSyncTransport {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["PB_SYNC_SERVER_URL"].flatMap(URL.init(string:)),
              let defaultToken = environment["PB_SYNC_SERVER_TOKEN"] else {
            throw XCTSkip("PB_SYNC_SERVER_URL / PB_SYNC_SERVER_TOKEN not set")
        }
        let configuration = URLSessionConfiguration.ephemeral
        return try HTTPSyncTransport(configuration: .init(baseURL: url, vaultID: vaultID, bearerToken: token ?? defaultToken,
                                                          allowInsecureLocalhost: true),
                                     session: URLSession(configuration: configuration))
    }

    func testTwoDevicesMergeThroughTheServer() async throws {
        let repoA = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let transportA = try transport(vaultID: repoA.vault.vaultID)
        let profile = try repoA.create(name: "Real server", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Paris"))
        let keyA = try repoA.profileKey(for: profile.id)
        _ = try repoA.bookmarkStore(for: profile.id, key: keyA).add(title: "From A", url: URL(string: "https://a.example/")!)
        let first = try await SyncEngine(repository: repoA, transport: transportA).sync()
        XCTAssertFalse(first.pushed.isEmpty)

        // Device B: bootstrap from the server with the master password alone.
        let transportB = try transport(vaultID: repoA.vault.vaultID)
        let vaultB = try await SyncEngine.bootstrap(transport: transportB, root: base.appendingPathComponent("B"), password: "pw")
        let repoB = try ProfileRepository(vault: vaultB)
        _ = try await SyncEngine(repository: repoB, transport: transportB).sync()
        XCTAssertEqual(repoB.list().map(\.name), ["Real server"])
        XCTAssertEqual(try repoB.loadConfiguration(profile.id).timeZoneIdentifier, "Europe/Paris")

        // Concurrent bookmark edits on both devices merge.
        _ = try repoB.bookmarkStore(for: profile.id, key: repoB.profileKey(for: profile.id))
            .add(title: "From B", url: URL(string: "https://b.example/")!)
        _ = try repoA.bookmarkStore(for: profile.id, key: keyA).add(title: "Also A", url: URL(string: "https://a2.example/")!)
        _ = try await SyncEngine(repository: repoB, transport: transportB).sync()
        let merged = try await SyncEngine(repository: repoA, transport: transportA).sync()
        XCTAssertFalse(merged.merged.isEmpty)
        _ = try await SyncEngine(repository: repoB, transport: transportB).sync()
        for repo in [repoA, repoB] {
            let titles = try repo.bookmarkStore(for: profile.id, key: repo.profileKey(for: profile.id)).all().map(\.title)
            XCTAssertEqual(Set(titles), ["From A", "From B", "Also A"])
        }

        // A second sync with no changes transfers nothing.
        let idle = try await SyncEngine(repository: repoA, transport: transportA).sync()
        XCTAssertEqual(idle.pushed + idle.pulled + idle.deferred, [])
    }

    func testServerRejectsBadToken() async throws {
        let http = try transport(vaultID: UUID(), token: "not-a-token")
        do {
            _ = try await http.listObjects()
            XCTFail("expected 401")
        } catch CoreError.syncServer(let status, _) {
            XCTAssertEqual(status, 401)
        }
    }
}
