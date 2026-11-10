import CryptoKit
import XCTest
@testable import LumenCore

/// A key of the tests' own and documents signed with it, as the account server signs its own.
struct TestSigner {
    let key = Curve25519.Signing.PrivateKey()
    static let deviceID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    static let machineID = PhoneID.machineID(of: "a-test-iphone")

    var keyID: String { EntitlementKeys.keyID(of: key.publicKey.rawRepresentation) }
    var keys: [String: Data] { [keyID: key.publicKey.rawRepresentation] }

    /// A document's content: issued 1 November 10:00, in force until the 5th, grace until the 8th.
    static func payload(plan: String = "pro", status: String = "active", reason: String? = nil,
                        features: Any? = ["browse", "proxies"], profiles: Int = 50, others: Int = 0,
                        period: String? = "2026-12-01T00:00:00Z") -> [String: Any] {
        var payload: [String: Any] = [
            "kind": "lumen.entitlement", "version": 1, "accountID": "6a1f4f0c-6a8e-4a43-8d51-0c2f2a7b1c11",
            "licenseID": "1d2c3b4a-5f6e-4d7c-8b9a-0a1b2c3d4e5f", "deviceID": deviceID, "machineID": machineID,
            "platform": "ios", "role": "owner", "plan": plan, "status": status,
            "exportReason": reason.map { $0 as Any } ?? NSNull(),
            "limits": ["profiles": profiles, "devices": 3, "seats": 1, "phones": 3], "profilesOnOtherDevices": others,
            "periodEndsAt": period.map { $0 as Any } ?? NSNull(),
            "issuedAt": "2026-11-01T10:00:00Z", "refreshAfter": "2026-11-02T10:00:00Z",
            "expiresAt": "2026-11-05T10:00:00Z", "graceEndsAt": "2026-11-08T10:00:00Z",
        ]
        if let features { payload["features"] = features }
        return payload
    }

