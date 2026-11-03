#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import BrowserCore
import Foundation
import XCTest

/// The licensing client's core against the server's own test vectors (`Fixtures/entitlement-test-
/// vectors.json`, a copy of the server's `docs/entitlement-test-vectors.json`, which its tests check
/// is what its code produces) and the cases the vectors leave out.
final class LicenseTests: XCTestCase {
    // MARK: The server's vectors

    private struct Vectors: Decodable {
        struct MachineIDExample: Decodable {
            let ioPlatformUUID: String
            let machineID: String
        }

        struct Decision: Decodable {
            let now: String
            let mode: String
            let allowedProfilesHere: Int
        }

        struct Case: Decodable {
            let name: String
            let document: String
            let deviceID: String
            let machineID: String
            let verify: String
            let decisions: [Decision]?
        }

        let trustedKeys: [String: String]
        let machineIDExample: MachineIDExample
        let cases: [Case]
    }

    private func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/entitlement-test-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func time(_ text: String) throws -> Date {
        try Date.ISO8601FormatStyle().parse(text)
    }

    func testEveryVectorChecksAndDecidesAsTheServerSays() throws {
        let vectors = try vectors()
        let keys = EntitlementKeys.fromInfoPlist(vectors.trustedKeys)
        XCTAssertEqual(keys.count, vectors.trustedKeys.count, "every trusted key of the vectors is a key under its own id")
        XCTAssertGreaterThanOrEqual(vectors.cases.count, 11)
        var decided = 0
        for vector in vectors.cases {
            let check = EntitlementVerifier.check(Data(vector.document.utf8), keys: keys, deviceID: vector.deviceID, machineID: vector.machineID)
            XCTAssertEqual(check.name, vector.verify, vector.name)
            for decision in vector.decisions ?? [] {
                let entitlement = try XCTUnwrap(check.entitlement, vector.name)
                let mode = LicenseDecision.mode(signedIn: true, entitlement: entitlement, at: try time(decision.now))
                XCTAssertEqual(mode.rawValue, decision.mode, "\(vector.name) at \(decision.now)")
                XCTAssertEqual(LicenseDecision.allowedProfilesHere(entitlement), decision.allowedProfilesHere, "\(vector.name) at \(decision.now)")
                decided += 1
            }
        }
        XCTAssertGreaterThanOrEqual(decided, 8, "the vectors' decisions were all made")
    }

    func testMachineIDIsTheContractsExample() throws {
        let example = try vectors().machineIDExample
        XCTAssertEqual(MachineID.compute(platformUUID: example.ioPlatformUUID), example.machineID)
        // Upper case is the input's, whatever the system gave.
        XCTAssertEqual(MachineID.compute(platformUUID: example.ioPlatformUUID.lowercased()), example.machineID)
        XCTAssertEqual(example.machineID, "06c813ff32b6377da5e4cb44a251d928985db83c18bed852efa4af0e3abd23ac")
    }

    // MARK: Cases the vectors leave out

    private let deviceID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    private let machineID = String(repeating: "ab", count: 32)
    private let signer = Curve25519.Signing.PrivateKey()

    private var keys: [String: Data] {
        let raw = signer.publicKey.rawRepresentation
        return [EntitlementKeys.keyID(of: raw): raw]
    }

