import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BrowserCore

/// Sync through the Lumen account (`AccountSync`, `DeviceSettings.SyncTarget.account`; the account
/// server's CONTRACT §16.1): when it is offered, what each refusal of the server means, the transport it
/// makes, and the target and its status as `settings.bin` keeps them. The engine against the server's
/// generation: `ServerGenerationTests`.
final class AccountSyncTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-accountsync-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: The server and its refusals

    /// The account server with this Mac's device token, for this vault: nothing typed, nothing stored.
    func testTheTransportIsTheAccountServersWithTheDeviceToken() throws {
        let vaultID = UUID()
        let http = try AccountSync.transport(server: URL(string: "https://api.lumen.test")!, deviceToken: ServerToken("lmd_device"),
                                             vaultID: vaultID)
        XCTAssertEqual(http.generationScope, "https://api.lumen.test|\(vaultID.uuidString.lowercased())")
        XCTAssertNil(http.serverGeneration)
        XCTAssertThrowsError(try AccountSync.transport(server: URL(string: "http://api.lumen.test")!, deviceToken: ServerToken("lmd_device"),
                                                       vaultID: vaultID), "HTTPS only")
        XCTAssertNoThrow(try AccountSync.transport(server: URL(string: "http://127.0.0.1:8080")!, deviceToken: ServerToken("lmd_device"),
                                                   vaultID: vaultID, allowInsecureLocalhost: true), "a development build's own server")
    }

    func testOutcomesOfTheServersRefusals() {
        let cases: [(Error, AccountSync.Outcome)] = [
            (SyncServerRefusal(status: 409, code: "generation_changed"), .generationChanged),
            (SyncServerRefusal(status: 401, code: "unauthorized"), .unauthorized),
            (SyncServerRefusal(status: 403, code: "forbidden"), .anotherAccount),
            (SyncServerRefusal(status: 403, code: "too_many_vaults"), .tooManyVaults),
            (SyncServerRefusal(status: 403, code: "account_disabled"), .accountDisabled),
            (SyncServerRefusal(status: 403, code: "sync_on_hold"), .onHold(until: nil)),
            (SyncServerRefusal(status: 403, code: "sync_not_in_plan"), .notInPlan),
            (SyncServerRefusal(status: 429, code: "rate_limited", retryAfter: 30), .rateLimited(retryAfter: 30)),
            (SyncServerRefusal(status: 507, code: "quota_exceeded"), .overQuota),
            (SyncServerRefusal(status: 413, code: "too_large"), .tooLarge),
            (SyncServerRefusal(status: 400, code: "bad_generation"), .other),
            (CoreError.syncServer(status: 401, message: "unauthorized"), .unauthorized),
            (CoreError.syncServer(status: 500, message: "x"), .other),
            (CoreError.io("offline"), .other),
        ]
        for (error, outcome) in cases { XCTAssertEqual(AccountSync.outcome(of: error), outcome, "\(error)") }
    }

    func testTheAccountIsOfferedToASignedInMacUnlessTheServerDisabledIt() {
        func entitlement(_ status: Entitlement.Status, _ reason: String?) -> Entitlement {
            Entitlement(deviceID: "d", machineID: "m", role: "owner", plan: "none", status: status, exportReason: reason,
                        limits: .init(profiles: 0, devices: 2, seats: 1), profilesOnOtherDevices: 0, periodEndsAt: nil,
                        issuedAt: Date(), refreshAfter: Date(), expiresAt: Date(), graceEndsAt: Date())
        }
        XCTAssertFalse(AccountSync.isOffered(signedIn: false, entitlement: nil))
        XCTAssertTrue(AccountSync.isOffered(signedIn: true, entitlement: nil), "signed in, the document not checked yet")
        XCTAssertTrue(AccountSync.isOffered(signedIn: true, entitlement: entitlement(.active, nil)))
        XCTAssertTrue(AccountSync.isOffered(signedIn: true, entitlement: entitlement(.exportOnly, "period_ended")),
                      "a Mac's sync goes on after the paid period: the data is the person's to take")
        XCTAssertFalse(AccountSync.isOffered(signedIn: true, entitlement: entitlement(.exportOnly, "account_disabled")))
    }
    // MARK: The sync target as stored

    func testTheAccountTargetIsStoredAndTheOtherTargetsReadAsBefore() throws {
        // `settings.bin`'s JSON as the versions before the account target wrote it.
        let server = Data(#"{"syncTarget":{"server":{"baseURL":"https:\/\/sync.example","token":"tok-123"}}}"#.utf8)
        XCTAssertEqual(try JSONCoding.decoder.decode(DeviceSettings.self, from: server).syncTarget,
                       .server(baseURL: URL(string: "https://sync.example")!, token: "tok-123"))
        let folder = Data(#"{"syncTarget":{"folder":{"bookmark":"AQID","path":"\/Volumes\/NAS\/lumen"}}}"#.utf8)
        XCTAssertEqual(try JSONCoding.decoder.decode(DeviceSettings.self, from: folder).syncTarget,
                       .folder(bookmark: Data([1, 2, 3]), path: "/Volumes/NAS/lumen"))
        let status = Data(#"{"lastSync":{"date":"2026-11-01T10:00:00Z","pushed":3,"pulled":1,"merged":0,"conflicts":0,"deferred":0}}"#.utf8)
        let old = try XCTUnwrap(JSONCoding.decoder.decode(DeviceSettings.self, from: status).lastSync)
        XCTAssertEqual(old.pushed, 3)
        XCTAssertNil(old.overQuota)
        XCTAssertNil(old.tooLarge)
        XCTAssertNil(old.heldUntil)

        // The account: only the choice — no address, no token.
        let settings = DeviceSettings(syncTarget: .account)
        let encoded = try JSONCoding.encoder.encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let target = try XCTUnwrap(json["syncTarget"] as? [String: Any])
        XCTAssertEqual(Array(target.keys), ["account"])
        XCTAssertEqual((target["account"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual(try JSONCoding.decoder.decode(DeviceSettings.self, from: encoded), settings)
        // Format 2 with it: a version from before the account target refuses the file as a newer
        // version's and leaves it alone, rather than take it for a damaged one.
        XCTAssertEqual(json["format"] as? Int, 2)
        XCTAssertThrowsError(try DocumentFormat.check(encoded, supported: 1, what: "settings.bin")) { error in
            XCTAssertEqual(error as? CoreError, .newerFormat(what: "settings.bin", found: 2, supported: 1))
        }
        // The others stay as every version wrote them: no marker.
        for other in [DeviceSettings(), DeviceSettings(syncTarget: .server(baseURL: URL(string: "https://sync.example")!, token: "t")),
                      DeviceSettings(syncTarget: .folder(bookmark: Data([1]), path: "/x"))] {
            let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(other)) as? [String: Any])
            XCTAssertNil(plain["format"])
        }

        // Encrypted in the vault, as the others.
        let vault = try MasterVault.create(in: base.appendingPathComponent("settings"), password: "pw", iterations: 1_000)
        var saved = settings
        saved.lastSync = .init(date: Date(timeIntervalSince1970: 1_700_000_000), error: "held", heldUntil: Date(timeIntervalSince1970: 1_700_086_400))
        try saved.save(to: vault)
        XCTAssertEqual(try DeviceSettings.load(from: vault), saved)
    }

    func testAStatusCountsWhatTheServerRefusedForSpaceAndSize() {
        var report = SyncReport()
        report.pushed = ["index"]
        report.deferred = ["a", "b", "c"]
        report.deferredOverQuota = ["a", "b"]
        report.deferredTooLarge = ["c"]
        let status = DeviceSettings.SyncStatus(report: report)
        XCTAssertEqual(status.deferred, 3)
        XCTAssertEqual(status.overQuota, 2)
        XCTAssertEqual(status.tooLarge, 1)
        XCTAssertNil(DeviceSettings.SyncStatus(report: SyncReport()).overQuota)
    }
}