    func envelope(_ payload: [String: Any]) -> Data {
        let bytes = try! JSONSerialization.data(withJSONObject: payload)
        let signature = try! key.signature(for: bytes)
        let envelope: [String: Any] = ["format": 1, "keyID": keyID, "payload": bytes.base64EncodedString(),
                                       "signature": signature.base64EncodedString()]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    func check(_ payload: [String: Any]) -> EntitlementCheck {
        EntitlementVerifier.check(envelope(payload), keys: keys, deviceID: Self.deviceID, machineID: Self.machineID)
    }

    func entitlement(_ payload: [String: Any]) -> Entitlement? { check(payload).entitlement }
}

func moment(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// The check of a document of rights (the server's CONTRACT.md §7.4), on the server's own test vectors.
final class EntitlementTests: XCTestCase {
    struct Vectors: Decodable {
        var trustedKeys: [String: String]
        var phoneMachineIDExample: PhoneExample
        var cases: [Case]
    }

    struct PhoneExample: Decodable {
        var keychainID: String
        var machineID: String
    }

    struct Case: Decodable {
        var name: String
        var deviceID: String
        var machineID: String
        var verify: String
        var document: String
        var decisions: [Decision]?
    }

    struct Decision: Decodable {
        var now: String
        var mode: String
        var allowedProfilesHere: Int
    }

    func vectors() throws -> Vectors {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("entitlement-test-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    func testServerVectors() throws {
        let vectors = try vectors()
        let keys = EntitlementKeys.from(vectors.trustedKeys)
        XCTAssertEqual(keys.count, vectors.trustedKeys.count, "each trusted key's id is its key's")
        XCTAssertGreaterThanOrEqual(vectors.cases.count, 19)
        // The iPhone's id as the server computes it from the same identifier (CONTRACT.md §4.1).
        XCTAssertEqual(PhoneID.machineID(of: vectors.phoneMachineIDExample.keychainID), vectors.phoneMachineIDExample.machineID,
                       "the iPhone's id is the server's for the same identifier")
        for vector in vectors.cases {
            let check = EntitlementVerifier.check(Data(vector.document.utf8), keys: keys, deviceID: vector.deviceID, machineID: vector.machineID)
            XCTAssertEqual(check.name, vector.verify, vector.name)
        }
    }

    /// The server's decisions in time: in force, in grace, over. (A Mac's "export only" is, on an
    /// iPhone, either a document that is no longer in force or one whose status says so.)
    func testDecisionsInTimeOnTheServersVectors() throws {
        let vectors = try vectors()
        let keys = EntitlementKeys.from(vectors.trustedKeys)
        var decided = 0
        for vector in vectors.cases {
            guard let decisions = vector.decisions else { continue }
            let checked = EntitlementVerifier.check(Data(vector.document.utf8), keys: keys, deviceID: vector.deviceID, machineID: vector.machineID)
            guard let p = checked.entitlement else { XCTFail("\(vector.name) is valid"); continue }
            for decision in decisions {
                let state = License.state(signedIn: true, entitlement: p, at: moment(decision.now))
                let what = "\(vector.name) at \(decision.now)"
                switch decision.mode {
                case "full": XCTAssertEqual(state.mode, .full, what)
                case "grace": XCTAssertEqual(state.mode, .grace, what)
                default: XCTAssertTrue(p.status == .exportOnly || state.mode == .unreachable || state.mode == .periodEnded, what)
                }
                XCTAssertEqual(p.allowedProfilesHere, decision.allowedProfilesHere, what)
                // The rights are the document's features: every plan that runs (the trial, Personal,
                // Professional, a member of a Team) opens sites and proxies; a period that ended, neither.
                if decision.mode == "full" || decision.mode == "grace" {
                    XCTAssertTrue(state.access.browse && state.access.proxies, "\(what): a running plan opens sites and proxies")
                    XCTAssertEqual(state.access.plan, p.plan, what)
                    XCTAssertEqual(state.access.maxProfiles, decision.allowedProfilesHere, what)
                } else {
                    XCTAssertFalse(state.access.proxies, "\(what): no proxies")
                }
                // The iPhone's own documents (CONTRACT.md §8.4а): decided by features, not by the status.
                switch vector.name {
                case "ios_free", "ios_period_ended":
                    XCTAssertTrue(state.access.browse, "\(what): the free level opens sites")
                    XCTAssertEqual(state.access.maxProfiles, 2, what)
                    XCTAssertEqual(SessionLock.of(Session(name: "Чистый"), proxyExists: false, access: state.access), .open, what)
                    XCTAssertTrue(SessionLock.of(Session(name: "Счета", proxyID: UUID()), proxyExists: true, access: state.access).isLocked, what)
                    XCTAssertEqual(state.access.plan, vector.name == "ios_free" ? "free" : "expired", what)
                case "ios_account_disabled":
                    XCTAssertFalse(state.access.browse, "\(what): a blocked account opens no sites")
                    XCTAssertTrue(SessionLock.of(Session(name: "Чистый"), proxyExists: false, access: state.access).isLocked,
                                  "\(what): a blocked account opens no profile — unlike the free level")
                    XCTAssertEqual(state.access.plan, "disabled", what)
                default: break
                }
                decided += 1
            }
        }
        XCTAssertGreaterThanOrEqual(decided, 15)
        XCTAssertEqual(Set(vectors.cases.map(\.name)).intersection(["ios_active", "ios_free", "ios_period_ended", "ios_account_disabled", "ios_on_another_phone"]).count, 5,
                       "the iPhone's five vectors are there")
        var plans: Set<String> = []
        for vector in vectors.cases where vector.verify == "ok" {
            let checked = EntitlementVerifier.check(Data(vector.document.utf8), keys: keys, deviceID: vector.deviceID, machineID: vector.machineID)
            if let p = checked.entitlement, p.status == .active { plans.insert(p.plan) }
        }
        XCTAssertEqual(plans, ["trial", "personal", "pro", "team"], "the vectors have a running document of every plan")
    }

    func testKeysAndThePhonesID() {
        let signer = TestSigner()
        let raw = signer.key.publicKey.rawRepresentation
        XCTAssertEqual(signer.keyID.count, 16)
        XCTAssertEqual(EntitlementKeys.from([signer.keyID: raw.base64EncodedString()]).count, 1)
        XCTAssertTrue(EntitlementKeys.from(["0000000000000000": raw.base64EncodedString()]).isEmpty, "an id that is not its key's is left out")
        XCTAssertTrue(EntitlementKeys.from([signer.keyID: "not a key"]).isEmpty)
        // docs/IPHONE.md §2.1: SHA-256("lumen.machine-id.ios.v1\n" + id), in lowercase hex.
        XCTAssertEqual(PhoneID.machineID(of: "5f1c0e9a7b3d4c2e8a6f0b1d3c5e7f9a1b2c3d4e5f60718293a4b5c6d7e8f901"),
                       "c36244f2711359caae7afbf37eefafe58aaf08f0d97f2a0b6e0a31e25ce91260")
        let a = PhoneID.random(), b = PhoneID.random()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b, "each iPhone makes its own identifier")
    }
}

/// What an iPhone may do, from the document's features and limits (the owner and the lead, 9 November).
final class LicenseTests: XCTestCase {
    let signer = TestSigner()
    let inForce = moment("2026-11-02T00:00:00Z")

    func state(_ payload: [String: Any], at t: Date? = nil) -> LicenseState {
        License.state(signedIn: true, entitlement: signer.entitlement(payload), at: t ?? inForce)
    }

    func testUnknownFeaturesArePassedOver() {
        let payload = TestSigner.payload(features: ["browse", "proxies", "automation", "hologram"])
        XCTAssertEqual(signer.check(payload).name, "ok", "a feature this app does not know breaks nothing")
        let access = state(payload).access
        XCTAssertTrue(access.browse)
        XCTAssertTrue(access.proxies)
    }

    func testRightsComeFromFeatures() {
        // A paid plan whose document names no proxies has none, whatever the plan is called.
        let browseOnly = state(TestSigner.payload(plan: "pro", features: ["browse"])).access
        XCTAssertFalse(browseOnly.proxies, "no \"proxies\" in the features: no proxies")
        XCTAssertTrue(browseOnly.browse)
        XCTAssertEqual(browseOnly.reason, "В вашем тарифе нет прокси.")
        // No list at all, or something that is not a list of names: nothing is open.
        let none = state(TestSigner.payload(features: nil)).access
        XCTAssertFalse(none.browse, "no features: no right to open sites")
        XCTAssertFalse(none.proxies)
        XCTAssertFalse(state(TestSigner.payload(features: "browse,proxies")).access.browse, "not a list: nothing")
        XCTAssertTrue(SessionLock.of(Session(name: "Любой"), proxyExists: false, access: none).isLocked, "without \"browse\" no profile opens")
        // The trial has both while it runs.
        let trial = state(TestSigner.payload(plan: "trial", features: ["browse", "proxies"], profiles: 3)).access
        XCTAssertTrue(trial.proxies)
        XCTAssertEqual(trial.plan, "trial")
        XCTAssertEqual(trial.maxProfiles, 3)
        XCTAssertNil(trial.reason)
    }

    func testTheFreeLevelComesFromTheDocument() {
        // Signed in without a plan: the server writes the free level into the document — and the
        // count is read from there (3 here, on purpose not the app's own 2).
        let free = state(TestSigner.payload(plan: "none", status: "export_only", reason: "no_license", features: ["browse"],
                                            profiles: 3, period: nil))
        XCTAssertEqual(free.access.maxProfiles, 3, "the profile count is the document's")
        XCTAssertEqual(free.mode, .full)
        XCTAssertTrue(free.access.browse)
        XCTAssertFalse(free.access.proxies)
        XCTAssertEqual(free.access.plan, "free")
        XCTAssertEqual(free.access.reason, "Прокси недоступны.")
        XCTAssertNil(free.access.paidPlanTitle, "no plan is named to an account that has paid for none")
        XCTAssertNil(Access.free.paidPlanTitle)
        XCTAssertNil(Access.expired.paidPlanTitle)
        XCTAssertEqual(state(TestSigner.payload(plan: "pro")).access.paidPlanTitle, "Профессиональный")
        XCTAssertEqual(state(TestSigner.payload(plan: "trial")).access.paidPlanTitle, "7 дней бесплатно")
        // A paid period that ended, as the server says it.
        let ended = state(TestSigner.payload(plan: "personal", status: "export_only", reason: "period_ended", features: ["browse"],
                                             profiles: 2, period: "2026-10-31T00:00:00Z")).access
        XCTAssertEqual(ended.plan, "expired")
        XCTAssertFalse(ended.proxies)
        XCTAssertTrue(SessionLock.of(Session(name: "Счета", proxyID: UUID()), proxyExists: true, access: ended).isLocked,
                      "a profile that lived behind a proxy stays locked")
        // A blocked account: nothing opens.
        let disabled = state(TestSigner.payload(status: "export_only", reason: "account_disabled", features: [String]())).access
        XCTAssertFalse(disabled.browse)
        XCTAssertEqual(disabled.reason, "Аккаунт заблокирован, напишите в поддержку.")
    }

    func testADocumentRunsOut() {
        let payload = TestSigner.payload()
        XCTAssertEqual(state(payload, at: moment("2026-11-05T09:59:59Z")).mode, .full)
        let grace = state(payload, at: moment("2026-11-05T10:00:00Z"))
        XCTAssertEqual(grace.mode, .grace)
        XCTAssertTrue(grace.access.proxies, "in grace the rights are the document's still")
        let over = state(payload, at: moment("2026-11-08T10:00:00Z"))
        XCTAssertEqual(over.mode, .unreachable, "past the document's last day it gives nothing")
        XCTAssertFalse(over.access.proxies)
        XCTAssertEqual(over.access.maxProfiles, Access.freeProfiles)
        // The paid period ends before the document does: what it opened ends with it.
        let short = TestSigner.payload(period: "2026-11-03T00:00:00Z")
        XCTAssertEqual(state(short, at: moment("2026-11-02T23:59:59Z")).mode, .full)
        let ended = state(short, at: moment("2026-11-03T00:00:00Z"))
        XCTAssertEqual(ended.mode, .periodEnded)
        XCTAssertFalse(ended.access.proxies)
    }

    func testNotSignedInAndUnverified() {
        let out = License.state(signedIn: false, entitlement: nil, at: inForce)
        XCTAssertEqual(out.mode, .notSignedIn)
        XCTAssertEqual(out.access, Access.free, "not signed in: the free level by the app's own rule")
        let unverified = License.state(signedIn: true, entitlement: nil, at: inForce)
        XCTAssertEqual(unverified.mode, .unverified)
        XCTAssertFalse(unverified.access.proxies)
        XCTAssertTrue(unverified.access.browse)
        XCTAssertEqual(unverified.access.maxProfiles, Access.freeProfiles)
    }

    func testTheClockSetBackBringsNothingBack() {
        // Five days on: the document (in force until the 5th, grace until the 8th) is in its grace.
        let start = moment("2026-11-01T10:00:00Z")
        var clock = EffectiveClock(floorTime: start, floorUptime: 1_000)
        let later = clock.now(wall: start.addingTimeInterval(5 * 86_400), uptime: 1_000 + 5 * 86_400)
        XCTAssertEqual(later, start.addingTimeInterval(5 * 86_400))
        // The clock set back by six days, a minute later.
        let back = clock.now(wall: start.addingTimeInterval(-86_400), uptime: 1_000 + 5 * 86_400 + 60)
        XCTAssertEqual(back, start.addingTimeInterval(5 * 86_400 + 60), "the clock set back does not bring time back")
        // After a restart (the uptime starts again) the floor stays where it was.
        XCTAssertEqual(clock.now(wall: start, uptime: 5), back)
        // So the document is still in its grace, not in force again as the bare clock would have it.
        XCTAssertEqual(state(TestSigner.payload(), at: back).mode, .grace)
        XCTAssertEqual(state(TestSigner.payload(), at: start.addingTimeInterval(-86_400)).mode, .full)
    }

    func testProfilesOverTheLimitAreLocked() {
        let base = moment("2026-11-01T10:00:00Z")
        let sessions = (0..<4).map { Session(name: "П\($0)", createdAt: base.addingTimeInterval(Double($0) * 60)) }
        let open = License.withinLimit(sessions.reversed(), allowed: 2)
        XCTAssertEqual(open, Set(sessions.prefix(2).map(\.id)), "the two made first stay open, the rest are over the limit")
        XCTAssertEqual(License.withinLimit(sessions, allowed: nil).count, 4, "no limit: all")
        XCTAssertTrue(License.withinLimit(sessions, allowed: 0).isEmpty)
        let over = SessionLock.of(sessions[3], proxyExists: false, access: .free, overLimit: true)
        XCTAssertEqual(over, .locked(reason: "Профиль сверх числа профилей тарифа (2). Он и его данные сохранены."))
        XCTAssertEqual(SessionLock.of(sessions[0], proxyExists: false, access: .free, overLimit: false), .open)
    }

    func testAnActivationSaysItIsAnIPhone() throws {
        let body = AccountWire.deviceBody(machineID: TestSigner.machineID, profileCount: 2, appVersion: "0.1.0 (1)")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["platform"] as? String, "ios", "the activation names its platform")
        XCTAssertEqual(object["machineID"] as? String, TestSigner.machineID)
        XCTAssertEqual(object["profileCount"] as? Int, 2)
        XCTAssertEqual(object["appVersion"] as? String, "0.1.0 (1)")
        XCTAssertNil(object["label"], "no label: nothing the person did not type goes to the server")
        let login = try XCTUnwrap(JSONSerialization.jsonObject(with: AccountWire.loginBody(email: "a@b.c", password: "p", robotToken: nil)) as? [String: Any])
        XCTAssertEqual(Set(login.keys), ["email", "password"])
    }

    func testRefusalsAreSaidWithTheirReason() throws {
        // A Mac's refusal is not the phones' limit: it has no number to show an iPhone.
        let mac = try XCTUnwrap(AccountWire.refusal(Data(#"{"error":{"code":"device_limit_reached","devices":[{"code":"A001"}]}}"#.utf8)))
        XCTAssertNil(mac.phones)
        XCTAssertEqual(AccountText.refusal(mac), "Что-то пошло не так.")
        let limit = try XCTUnwrap(AccountWire.refusal(Data(#"{"error":{"code":"phone_limit_reached","message":"x","limits":{"phones":3}}}"#.utf8)))
        XCTAssertEqual(AccountText.refusal(limit),
                       "К этой лицензии уже подключено наибольшее число iPhone (3). Отключите один из них в кабинете на сайте и войдите снова.",
                       "the limit of phones is said with its reason")
        let busy = try XCTUnwrap(AccountWire.refusal(Data(#"{"error":{"code":"rate_limited","retryAfter":90}}"#.utf8)))
        XCTAssertEqual(AccountText.refusal(busy), "Слишком много попыток. Повторите через 2 минуты.")
        XCTAssertEqual(AccountText.refusal(AccountWire.Refusal(code: "invalid_credentials", retryAfter: nil, phones: nil)), "Неверная почта или пароль.")
        XCTAssertNil(AccountWire.refusal(Data("<html><body>Sign in to the Wi-Fi</body></html>".utf8)), "a captive portal's page is not the server's answer")
        XCTAssertEqual(AccountText.duration(1), "1 секунду")
        XCTAssertEqual(AccountText.duration(45), "45 секунд")
        XCTAssertEqual(AccountText.duration(3_600), "1 час")
    }

    func testTheRecordIsKeptAsItWas() throws {
        let record = AccountRecord(email: "anna@example.com", deviceID: TestSigner.deviceID, code: "B119", deviceToken: "lmd_x",
                                   entitlement: signer.envelope(TestSigner.payload()),
                                   clock: EffectiveClock(floorTime: inForce, floorUptime: 12), lastSuccessAt: inForce)
        let again = try JSONDecoder().decode(AccountRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(again, record)
        let document = try XCTUnwrap(again.entitlement)
        XCTAssertEqual(EntitlementVerifier.check(document, keys: signer.keys, deviceID: again.deviceID, machineID: TestSigner.machineID).name, "ok")
        XCTAssertEqual(RefreshSchedule.retryDelay(afterFailures: 1), 60)
        XCTAssertEqual(RefreshSchedule.retryDelay(afterFailures: 9), 3_600)
        XCTAssertTrue(RefreshSchedule.refreshDue(entitlement: nil, at: inForce))
    }
}