    private func payload(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "kind": "lumen.entitlement", "version": 1, "documentID": "d", "accountID": "a", "licenseID": "l",
            "deviceID": deviceID, "machineID": machineID, "role": "owner", "plan": "pro", "status": "active",
            "exportReason": NSNull(), "limits": ["profiles": 50, "devices": 3, "seats": 1], "profilesOnOtherDevices": 12,
            "periodEndsAt": "2026-12-01T00:00:00Z", "issuedAt": "2026-11-01T10:00:00Z", "refreshAfter": "2026-11-02T10:00:00Z",
            "expiresAt": "2026-11-05T10:00:00Z", "graceEndsAt": "2026-11-08T10:00:00Z",
        ]
        for (name, value) in changes {
            if let value { fields[name] = value } else { fields.removeValue(forKey: name) }
        }
        return fields
    }

    private func document(_ payload: [String: Any], format: Any = 1, keyID: String? = nil, signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        let key = signer ?? self.signer
        let envelope: [String: Any] = [
            "format": format, "keyID": keyID ?? EntitlementKeys.keyID(of: key.publicKey.rawRepresentation),
            "payload": bytes.base64EncodedString(), "signature": try key.signature(for: bytes).base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    private func check(_ data: Data) -> EntitlementCheck {
        EntitlementVerifier.check(data, keys: keys, deviceID: deviceID, machineID: machineID)
    }

    func testAValidDocumentReadsEveryField() throws {
        let entitlement = try XCTUnwrap(check(try document(payload())).entitlement)
        XCTAssertEqual(entitlement.plan, "pro")
        XCTAssertTrue(entitlement.isOwner)
        XCTAssertEqual(entitlement.limits, Entitlement.Limits(profiles: 50, devices: 3, seats: 1))
        XCTAssertEqual(entitlement.periodEndsAt, try time("2026-12-01T00:00:00Z"))
        XCTAssertEqual(entitlement.offlineWork, 7 * 86_400)
        // Unknown fields are ignored (§2, §13).
        XCTAssertNotNil(check(try document(payload(["somethingNew": ["a": 1]]))).entitlement)
    }

    func testACountdownSaysTheTwoLargestUnitsRoundedDown() {
        func said(_ seconds: TimeInterval) -> String {
            Countdown.parts(seconds).map { "\($0.value) \($0.unit.rawValue)" }.joined(separator: " ")
        }
        // The account page's case (CI run 586): 10020 minutes left.
        XCTAssertEqual(said(10_020 * 60), "6 day 23 hour")
        XCTAssertEqual(said(7 * 86_400), "7 day")
        XCTAssertEqual(said(86_400 + 59 * 60), "1 day")
        XCTAssertEqual(said(90 * 60), "1 hour 30 minute")
        XCTAssertEqual(said(2 * 3_600), "2 hour")
        XCTAssertEqual(said(59 * 60 + 59), "59 minute")
        // Never less than a minute, nor nothing: the moment is reached when the mode changes.
        XCTAssertEqual(said(59), "1 minute")
        XCTAssertEqual(said(0), "1 minute")
        XCTAssertEqual(said(-3_600), "1 minute")
        XCTAssertEqual(said(.infinity), "1 minute")
    }

    func testEachStepRefusesWhatItMust() throws {
        // 1. Not an object, no format, a format that is not a whole number.
        XCTAssertEqual(check(Data("[1]".utf8)), .notADocument)
        XCTAssertEqual(check(Data("{}".utf8)), .notADocument)
        XCTAssertEqual(check(try document(payload(), format: "1")), .notADocument)
        XCTAssertEqual(check(try document(payload(), format: 1.5)), .notADocument)
        XCTAssertEqual(check(Data("404 page not found".utf8)), .notADocument)
        // 2. A newer format, whatever else it holds.
        XCTAssertEqual(check(Data(#"{"format": 2, "anything": true}"#.utf8)), .newerFormat)
        // 3. Format 0, an empty payload, not base64.
        XCTAssertEqual(check(try document(payload(), format: 0)), .notADocument)
        XCTAssertEqual(check(Data(#"{"format":1,"keyID":"x","payload":"","signature":""}"#.utf8)), .notADocument)
        XCTAssertEqual(check(Data(#"{"format":1,"keyID":"x","payload":"%%%","signature":"AA=="}"#.utf8)), .notADocument)
        // 4. A key this app does not carry.
        XCTAssertEqual(check(try document(payload(), keyID: "0000000000000000")), .unknownKey)
        // 5. Another key under a trusted id.
        XCTAssertEqual(check(try document(payload(), keyID: keys.keys.first!, signer: Curve25519.Signing.PrivateKey())), .badSignature)
        // 6. Another kind; a newer version; a payload that is no object.
        XCTAssertEqual(check(try document(payload(["kind": "lumen.other"]))), .wrongKind)
        XCTAssertEqual(check(try document(payload(["kind": nil]))), .wrongKind)
        XCTAssertEqual(check(try document(payload(["version": 2]))), .newerVersion)
        // 7. Another device, another Mac.
        XCTAssertEqual(check(try document(payload(["deviceID": "00000000-0000-0000-0000-000000000000"]))), .wrongDevice)
        XCTAssertEqual(check(try document(payload(["machineID": String(repeating: "0", count: 64)]))), .wrongDevice)
        XCTAssertEqual(check(try document(payload(["machineID": nil]))), .wrongDevice)
        // 8. A status of no meaning, an unreadable time, a missing limit, fractions of a second.
        XCTAssertEqual(check(try document(payload(["status": "maybe"]))), .malformed)
        XCTAssertEqual(check(try document(payload(["expiresAt": "tomorrow"]))), .malformed)
        XCTAssertEqual(check(try document(payload(["graceEndsAt": nil]))), .malformed)
        XCTAssertEqual(check(try document(payload(["limits": ["profiles": 50]]))), .malformed)
        XCTAssertEqual(check(try document(payload(["issuedAt": "2026-11-01T10:00:00.500Z"]))), .malformed)
        // Every other form a parser may take besides (macOS's took the fraction above, CI run 578).
        for other in ["2026-11-01T10:00:00+00:00", "2026-11-01 10:00:00Z", "2026-11-01T10:00Z", "2026-11-01t10:00:00z",
                      "2026-11-01T10:00:00.5Z", "20261101T100000Z", " 2026-11-01T10:00:00Z", "２０２6-11-01T10:00:00Z"] {
            XCTAssertEqual(check(try document(payload(["refreshAfter": other]))), .malformed, other)
        }
        XCTAssertEqual(check(try document(payload(["periodEndsAt": 5]))), .malformed)
        // A period that never was is not malformed: it decides export-only (§8.2).
        let noPeriod = try XCTUnwrap(check(try document(payload(["periodEndsAt": NSNull()]))).entitlement)
        XCTAssertNil(noPeriod.periodEndsAt)
        XCTAssertEqual(LicenseDecision.mode(signedIn: true, entitlement: noPeriod, at: try time("2026-11-01T10:00:00Z")), .exportOnly)
    }

    func testAStoredEnvelopeChecksAsTheDocumentItCameFrom() throws {
        let data = try document(payload())
        let envelope = try XCTUnwrap(EntitlementVerifier.envelope(of: data))
        let stored = try JSONEncoder().encode(envelope)
        XCTAssertEqual(EntitlementVerifier.check(stored, keys: keys, deviceID: deviceID, machineID: machineID), check(data))
        XCTAssertEqual(EntitlementVerifier.check(envelope, keys: keys, deviceID: deviceID, machineID: machineID), check(data))
        var tampered = envelope
        tampered.payload[tampered.payload.startIndex] ^= 1
        XCTAssertEqual(EntitlementVerifier.check(tampered, keys: keys, deviceID: deviceID, machineID: machineID), .badSignature)
    }

    func testOnlyTheUpdateRefusalsMeanTheAppIsOutdated() {
        let outdated: [EntitlementCheck] = [.unknownKey, .newerFormat, .newerVersion]
        let unreachable: [EntitlementCheck] = [.notADocument, .badSignature, .wrongKind, .wrongDevice, .malformed]
        XCTAssertTrue(outdated.allSatisfy(\.meansAppOutdated))
        XCTAssertFalse(unreachable.contains(where: \.meansAppOutdated))
    }

    func testTheDevelopmentKeyIsAKeyUnderItsOwnID() {
        let keys = EntitlementKeys.fromInfoPlist([EntitlementKeys.developmentKeyID: EntitlementKeys.developmentPublicKey])
        XCTAssertEqual(Array(keys.keys), [EntitlementKeys.developmentKeyID])
        // An entry whose id is not its key's is left out.
        XCTAssertTrue(EntitlementKeys.fromInfoPlist(["0000000000000000": EntitlementKeys.developmentPublicKey]).isEmpty)
    }

    // MARK: The decision (§8.2–§8.4)

    private func entitlement(status: Entitlement.Status = .active, periodEnds: String? = "2026-12-01T00:00:00Z",
                             plan: String = "pro", role: String = "owner", reason: String? = nil,
                             limit: Int = 10, others: Int = 0) throws -> Entitlement {
        Entitlement(deviceID: deviceID, machineID: machineID, role: role, plan: plan, status: status, exportReason: reason,
                    limits: .init(profiles: limit, devices: 2, seats: 1), profilesOnOtherDevices: others,
                    periodEndsAt: try periodEnds.map(time), issuedAt: try time("2026-11-01T10:00:00Z"),
                    refreshAfter: try time("2026-11-02T10:00:00Z"), expiresAt: try time("2026-11-05T10:00:00Z"),
                    graceEndsAt: try time("2026-11-08T10:00:00Z"))
    }

    func testTheDecisionFollowsTheContractsOrder() throws {
        let t = try time("2026-11-03T00:00:00Z")
        XCTAssertEqual(LicenseDecision.mode(signedIn: false, entitlement: try entitlement(), at: t), .notSignedIn)
        XCTAssertEqual(LicenseDecision.mode(signedIn: true, entitlement: nil, at: t), .exportOnly)
        XCTAssertEqual(LicenseDecision.mode(signedIn: true, entitlement: try entitlement(status: .exportOnly), at: t), .exportOnly)
        XCTAssertEqual(LicenseDecision.mode(signedIn: true, entitlement: try entitlement(), at: t), .full)
        // The period ends before the grace does: export-only from the period's end, on this Mac's own time.
        let early = try entitlement(periodEnds: "2026-11-06T00:00:00Z")
        XCTAssertEqual(LicenseDecision.mode(signedIn: true, entitlement: early, at: try time("2026-11-05T12:00:00Z")), .grace)
        XCTAssertEqual(LicenseDecision.mode(signedIn: true, entitlement: early, at: try time("2026-11-06T00:00:00Z")), .exportOnly)
        XCTAssertEqual(LicenseDecision.graceDate(early), try time("2026-11-06T00:00:00Z"))
        XCTAssertEqual(LicenseDecision.graceDate(try entitlement()), try time("2026-11-08T10:00:00Z"))
    }

    func testWorkWithoutTheServerEndsAtTheGraceDate() throws {
        let p = try entitlement()
        XCTAssertEqual(LicenseDecision.worksWithoutServerUntil(mode: .full, entitlement: p), try time("2026-11-08T10:00:00Z"))
        XCTAssertEqual(LicenseDecision.worksWithoutServerUntil(mode: .grace, entitlement: p), try time("2026-11-08T10:00:00Z"))
        XCTAssertNil(LicenseDecision.worksWithoutServerUntil(mode: .exportOnly, entitlement: p))
        XCTAssertNil(LicenseDecision.worksWithoutServerUntil(mode: .notSignedIn, entitlement: p))
    }

    func testTheLimitOpensTheOldestProfilesFully() throws {
        let base = try time("2026-01-01T00:00:00Z")
        let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
        let profiles = [(id: c, createdAt: base), (id: b, createdAt: base), (id: a, createdAt: base.addingTimeInterval(60))]
        // The same moment is broken by the id: b before c; a is the newest.
        XCTAssertEqual(LicenseDecision.fullyOpen(profiles, allowed: 2), [b, c])
        XCTAssertEqual(LicenseDecision.fullyOpen(profiles, allowed: 0), [])
        XCTAssertEqual(LicenseDecision.fullyOpen(profiles, allowed: -3), [])
        XCTAssertEqual(LicenseDecision.fullyOpen(profiles, allowed: 9), [a, b, c])
        let p = try entitlement(limit: 10, others: 7)
        XCTAssertTrue(LicenseDecision.canCreateProfile(mode: .full, entitlement: p, profilesHere: 2))
        XCTAssertFalse(LicenseDecision.canCreateProfile(mode: .full, entitlement: p, profilesHere: 3))
        XCTAssertFalse(LicenseDecision.canCreateProfile(mode: .exportOnly, entitlement: p, profilesHere: 0))
        XCTAssertTrue(LicenseDecision.canCreateProfile(mode: .grace, entitlement: p, profilesHere: 0))
    }

    // MARK: The effective time (§8.3)

    func testSettingTheClockBackDoesNotBringTimeBack() throws {
        let start = try time("2026-11-01T10:00:00Z")
        var clock = EffectiveClock.reset(serverTime: start, uptime: 1_000)
        // An hour later by uptime, the clock set back a day: the hour counts, the day does not.
        XCTAssertEqual(clock.now(wall: start.addingTimeInterval(-86_400), uptime: 4_600), start.addingTimeInterval(3_600))
        // Restarted (uptime from 0), the clock still back: the floor holds.
        XCTAssertEqual(clock.now(wall: start.addingTimeInterval(-86_400), uptime: 50), start.addingTimeInterval(3_600))
        // The clock ahead of the floor: the clock.
        XCTAssertEqual(clock.now(wall: start.addingTimeInterval(7_200), uptime: 60), start.addingTimeInterval(7_200))
        XCTAssertNil(EffectiveClock.skew(wall: start.addingTimeInterval(600), serverTime: start))
        XCTAssertEqual(EffectiveClock.skew(wall: start.addingTimeInterval(-7_200), serverTime: start), 7_200)
    }

    func testRetriesSlowDownToHourly() {
        XCTAssertEqual((1...7).map(RefreshSchedule.retryDelay(afterFailures:)), [60, 300, 900, 1_800, 3_600, 3_600, 3_600])
    }

    // MARK: Banners (§8.5)

    func testOneBannerPerConditionInTheContractsOrder() throws {
        let t = try time("2026-11-06T00:00:00Z")
        let ending = try entitlement(periodEnds: "2026-11-06T12:00:00Z")
        let banners = LicenseBanners.banners(.init(mode: .grace, entitlement: ending, appOutdated: true, lastSuccessAt: t,
                                                   clockSkew: 7_200, now: t))
        XCTAssertEqual(banners.map(\.rank), [7, 9, 10])
        guard case .grace(let outdated, _, let until) = banners[0], case .periodEnding(_, _, let final) = banners[2] else {
            return XCTFail("\(banners)")
        }
        XCTAssertTrue(outdated)
        XCTAssertEqual(until, try time("2026-11-06T12:00:00Z"))
        XCTAssertTrue(final, "less than a day left: the last warning")
        // The revocation is the reason: "sign in" is not said twice.
        XCTAssertEqual(LicenseBanners.banners(.init(mode: .notSignedIn, entitlement: nil, signedOutReason: .deviceRevoked, now: t)), [.deviceRevoked])
        XCTAssertEqual(LicenseBanners.banners(.init(mode: .notSignedIn, entitlement: nil, now: t)), [.notSignedIn])
    }

    func testTheWarningsStartAWeekAndADayBefore() throws {
        let end = try time("2026-12-01T00:00:00Z")
        let p = try entitlement()
        func warning(daysLeft: Double) -> LicenseBanner? {
            LicenseBanners.banners(.init(mode: .full, entitlement: p, now: end.addingTimeInterval(-daysLeft * 86_400)))
                .first { $0.rank == 10 }
        }
        XCTAssertNil(warning(daysLeft: 7.1))
        XCTAssertEqual(warning(daysLeft: 6.9), .periodEnding(owner: true, endsAt: end, final: false))
        XCTAssertEqual(warning(daysLeft: 1.1), .periodEnding(owner: true, endsAt: end, final: false))
        XCTAssertEqual(warning(daysLeft: 0.9), .periodEnding(owner: true, endsAt: end, final: true))
    }

    func testExportOnlyNamesItsReason() throws {
        let t = try time("2026-11-03T00:00:00Z")
        func banner(_ p: Entitlement) -> [LicenseBanner] { LicenseBanners.banners(.init(mode: .exportOnly, entitlement: p, now: t)) }
        XCTAssertEqual(banner(try entitlement(status: .exportOnly, reason: "account_disabled")), [.accountDisabled])
        XCTAssertEqual(banner(try entitlement(status: .exportOnly, reason: "no_license")), [.noLicense])
        let ended = try entitlement(status: .exportOnly, periodEnds: "2026-11-01T00:00:00Z", role: "member", reason: "something_new")
        XCTAssertEqual(banner(ended), [.periodEnded(owner: false, endedAt: try time("2026-11-01T00:00:00Z"))])
        // Still "active" in the document, but the period ended by this Mac's time.
        let byTime = try entitlement(periodEnds: "2026-11-02T00:00:00Z")
        XCTAssertEqual(banner(byTime), [.periodEnded(owner: true, endedAt: try time("2026-11-02T00:00:00Z"))])
    }

    /// After the grace (the last line of §8.2) the banner says since when the license could not be
    /// checked — and, the app outdated, says that instead of `app.outdated`; with no document that
    /// checks (the second line), `mode.unverified` (§8.5 item 7, contract of 2 November).
    func testExportOnlyAfterTheGraceAndWithoutADocumentSayWhy() throws {
        let afterGrace = try time("2026-11-09T00:00:00Z")
        let p = try entitlement()
        let last = try time("2026-11-01T10:00:00Z")
        XCTAssertEqual(LicenseDecision.mode(signedIn: true, entitlement: p, at: afterGrace), .exportOnly)
        XCTAssertEqual(LicenseBanners.banners(.init(mode: .exportOnly, entitlement: p, lastSuccessAt: last, now: afterGrace)),
                       [.expired(outdated: false, lastSuccessAt: last)])
        XCTAssertEqual(LicenseBanners.banners(.init(mode: .exportOnly, entitlement: p, appOutdated: true, lastSuccessAt: last, now: afterGrace)),
                       [.expired(outdated: true, lastSuccessAt: last)], "says \"update\" itself: no app.outdated beside it")
        XCTAssertEqual(LicenseBanners.banners(.init(mode: .exportOnly, entitlement: nil, now: afterGrace)), [.unverified])
        XCTAssertEqual(LicenseBanners.banners(.init(mode: .exportOnly, entitlement: nil, appOutdated: true, now: afterGrace)),
                       [.unverified, .appOutdated])
        // A reason of the document's own is still said as before, not as "expired".
        XCTAssertEqual(LicenseBanners.banners(.init(mode: .exportOnly, entitlement: try entitlement(status: .exportOnly, reason: "no_license"),
                                                    appOutdated: true, now: afterGrace)), [.noLicense, .appOutdated])
        XCTAssertEqual(LicenseBanner.expired(outdated: false, lastSuccessAt: nil).rank, LicenseBanner.unverified.rank)
        // Both stop work, as the reasons of §8.5's 1–6 do; GRACE and the warnings do not.
        XCTAssertTrue(LicenseBanner.expired(outdated: true, lastSuccessAt: nil).stopsWork)
        XCTAssertTrue(LicenseBanner.unverified.stopsWork)
        XCTAssertTrue(LicenseBanner.noLicense.stopsWork)
        XCTAssertFalse(LicenseBanner.grace(outdated: false, lastSuccessAt: nil, until: afterGrace).stopsWork)
        XCTAssertFalse(LicenseBanner.appOutdated.stopsWork)
    }

    /// Closed during the week, the warning comes back for the last day; closed on the last day, not
    /// again; a renewal that moved the end counts anew (§8.5 item 10).
    func testAClosedPeriodWarningComesBackOnlyForTheLastDay() throws {
        let end = try time("2026-12-01T00:00:00Z")
        let p = try entitlement()
        func warning(daysLeft: Double, closed: AccountRecord.PeriodEndingClosed?) -> LicenseBanner? {
            LicenseBanners.banners(.init(mode: .full, entitlement: p, periodEndingClosed: closed, now: end.addingTimeInterval(-daysLeft * 86_400)))
                .first { $0.rank == 10 }
        }
        let closedInTheWeek = AccountRecord.PeriodEndingClosed(endsAt: end, final: false)
        XCTAssertNil(warning(daysLeft: 3, closed: closedInTheWeek))
        XCTAssertEqual(warning(daysLeft: 0.5, closed: closedInTheWeek), .periodEnding(owner: true, endsAt: end, final: true))
        let closedOnTheLastDay = AccountRecord.PeriodEndingClosed(endsAt: end, final: true)
        XCTAssertNil(warning(daysLeft: 0.5, closed: closedOnTheLastDay))
        XCTAssertNil(warning(daysLeft: 3, closed: closedOnTheLastDay), "a clock set back does not bring it back")
        let closedForTheOldEnd = AccountRecord.PeriodEndingClosed(endsAt: end.addingTimeInterval(-30 * 86_400), final: true)
        XCTAssertEqual(warning(daysLeft: 3, closed: closedForTheOldEnd), .periodEnding(owner: true, endsAt: end, final: false))
    }

    /// `account.json`'s new notes: kept and read back; one that does not read is left out, never the
    /// whole file (which would sign this Mac out).
    func testTheAccountFilesNewNotesReadBackAndAnOddOneIsLeftOut() throws {
        var record = AccountRecord()
        record.deviceToken = ServerToken("lmd_x")
        record.unlinkCooldownSeconds = 604_800
        record.periodEndingClosed = .init(endsAt: try time("2026-12-01T00:00:00Z"), final: false)
        let data = try JSONCoding.encoder.encode(record)
        XCTAssertEqual(try JSONCoding.decoder.decode(AccountRecord.self, from: data), record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unlinkCooldownSeconds"] = "a week"
        object["periodEndingClosed"] = ["endsAt": 3]
        let odd = try JSONCoding.decoder.decode(AccountRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(odd.isSignedIn)
        XCTAssertNil(odd.unlinkCooldownSeconds)
        XCTAssertNil(odd.periodEndingClosed)
    }

    // MARK: The key (the server's internal/ident)

    /// The server's own vectors (internal/ident/ident_test.go), "computed outside this package — by
    /// a Python implementation of the same definition".
    func testTheServersKeyVectorsRead() {
        for key in ["LMK-0000-0000-0000-0000-0000-0000", "LMK-0123-4567-89AB-CDEF-GHJK-MNMT", "LMK-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZWB"] {
            XCTAssertEqual(AccountKey(typed: key)?.unredacted(), key)
            // The same data with other check characters is a typo.
            let last = CrockfordCode.alphabet.firstIndex(of: key.last!)!
            XCTAssertNil(AccountKey(typed: String(key.dropLast()) + String(CrockfordCode.alphabet[(last + 1) % 32])), key)
        }
        XCTAssertEqual(CrockfordCode.parse("LPC-0123-4567-89AB-CDEF-GHSY", kind: .purchaseCode), "LPC-0123-4567-89AB-CDEF-GHSY")
        XCTAssertEqual(CrockfordCode.parse("LMN-7K3Q-WXYZ-0123-4567-8929", kind: .invoiceNumber), "LMN-7K3Q-WXYZ-0123-4567-8929")
    }

    func testAKeyIsReadAsAPersonTypesIt() {
        let key = "LMK-0123-4567-89AB-CDEF-GHJK-MNMT"
        for typed in ["lmk-0123-4567-89ab-cdef-ghjk-mnmt", "LMK0123456789ABCDEFGHJKMNMT", "0123-4567-89AB-CDEF-GHJK-MNMT",
                      " LMK – 0123 4567\u{00A0}89AB—CDEF‐GHJK‑MNMT ", "LMK-O123-4567-89AB-CDEF-GHJK-MNMT",
                      "LMK-0123-4567-89AB-CDEF-GHJK-MNMT\n"] {
            XCTAssertEqual(AccountKey(typed: typed)?.unredacted(), key, typed)
        }
        // I and L are read as 1, O as 0 — the server reads them so too.
        XCTAssertEqual(AccountKey(typed: "LMK-0I23-4567-89AB-CDEF-GHJK-MNMT")?.unredacted(), key)
        XCTAssertEqual(AccountKey(typed: "lmk-0l23-4567-89ab-cdef-ghjk-mnmt")?.unredacted(), key)
        // U is not in the alphabet at all.
        XCTAssertNil(AccountKey(typed: "LMK-0U23-4567-89AB-CDEF-GHJK-MNMT"))
    }

    func testEverySingleWrongCharacterAndEveryNeighbourSwapIsCaught() {
        let key = Array("0123456789ABCDEFGHJKMNMT")
        var tried = 0
        for index in key.indices {
            for replacement in CrockfordCode.alphabet where replacement != key[index] {
                var typo = key
                typo[index] = replacement
                XCTAssertNil(AccountKey(typed: String(typo)), String(typo))
                tried += 1
            }
            if index + 1 < key.count, key[index] != key[index + 1] {
                var swapped = key
                swapped.swapAt(index, index + 1)
                XCTAssertNil(AccountKey(typed: String(swapped)), String(swapped))
                tried += 1
            }
        }
        XCTAssertEqual(tried, 24 * 31 + 23)
    }

    func testAKeyFieldSaysWhatItHolds() {
        XCTAssertEqual(AccountKeyInput.classify("  - "), .empty)
        XCTAssertEqual(AccountKeyInput.classify("LPC-0123-4567-89AB-CDEF-GHSY"), .purchaseCode)
        XCTAssertEqual(AccountKeyInput.classify("LMN-7K3Q-WXYZ-0123-4567-8929"), .invoiceNumber)
        XCTAssertEqual(AccountKeyInput.classify("ДЬЛ-0123-4567-89ФИ-СВУА-ПРОЛ-ЬТЬЕ"), .cyrillic)
        XCTAssertEqual(AccountKeyInput.classify("LMK-0123-4567-89AB-CDEF-GHJK-MNMU"), .typo)
        guard case .key(let key) = AccountKeyInput.classify("lmk 0123 4567 89ab cdef ghjk mnmt") else { return XCTFail() }
        XCTAssertEqual(key.unredacted(), "LMK-0123-4567-89AB-CDEF-GHJK-MNMT")
    }

    /// The key never says itself: not interpolated, printed, dumped, mirrored, nor inside another
    /// value's description — only `unredacted()` gives its text.
    func testAKeyAndATokenNeverSayThemselves() throws {
        let text = "LMK-0123-4567-89AB-CDEF-GHJK-MNMT"
        let key = try XCTUnwrap(AccountKey(typed: text))
        let token = ServerToken("lmd_5ecret5ecret5ecret")
        struct Holder { let key: AccountKey; let token: ServerToken }
        let holder = Holder(key: key, token: token)
        var dumped = ""
        dump(holder, to: &dumped)
        let shown = ["\(key)", String(describing: key), String(reflecting: key), "\(holder)", String(reflecting: holder),
                     dumped, "\([key])", "\(Optional(key) as Any)", "\(token)", String(reflecting: token), "\(Mirror(reflecting: holder).children.map { $0.value })"]
        for line in shown {
            XCTAssertFalse(line.contains("0123"), line)
            XCTAssertFalse(line.contains("5ecret"), line)
        }
        XCTAssertEqual("\(key)", "LMK-…")
        XCTAssertEqual("\(token)", "lmd_…")
        // A token is written to its file as it is: the file is where it lives.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(token), as: UTF8.self), #""lmd_5ecret5ecret5ecret""#)
    }

    // MARK: account.json

    func testTheAccountFileKeepsWhatTheContractNamesAndRefusesNewer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = AccountFile(directory: directory)
        XCTAssertNil(try file.load())
        var record = AccountRecord()
        record.deviceID = deviceID
        record.code = "B119"
        record.deviceToken = ServerToken("lmd_token")
        record.entitlement = EntitlementVerifier.envelope(of: try document(payload()))
        record.clock = EffectiveClock(floorTime: try time("2026-11-01T10:00:00Z"), floorUptime: 123.5)
        record.lastSuccessAt = try time("2026-11-01T10:00:00Z")
        record.signedInWith = .key
        try file.save(record)
        XCTAssertEqual(try file.load(), record)
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        #endif
        // The stored document still checks.
        XCTAssertNotNil(EntitlementVerifier.check(try XCTUnwrap(try file.load()?.entitlement), keys: keys, deviceID: deviceID, machineID: machineID).entitlement)

        // A newer version's file: refused, and never written over.
        let newer = Data(#"{"format": 2, "deviceToken": "lmd_new"}"#.utf8)
        try newer.write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertThrowsError(try file.save(record))
        XCTAssertEqual(try Data(contentsOf: file.url), newer)

        // One that does not read: moved aside, never written over.
        let damaged = Data("{\"format\": 1, \"deviceID\": ".utf8)
        try damaged.write(to: file.url)
        XCTAssertThrowsError(try file.load())
        try file.save(record)
        XCTAssertEqual(try Data(contentsOf: file.url.appendingPathExtension("unreadable")), damaged)
        XCTAssertEqual(try file.load(), record)
    }

    func testSigningOutKeepsOnlyTheReason() throws {
        var record = AccountRecord()
        record.deviceID = deviceID
        record.deviceToken = ServerToken("lmd_token")
        record.session = .init(sessionToken: ServerToken("lms_session"), expiresAt: nil, idleTimeoutSeconds: 604_800)
        record.entitlement = EntitlementVerifier.envelope(of: try document(payload()))
        record.lastSuccessAt = try time("2026-11-01T10:00:00Z")
        record.signOut(because: .machineMismatch)
        XCTAssertFalse(record.isSignedIn)
        XCTAssertNil(record.entitlement)
        XCTAssertNil(record.session)
        XCTAssertEqual(record.signedOutReason, .machineMismatch)
    }

    // MARK: The codes people copy by hand: the server's whole set (§18)

    private struct CodeVectors: Decodable {
        struct Case: Decodable {
            let kind: String
            let input: String
            let canonical: String?
            let why: String
        }

        let alphabet: String
        let cases: [Case]
    }

    /// `Fixtures/ident-test-vectors.json`, a copy of the server's `docs/ident-test-vectors.json` — written
    /// by a Python implementation of §18 apart from the server's code; "the app's implementation must
    /// pass it as it passes the document's vectors" (the contract, §18).
    func testEveryCaseOfTheServersCodeVectorsReadsAsTheContractSays() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ident-test-vectors.json")
        let vectors = try JSONDecoder().decode(CodeVectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.alphabet, String(CrockfordCode.alphabet))
        XCTAssertEqual(vectors.cases.count, 151)
        var read = 0, typos = 0
        for vector in vectors.cases {
            let kind: CrockfordCode.Kind
            switch vector.kind {
            case "key": kind = .key
            case "purchaseCode": kind = .purchaseCode
            case "invoiceNumber": kind = .invoiceNumber
            default: return XCTFail("an unknown kind: \(vector.kind)")
            }
            XCTAssertEqual(CrockfordCode.parse(vector.input, kind: kind), vector.canonical, "\(vector.kind) \(vector.why): \(vector.input)")
            if kind == .key { XCTAssertEqual(AccountKey(typed: vector.input)?.unredacted(), vector.canonical, vector.why) }
            if kind == .purchaseCode { XCTAssertEqual(PurchaseCode(typed: vector.input)?.unredacted(), vector.canonical, vector.why) }
            if vector.canonical == nil { typos += 1 } else { read += 1 }
        }
        XCTAssertEqual(read, 70)
        XCTAssertEqual(typos, 81)
    }

    // MARK: §10.1 — the master password is not the key

    func testTheKeysEchoKnowsItInEveryFormItCanBeTypedInAndNothingElse() throws {
        let text = "LMK-0123-4567-89AB-CDEF-GHJK-MNMT"
        let key = try XCTUnwrap(AccountKey(typed: text))
        let echo = AccountKeyEcho(key)
        for form in [text, "lmk 0123 4567 89ab cdef ghjk mnmt", "0123456789ABCDEFGHJKMNMT", "0123-4567-89AB-CDEF-GHJK-MNMT",
                     "LMK-O123-4567-89AB-CDEF-GHJK-MNMT", "LMK-0I23-4567-89AB-CDEF-GHJK-MNMT", " LMK0123456789abcdefghjkmnmt\n"] {
            XCTAssertTrue(echo.matches(form), form)
            XCTAssertTrue(key.isTyped(as: form), form)
        }
        for other in ["LMK-0000-0000-0000-0000-0000-0000", text + "!", "!" + text, "correct horse battery staple", "",
                      "LPC-0123-4567-89AB-CDEF-GHSY", "LMK-0123-4567-89AB-CDEF-GHJK-MNMV"] {
            XCTAssertFalse(echo.matches(other), other)
            XCTAssertFalse(key.isTyped(as: other), other)
        }
        // The echo says nothing of the key (its parts that no hexadecimal of random bytes could hold).
        var dumped = ""
        dump(echo, to: &dumped)
        for shown in [dumped, "\(echo)", String(reflecting: echo)] {
            XCTAssertFalse(shown.uppercased().contains("GHJK"), shown)
            XCTAssertFalse(shown.uppercased().contains("MNMT"), shown)
        }
    }

    func testAPurchaseCodeReadsAsTheServerReadsItAndNeverSaysItself() throws {
        let code = try XCTUnwrap(PurchaseCode(typed: "lpc 0123 4567 89ab cdef ghsy"))
        XCTAssertEqual(code.unredacted(), "LPC-0123-4567-89AB-CDEF-GHSY")
        XCTAssertEqual(PurchaseCode(typed: "0123456789ABCDEFGHSY"), code, "the prefix may be left out")
        XCTAssertNil(PurchaseCode(typed: "LPC-0123-4567-89AB-CDEF-GHSZ"), "a wrong check character")
        XCTAssertNil(PurchaseCode(typed: "LMK-0123-4567-89AB-CDEF-GHJK-MNMT"), "a key is not a purchase code")
        var dumped = ""
        dump(code, to: &dumped)
        for shown in ["\(code)", String(reflecting: code), dumped, "\([code])"] {
            XCTAssertFalse(shown.contains("0123"), shown)
        }
        XCTAssertEqual("\(code)", "LPC-…")
    }

    // MARK: account.json — the key's choice and the linked email (§4.2, §10.1)

    func testTheAccountFileKeepsTheKeysChoiceAndWhetherAnEmailIsLinked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = AccountFile(directory: directory)
        var record = AccountRecord()
        XCTAssertTrue(record.keepsKey, "the key is remembered unless the person says otherwise (§10.1)")
        record.deviceID = deviceID
        record.deviceToken = ServerToken("lmd_token")
        record.signedInWith = .key
        record.rememberKey = false
        record.emailLinked = true
        try file.save(record)
        XCTAssertEqual(try file.load(), record)
        XCTAssertFalse(try XCTUnwrap(try file.load()).keepsKey)
        let json = String(decoding: try Data(contentsOf: file.url), as: UTF8.self)
        XCTAssertTrue(json.contains("\"rememberKey\":false"), json)
        XCTAssertTrue(json.contains("\"emailLinked\":true"), json)
        // Signed out by the server: whether an email is linked stays — "Lost your key?" says by it how to
        // get back in; the key's choice goes with the sign-in it was made for.
        var revoked = record
        revoked.signOut(because: .deviceRevoked)
        XCTAssertEqual(revoked.emailLinked, true)
        XCTAssertNil(revoked.rememberKey)
        // Signed out by the person: neither stays.
        var left = record
        left.signOut(because: nil)
        XCTAssertNil(left.emailLinked)
        XCTAssertNil(left.rememberKey)
        // A file written before these fields reads with neither.
        let older = Data(#"{"format": 1, "deviceID": "d", "signedInWith": "key"}"#.utf8)
        try older.write(to: file.url)
        let read = try XCTUnwrap(try file.load())
        XCTAssertNil(read.emailLinked)
        XCTAssertTrue(read.keepsKey)
    }

    // MARK: Renewals (the owner, 3 November)

    func testEveryStartOfASignedInMacRenewsWhateverTheDocumentSays() throws {
        let p = try entitlement()
        // An hour after the document was issued, a day before it asks to be renewed.
        let fresh = try time("2026-11-01T11:00:00Z")
        XCTAssertTrue(RefreshSchedule.refreshAtLaunch(mode: .full, entitlement: p, at: fresh))
        XCTAssertTrue(RefreshSchedule.refreshAtLaunch(mode: .exportOnly, entitlement: nil, at: fresh))
        XCTAssertFalse(RefreshSchedule.refreshAtLaunch(mode: .notSignedIn, entitlement: nil, at: fresh))
        // While the app runs: when the document asks.
        XCTAssertFalse(RefreshSchedule.refreshDue(entitlement: p, at: fresh))
        XCTAssertTrue(RefreshSchedule.refreshDue(entitlement: p, at: try time("2026-11-02T10:00:00Z")))
    }

    func testAFailingRenewalIsSaidInTheDocumentsLastTwoDays() throws {
        let p = try entitlement()
        let since = try time("2026-11-02T10:05:00Z")
        let failure = AccountRecord.RenewalFailure(since: since, lastAt: try time("2026-11-03T12:00:00Z"), reason: .noAnswer, status: nil)
        func banners(_ mode: LicenseMode, at text: String, _ failure: AccountRecord.RenewalFailure?) throws -> [LicenseBanner] {
            LicenseBanners.banners(.init(mode: mode, entitlement: p, renewalFailure: failure, now: try time(text)))
        }
        // Three days before the document expires, a day of failures is not said.
        XCTAssertEqual(try banners(.full, at: "2026-11-02T09:00:00Z", failure), [])
        // Less than two days before: said, with since when, why, and until when this Mac works.
        XCTAssertEqual(try banners(.full, at: "2026-11-03T12:00:00Z", failure),
                       [.renewalFailing(since: since, reason: .noAnswer, status: nil, until: LicenseDecision.graceDate(p))])
        // No failure: nothing. The grace says it in its own words.
        XCTAssertEqual(try banners(.full, at: "2026-11-03T12:00:00Z", nil), [])
        XCTAssertFalse(try banners(.grace, at: "2026-11-06T12:00:00Z", failure).contains {
            if case .renewalFailing = $0 { return true }
            return false
        })
        XCTAssertFalse(LicenseBanner.renewalFailing(since: since, reason: .server, status: 503, until: since).stopsWork)
    }

    func testTheRenewalsNotesAreKeptAndASignOutForgetsThisMacsLabel() throws {
        var record = AccountRecord()
        record.deviceID = deviceID
        record.deviceToken = ServerToken("lmd_device_token")
        record.label = "Mac of the check"
        record.profileCount = 3
        record.renewalFailure = AccountRecord.RenewalFailure(since: try time("2026-11-02T10:00:00Z"), lastAt: try time("2026-11-02T11:00:00Z"),
                                                             reason: .server, status: 503)
        let data = try JSONCoding.encoder.encode(record)
        XCTAssertEqual(try JSONCoding.decoder.decode(AccountRecord.self, from: data), record)
        // A note that does not read is left out, not the whole file.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["renewalFailure"] = "not a note"
        let odd = try JSONCoding.decoder.decode(AccountRecord.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(odd.renewalFailure)
        XCTAssertEqual(odd.label, "Mac of the check")
        record.signOut(because: nil)
        XCTAssertNil(record.label)
        XCTAssertNil(record.renewalFailure)
        XCTAssertEqual(record.profileCount, 3)
    }
}

/// The key of an account without an email, kept in the vault (`AccountKeyVault`).
final class AccountKeyVaultTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-account-key-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let text = "LMK-0123-4567-89AB-CDEF-GHJK-MNMT"

    func testTheKeyIsKeptEncryptedAndOnlyTheVaultOpensIt() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        XCTAssertNil(try AccountKeyVault.load(from: vault))
        let key = try XCTUnwrap(AccountKey(typed: text))
        try AccountKeyVault.save(key, to: vault)
        XCTAssertEqual(try AccountKeyVault.load(from: vault), key)
        // On disk: neither the key nor its characters in a row, in any form.
        let bytes = try Data(contentsOf: root.appendingPathComponent("account-key.bin"))
        for form in [text, "0123456789ABCDEFGHJKMNMT", "0123-4567", "MNMT"] {
            XCTAssertNil(bytes.range(of: Data(form.utf8)), form)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("account-key.bin").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        // The vault opened again with its password opens it.
        let again = try MasterVault.unlock(in: root, password: "pw")
        XCTAssertEqual(try AccountKeyVault.load(from: again), key)
        // A profile's own process — the vault opened with a grant — cannot.
        let manager = try ProfileRepository(vault: again)
        let profile = try manager.create(name: "P", configuration: ProfileConfiguration())
        let granted = try MasterVault.open(in: root, grant: manager.grant(for: profile.id))
        XCTAssertThrowsError(try AccountKeyVault.load(from: granted))
        try AccountKeyVault.remove(from: again)
        XCTAssertNil(try AccountKeyVault.load(from: again))
    }

    func testAFileThatDoesNotOpenIsNeverWrittenOver() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        let url = root.appendingPathComponent("account-key.bin")
        let damaged = Data("not a sealed key".utf8)
        try damaged.write(to: url)
        XCTAssertThrowsError(try AccountKeyVault.load(from: vault))
        try AccountKeyVault.save(try XCTUnwrap(AccountKey(typed: text)), to: vault)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unreadable")), damaged)
        XCTAssertEqual(try AccountKeyVault.load(from: vault)?.unredacted(), text)
    }

    // MARK: The subscription's reminders (an account with a key alone, the owner 2 November)

    func testRemindersAreOfferedOnceToAKeyAccountRightAfterActivationOrAtTheFirstWarning() {
        // Right after a key connected this Mac: offered, whatever the banners say.
        XCTAssertTrue(ExpiryReminders.shouldOffer(at: .activatedWithKey, signedInWithKey: true, alreadyOffered: false, periodEnding: false))
        // Later, only once the first warning before the period's end is shown.
        XCTAssertFalse(ExpiryReminders.shouldOffer(at: .stateChanged, signedInWithKey: true, alreadyOffered: false, periodEnding: false))
        XCTAssertTrue(ExpiryReminders.shouldOffer(at: .stateChanged, signedInWithKey: true, alreadyOffered: false, periodEnding: true))
        // Never again by itself after an answer, whatever it was.
        XCTAssertFalse(ExpiryReminders.shouldOffer(at: .activatedWithKey, signedInWithKey: true, alreadyOffered: true, periodEnding: true))
        XCTAssertFalse(ExpiryReminders.shouldOffer(at: .stateChanged, signedInWithKey: true, alreadyOffered: true, periodEnding: true))
        // An account with an email gets letters, not these; nor does a Mac not signed in.
        XCTAssertFalse(ExpiryReminders.shouldOffer(at: .activatedWithKey, signedInWithKey: false, alreadyOffered: false, periodEnding: true))
        XCTAssertFalse(ExpiryReminders.shouldOffer(at: .stateChanged, signedInWithKey: false, alreadyOffered: false, periodEnding: true))
    }

    func testRemindersComeAWeekAndADayBeforeThePeriodsEndOnlyAhead() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let end = now.addingTimeInterval(10 * day)
        XCTAssertEqual(ExpiryReminders.reminders(periodEndsAt: end, now: now), [
            .init(kind: .week, at: end.addingTimeInterval(-7 * day), periodEndsAt: end),
            .init(kind: .day, at: end.addingTimeInterval(-day), periodEndsAt: end),
        ])
        // Three days left: the week's moment is past, the day's is ahead.
        let soon = now.addingTimeInterval(3 * day)
        XCTAssertEqual(ExpiryReminders.reminders(periodEndsAt: soon, now: now).map(\.kind), [.day])
        // Twelve hours left, the period over, or no period: nothing to remind of.
        XCTAssertEqual(ExpiryReminders.reminders(periodEndsAt: now.addingTimeInterval(day / 2), now: now), [])
        XCTAssertEqual(ExpiryReminders.reminders(periodEndsAt: now.addingTimeInterval(-day), now: now), [])
        XCTAssertEqual(ExpiryReminders.reminders(periodEndsAt: nil, now: now), [])
    }
}
