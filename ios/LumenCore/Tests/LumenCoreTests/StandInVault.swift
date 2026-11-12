@testable import BrowserCore
import XCTest

/// The stand-in server's vault for the app's end-to-end tests, made by the Mac's own code: written
/// only when the CI asks (LUMEN_WRITE_STANDIN_VAULT names the folder), in the folder transport's
/// layout, which ios/testbed/account.py serves. Master password "vault-pass-1".
final class StandInVault: XCTestCase {
    func testWriteTheStandInsVault() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_WRITE_STANDIN_VAULT"], !path.isEmpty else {
            throw XCTSkip("only for the CI's end-to-end tests")
        }
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: folder)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("standin-mac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try MasterVault.create(in: root, password: "vault-pass-1", iterations: 1_000)
        let repository = try ProfileRepository(vault: vault)
        // Behind the testbed's SOCKS5 proxy B (port 28382, login ub / pb), as a Mac would have it.
        let shop = try repository.create(name: "Магазин с Mac", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .socks5, host: "127.0.0.1", port: 28382, username: "ub", password: "pb"),
            tags: ["mac"], notes: "Синхронизирован с Mac"))
        // Signed in on the Mac: the testbed's /state cookie of macstate.lumentest (the sync's step 4).
        try repository.saveCookieJar(CookieJarDocument(cookies: [.init(
            cookie: ImportedCookie(name: "lumen", value: "from-mac", domain: "macstate.lumentest", hostOnly: true, path: "/",
                                   expires: Date().addingTimeInterval(30 * 86400)),
            updatedAt: Date().addingTimeInterval(-600))]), for: shop.id)
        _ = try repository.create(name: "Почта с Mac", configuration: ProfileConfiguration(tags: ["mac"]))
        let transport = LocalDirectorySyncTransport(directory: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        let objects = try await transport.listObjects()
        XCTAssertTrue(objects.contains { $0.objectID == SyncEngine.vaultHeaderObjectID })
        print("stand-in vault: \(vault.vaultID.uuidString.lowercased()), \(objects.count) objects")
    }
}
