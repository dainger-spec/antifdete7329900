#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import BrowserCore
import Foundation
import XCTest

/// The account server's conversations (§6, §9) against a server played here: what each answer makes
/// of this Mac's account state, and how long the Mac works when the server says nothing at all.
final class LicenseClientTests: XCTestCase {
    private let signer = Curve25519.Signing.PrivateKey()
    private let machineID = MachineID.compute(platformUUID: "8C5E5A2D-1B3F-4E6A-9D7C-0A1B2C3D4E5F")
    private let deviceID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    private var keys: [String: Data] {
        let raw = signer.publicKey.rawRepresentation
        return [EntitlementKeys.keyID(of: raw): raw]
    }

    /// Answers each request with what `answer` gives, keeps every request.
    private final class FakeServer: AccountTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [AccountRequest] = []
        var answer: (AccountRequest) throws -> AccountResponse

        init(_ answer: @escaping (AccountRequest) throws -> AccountResponse) { self.answer = answer }

        var requests: [AccountRequest] { lock.withLock { _requests } }

        func send(_ request: AccountRequest) async throws -> AccountResponse {
            lock.withLock { _requests.append(request) }
            return try answer(request)
        }
    }

    private struct NoNetwork: Error {}

    private func time(_ text: String) -> Date { try! Date.ISO8601FormatStyle().parse(text) }

    private func document(plan: String = "pro", status: String = "active", reason: String? = nil, version: Int = 1,
                          periodEnds: String? = "2026-12-01T00:00:00Z", issued: String = "2026-11-01T10:00:00Z",
                          device: String? = nil, signer: Curve25519.Signing.PrivateKey? = nil) -> [String: Any] {
        let issuedAt = time(issued)
        func at(_ hours: Double) -> String { issuedAt.addingTimeInterval(hours * 3_600).formatted(.iso8601) }
        let payload: [String: Any] = [
            "kind": "lumen.entitlement", "version": version, "documentID": UUID().uuidString.lowercased(), "accountID": "a", "licenseID": "l",
            "deviceID": device ?? deviceID, "machineID": machineID, "role": "owner", "plan": plan, "status": status,
            "exportReason": reason.map { $0 as Any } ?? NSNull(), "limits": ["profiles": 10, "devices": 2, "seats": 1],
            "profilesOnOtherDevices": 3, "periodEndsAt": periodEnds.map { $0 as Any } ?? NSNull(), "issuedAt": issued,
            "refreshAfter": at(24), "expiresAt": at(96), "graceEndsAt": at(168),
        ]
        let bytes = try! JSONSerialization.data(withJSONObject: payload)
        let key = signer ?? self.signer
        return ["format": 1, "keyID": EntitlementKeys.keyID(of: self.signer.publicKey.rawRepresentation),
                "payload": bytes.base64EncodedString(), "signature": try! key.signature(for: bytes).base64EncodedString()]
    }

    private func ok(_ object: [String: Any]) -> AccountResponse {
        AccountResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func error(_ status: Int, _ code: String, _ extra: [String: Any] = [:], retryAfter: String? = nil) -> AccountResponse {
        var body: [String: Any] = ["code": code, "message": "for the developer's log"]
        body.merge(extra) { $1 }
        return AccountResponse(status: status, body: try! JSONSerialization.data(withJSONObject: ["error": body]), retryAfter: retryAfter)
    }

    private func activation(_ document: [String: Any], serverTime: String = "2026-11-01T10:00:00Z") -> AccountResponse {
        ok(["device": ["deviceID": deviceID, "code": "B119", "label": "", "mine": true, "accountEmail": NSNull()],
            "deviceToken": "lmd_device_token", "entitlement": document, "serverTime": serverTime])
    }

    private func client(_ server: FakeServer) -> LicenseClient {
        LicenseClient(transport: server, keys: keys, machineID: machineID, appVersion: "1.2.0 (120)")
    }

    private func body(_ request: AccountRequest) -> [String: Any] {
        (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }

    /// A Mac signed in by the session at 2026-11-01T10:00Z, as the server played here answered.
    private func signedIn() async throws -> AccountRecord {
        let server = FakeServer { _ in self.activation(self.document()) }
        let session = AccountSession(token: ServerToken("lms_session"), expiresAt: nil, accountID: "a", idleTimeoutSeconds: 604_800)
        let result = await client(server).activate(.session(session.token), label: "", profileCount: 2, record: AccountRecord(),
                                                   session: session, wall: time("2026-11-01T10:00:00Z"), uptime: 1_000)
        return try result.get().record
    }

    // MARK: Activation (§6.1)

    func testActivatingWithASessionStoresTheDeviceAndTheServersTime() async throws {
        let server = FakeServer { _ in self.activation(self.document(plan: "trial"), serverTime: "2026-11-01T12:00:00Z") }
        let session = AccountSession(token: ServerToken("lms_session"), expiresAt: nil, accountID: "a", idleTimeoutSeconds: 604_800)
        let result = await client(server).activate(.session(session.token), label: "Рабочий", profileCount: 3, record: AccountRecord(),
                                                   session: session, wall: time("2026-11-01T10:00:00Z"), uptime: 500)
        let activation = try result.get()
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/v1/devices/activate")
        XCTAssertEqual(request.bearer?.unredacted(), "lms_session")
        let sent = body(request)
        XCTAssertEqual(sent["machineID"] as? String, machineID)
        XCTAssertEqual(sent["label"] as? String, "Рабочий")
        XCTAssertEqual(sent["profileCount"] as? Int, 3)
        XCTAssertEqual(sent["appVersion"] as? String, "1.2.0 (120)")
        XCTAssertNil(sent["key"])
        let record = activation.record
        XCTAssertTrue(record.isSignedIn)
        XCTAssertEqual(record.deviceID, deviceID)
        XCTAssertEqual(record.code, "B119")
        XCTAssertEqual(record.deviceToken?.unredacted(), "lmd_device_token")
        XCTAssertEqual(record.signedInWith, .email)
        XCTAssertEqual(record.session?.sessionToken?.unredacted(), "lms_session")
        XCTAssertEqual(record.lastSuccessAt, time("2026-11-01T12:00:00Z"))
        XCTAssertEqual(record.clock, EffectiveClock(floorTime: time("2026-11-01T12:00:00Z"), floorUptime: 500))
        XCTAssertTrue(activation.trialStarted)
        XCTAssertEqual(activation.clockSkew, 7_200, "this Mac's clock two hours behind the server's")
    }

    func testActivatingWithAKeySendsTheKeyAndNoAuthorization() async throws {
        let server = FakeServer { _ in self.activation(self.document()) }
        let key = try XCTUnwrap(AccountKey(typed: "lmk 0123 4567 89ab cdef ghjk mnmt"))
        let result = await client(server).activate(.key(key), label: "", profileCount: 0, record: AccountRecord(),
                                                   wall: time("2026-11-01T10:00:00Z"), uptime: 1)
        let record = try result.get().record
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertNil(request.bearer)
        XCTAssertEqual(body(request)["key"] as? String, "LMK-0123-4567-89AB-CDEF-GHJK-MNMT", "the canonical form")
        XCTAssertEqual(record.signedInWith, .key)
        XCTAssertNil(record.session)
        // The key is not in the account's file.
        let file = String(decoding: try JSONCoding.encoder.encode(record), as: UTF8.self)
        XCTAssertFalse(file.contains("0123-4567"))
        XCTAssertFalse(file.contains("01234567"))
    }

    func testAnActivationWhoseDocumentDoesNotPassDidNotHappen() async {
        for (document, expected) in [(document(device: "00000000-0000-0000-0000-000000000000"), EntitlementCheck.wrongDevice),
                                     (document(version: 2), .newerVersion),
                                     (document(signer: Curve25519.Signing.PrivateKey()), .badSignature)] {
            let server = FakeServer { _ in self.activation(document) }
            let result = await client(server).activate(.session(ServerToken("lms_s")), label: "", profileCount: 0, record: AccountRecord(),
                                                       wall: Date(), uptime: 1)
            guard case .failure(.document(let check)) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(check, expected)
        }
    }

    func testAFullLicenseNamesItsMacsToUnlink() async {
        let server = FakeServer { _ in
            self.error(409, "device_limit_reached", ["devices": [["deviceID": "d1", "code": "A7F3", "label": "Рабочий", "lastSeenAt": "2026-10-31T09:00:00Z",
                                                                    "profileCount": 7, "mine": true],
                                                                   ["deviceID": "d2", "code": "3KQ9"]],
                                                       "unlinkAvailableAt": NSNull(), "unlinkCooldownSeconds": 604_800, "offlineWorkSeconds": 604_800])
        }
        let result = await client(server).activate(.session(ServerToken("lms_s")), label: "", profileCount: 0, record: AccountRecord(),
                                                   wall: Date(), uptime: 1)
        guard case .failure(.server(let error)) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(error.code, "device_limit_reached")
        XCTAssertEqual(error.devices?.map(\.code), ["A7F3", "3KQ9"], "a device without a label still reads")
        XCTAssertNil(error.unlinkAvailableAt)
        XCTAssertEqual(error.offlineWorkSeconds, 604_800)
    }

    // MARK: Refresh (§6.2, §9.3, §9.4)

    func testWhatIsNotTheServersAnswerChangesNothing() async throws {
        let record = try await signedIn()
        let answers: [(String, () throws -> AccountResponse)] = [
            ("no network", { throw NoNetwork() }),
            ("5xx", { self.error(503, "internal") }),
            ("408", { AccountResponse(status: 408, body: Data()) }),
            ("a captive portal's 200", { AccountResponse(status: 200, body: Data("<html><body>Sign in to the Wi-Fi</body></html>".utf8)) }),
            ("404 page not found", { AccountResponse(status: 404, body: Data("404 page not found".utf8)) }),
            ("another 4xx", { self.error(400, "invalid_request", ["field": "machineID"]) }),
            ("a changed document", { self.ok(["entitlement": self.document(signer: Curve25519.Signing.PrivateKey()), "serverTime": "2026-11-02T10:00:00Z"]) }),
            ("another device's document", { self.ok(["entitlement": self.document(device: "00000000-0000-0000-0000-000000000000"), "serverTime": "2026-11-02T10:00:00Z"]) }),
        ]
        for (what, answer) in answers {
            let server = FakeServer { _ in try answer() }
            let (after, result) = await client(server).refresh(record, profileCount: 2, wall: time("2026-11-02T10:00:00Z"), uptime: 2_000)
            XCTAssertEqual(result, .unreachable(retryAfter: nil), what)
            XCTAssertEqual(after, record, what)
        }
    }

    func testARateLimitIsUnreachableWithItsDelay() async throws {
        let record = try await signedIn()
        let server = FakeServer { _ in self.error(429, "rate_limited", retryAfter: "120") }
        let (after, result) = await client(server).refresh(record, profileCount: 2, wall: Date(), uptime: 2)
        XCTAssertEqual(result, .unreachable(retryAfter: 120))
        XCTAssertEqual(after, record)
    }

    func testARefreshSendsTheDeviceTokenAndStoresTheNewDocument() async throws {
        let record = try await signedIn()
        let server = FakeServer { _ in
            self.ok(["entitlement": self.document(periodEnds: "2026-12-31T00:00:00Z", issued: "2026-11-02T10:00:00Z"), "serverTime": "2026-11-02T10:00:00Z"])
        }
        let (after, result) = await client(server).refresh(record, profileCount: 4, wall: time("2026-11-02T10:01:00Z"), uptime: 3_000)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/v1/device/entitlement")
        XCTAssertEqual(request.bearer?.unredacted(), "lmd_device_token")
        XCTAssertEqual(body(request)["profileCount"] as? Int, 4)
        XCTAssertNil(body(request)["label"], "no label in a refresh (§6.2)")
        XCTAssertEqual(result, .accepted(paymentReceived: true), "the paid period moved on")
        XCTAssertEqual(after.lastSuccessAt, time("2026-11-02T10:00:00Z"))
        XCTAssertNil(after.clockSkewSeconds)
        let state = LicenseState.of(after, keys: keys, machineID: machineID, at: time("2026-11-02T10:01:00Z"))
        XCTAssertEqual(state.entitlement?.periodEndsAt, time("2026-12-31T00:00:00Z"))
        // The same period again: no payment.
        let again = FakeServer { _ in self.ok(["entitlement": self.document(periodEnds: "2026-12-31T00:00:00Z"), "serverTime": "2026-11-02T11:00:00Z"]) }
        let (_, second) = await client(again).refresh(after, profileCount: 4, wall: Date(), uptime: 1)
        XCTAssertEqual(second, .accepted(paymentReceived: false))
    }

    func testAWorseDocumentReplacesTheBetterOne() async throws {
        let record = try await signedIn()
        let server = FakeServer { _ in
            self.ok(["entitlement": self.document(status: "export_only", reason: "period_ended", periodEnds: "2026-11-01T11:00:00Z",
                                                  issued: "2026-11-02T10:00:00Z"), "serverTime": "2026-11-02T10:00:00Z"])
        }
        let (after, result) = await client(server).refresh(record, profileCount: 2, wall: time("2026-11-02T10:00:00Z"), uptime: 2)
        XCTAssertEqual(result, .accepted(paymentReceived: false))
        let state = LicenseState.of(after, keys: keys, machineID: machineID, at: time("2026-11-02T10:00:00Z"))
        XCTAssertEqual(state.mode, .exportOnly)
        XCTAssertEqual(state.banners, [.periodEnded(owner: true, endedAt: time("2026-11-01T11:00:00Z"))])
    }

    func testTheServerSignsThisMacOutOnlyWithItsTwoFinalAnswers() async throws {
        let record = try await signedIn()
        for (response, reason) in [(error(401, "device_revoked"), SignedOutReason.deviceRevoked),
                                   (error(409, "machine_mismatch"), .machineMismatch)] {
            let server = FakeServer { _ in response }
            let (after, result) = await client(server).refresh(record, profileCount: 2, wall: Date(), uptime: 2)
            XCTAssertEqual(result, .signedOut(reason))
            XCTAssertFalse(after.isSignedIn)
            XCTAssertNil(after.entitlement)
            let state = LicenseState.of(after, keys: keys, machineID: machineID, at: time("2026-11-02T10:00:00Z"))
            XCTAssertEqual(state.mode, .notSignedIn)
            XCTAssertEqual(state.banners.first?.rank, reason == .deviceRevoked ? 1 : 2)
            XCTAssertEqual(state.banners.count, 1, "the reason, not \"sign in\" besides")
        }
        // A 401 of another code does not sign out: the session's, say, is not the device's.
        let server = FakeServer { _ in self.error(401, "unauthorized") }
        let (after, result) = await client(server).refresh(record, profileCount: 2, wall: Date(), uptime: 2)
        XCTAssertEqual(result, .unreachable(retryAfter: nil))
        XCTAssertEqual(after, record)
    }

    func testADocumentThisAppCannotJudgeKeepsTheOldOneAndSaysUpdate() async throws {
        let record = try await signedIn()
        let server = FakeServer { _ in self.ok(["entitlement": self.document(version: 2), "serverTime": "2026-11-02T10:00:00Z"]) }
        let (after, result) = await client(server).refresh(record, profileCount: 2, wall: Date(), uptime: 2)
        XCTAssertEqual(result, .appOutdated)
        XCTAssertTrue(after.appOutdated)
        XCTAssertEqual(after.entitlement, record.entitlement, "the old document stays")
        XCTAssertEqual(after.lastSuccessAt, record.lastSuccessAt, "the license was not checked")
        // Full by the old document, then GRACE saying "update", then export-only.
        func state(_ t: String) -> LicenseState { LicenseState.of(after, keys: keys, machineID: machineID, at: time(t)) }
        XCTAssertEqual(state("2026-11-03T00:00:00Z").banners, [.appOutdated])
        XCTAssertEqual(state("2026-11-06T00:00:00Z").banners.first,
                       .grace(outdated: true, lastSuccessAt: time("2026-11-01T10:00:00Z"), until: time("2026-11-08T10:00:00Z")))
        XCTAssertFalse(state("2026-11-06T00:00:00Z").banners.contains(.appOutdated), "GRACE's text says it already")
        // An accepted document clears it.
        let fresh = FakeServer { _ in self.ok(["entitlement": self.document(issued: "2026-11-02T10:00:00Z"), "serverTime": "2026-11-02T10:00:00Z"]) }
        let (cleared, _) = await client(fresh).refresh(after, profileCount: 2, wall: Date(), uptime: 3)
        XCTAssertFalse(cleared.appOutdated)
    }

    // MARK: Without the server (§9.2, §8.3)

    /// The owner's rule: without the network the app works the whole offline grace and says how
    /// much is left — never "no license" at the first break.
    func testWithoutTheServerTheMacWorksTheWholeGraceAndSaysUntilWhen() async throws {
        var record = try await signedIn()
        let silent = FakeServer { _ in throw NoNetwork() }
        let start = time("2026-11-01T10:00:00Z")
        var uptime: TimeInterval = 1_000
        var modes: [LicenseMode] = []
        for hours in stride(from: 0.0, through: 200, by: 6) {
            let wall = start.addingTimeInterval(hours * 3_600)
            uptime = 1_000 + hours * 3_600
            let (after, result) = await client(silent).refresh(record, profileCount: 2, wall: wall, uptime: uptime)
            XCTAssertEqual(result, .unreachable(retryAfter: nil))
            record = after
            var clock = try XCTUnwrap(record.clock)
            let t = clock.now(wall: wall, uptime: uptime)
            let state = LicenseState.of(record, keys: keys, machineID: machineID, at: t)
            modes.append(state.mode)
            if state.mode.allowsWork {
                XCTAssertEqual(state.worksWithoutServerUntil, time("2026-11-08T10:00:00Z"), "\(hours) h")
            }
        }
        // 4 days full, 3 days grace, then export-only — and nothing in between.
        XCTAssertEqual(modes.prefix(16).allSatisfy { $0 == .full }, true)
        XCTAssertEqual(modes[16..<28].allSatisfy { $0 == .grace }, true)
        XCTAssertEqual(modes[28...].allSatisfy { $0 == .exportOnly }, true)
        XCTAssertEqual(modes.count, 34)
    }

    func testSettingTheClockBackDoesNotStretchTheGrace() async throws {
        let record = try await signedIn()
        var clock = try XCTUnwrap(record.clock)
        // Eight days of uptime pass; the clock is set back to the day of the activation.
        let t = clock.now(wall: time("2026-11-01T10:00:00Z"), uptime: 1_000 + 8 * 86_400)
        XCTAssertEqual(LicenseState.of(record, keys: keys, machineID: machineID, at: t).mode, .exportOnly)
    }

    func testTheDocumentCopiedToAnotherMacDoesNotWorkThere() async throws {
        let record = try await signedIn()
        let otherMac = MachineID.compute(platformUUID: "00000000-0000-0000-0000-000000000001")
        let state = LicenseState.of(record, keys: keys, machineID: otherMac, at: time("2026-11-02T10:00:00Z"))
        XCTAssertEqual(state.check, .wrongDevice)
        XCTAssertEqual(state.mode, .exportOnly)
    }

    // MARK: Signing out (§6.3)

    func testSigningOutHappensHereWhateverTheServerSays() async throws {
        let record = try await signedIn()
        for (answer, confirmed) in [({ () throws -> AccountResponse in AccountResponse(status: 204, body: Data()) }, true),
                                    ({ self.error(401, "device_revoked") }, true),
                                    ({ throw NoNetwork() }, false)] {
            let server = FakeServer { request in
                if request.path == "/v1/auth/logout" { return AccountResponse(status: 204, body: Data()) }
                return try answer()
            }
            let (after, didConfirm) = await client(server).signOut(record)
            XCTAssertEqual(didConfirm, confirmed)
            XCTAssertFalse(after.isSignedIn)
            XCTAssertNil(after.entitlement)
            XCTAssertNil(after.session)
            XCTAssertNil(after.signedOutReason, "signing out is the person's own: no revocation banner")
            XCTAssertEqual(server.requests.map(\.path), ["/v1/device", "/v1/auth/logout"])
            XCTAssertEqual(server.requests.first?.method, .delete)
            XCTAssertEqual(server.requests.first?.bearer?.unredacted(), "lmd_device_token")
        }
    }

    // MARK: Devices

    func testTheDevicesListReadsTheSessionsAndTheKeysAnswers() async throws {
        let list: [String: Any] = ["devices": [["deviceID": deviceID, "code": "B119", "label": "", "mine": true]],
                                   "limit": 3, "used": 1, "unlinkAvailableAt": NSNull(), "unlinkCooldownSeconds": 604_800, "offlineWorkSeconds": 604_800]
        var keyed = list
        keyed["license"] = ["plan": "pro"]
        let server = FakeServer { request in request.path == "/v1/account/devices" ? self.ok(list) : self.ok(keyed) }
        let bySession = try await client(server).devices(.session(ServerToken("lms_s"))).get()
        XCTAssertEqual(bySession.devices.map(\.code), ["B119"])
        let key = try XCTUnwrap(AccountKey(typed: "LMK-0123-4567-89AB-CDEF-GHJK-MNMT"))
        let byKey = try await client(server).devices(.key(key)).get()
        XCTAssertEqual(byKey, bySession)
        XCTAssertEqual(server.requests.last?.method, .post, "the key goes in a body, never in an address")
        XCTAssertFalse(server.requests.last?.path.contains("LMK") ?? true)
        // Unlinking one already unlinked is done.
        let gone = FakeServer { _ in self.error(404, "not_found") }
        let unlinked = await client(gone).unlink(deviceID: "d2", .session(ServerToken("lms_s")))
        XCTAssertNoThrow(try unlinked.get())
        let cooling = FakeServer { _ in self.error(429, "unlink_cooldown", ["availableAt": "2026-11-08T09:00:00Z"]) }
        let refused = await client(cooling).unlink(deviceID: "d2", .session(ServerToken("lms_s")))
        guard case .failure(.server(let error)) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(error.availableAt, time("2026-11-08T09:00:00Z"))
    }
}
