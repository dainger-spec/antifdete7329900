#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import BrowserCore

/// Unlocking with Touch ID, the part that needs no Mac: what is kept beside the vault opens it only
/// with the key that goes into the keychain, exactly as it was sealed, and the rule says when
/// Touch ID may open the vault and when the master password is asked.
final class BiometricUnlockTests: XCTestCase {
    var root: URL!
    /// When this Mac started, in the tests: a fixed moment.
    let boot = 1_800_000_000
    let typed = Date(timeIntervalSince1970: 1_800_003_600)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-touchid-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func vault(password: String = "master password") throws -> UnlockedVault {
        try MasterVault.create(in: root, password: password, iterations: 1_000)
    }

    private func decide(_ record: BiometricUnlockRecord?, _ vault: UnlockedVault, after seconds: Int = 60, boot: Int? = nil,
                        fingerprints: Data? = Data([1]), keyKept: Bool = true) -> BiometricUnlock.Decision {
        BiometricUnlock.decide(record: record, header: vault.header, now: typed.addingTimeInterval(TimeInterval(seconds)),
                               bootTime: boot ?? self.boot, biometryState: fingerprints, keyKept: keyKept)
    }

    // MARK: What is kept opens the vault, and only as it was sealed

    func testTheKeyTouchIDReleasesOpensTheVaultThePasswordOpened() throws {
        let opened = try vault()
        let repository = try ProfileRepository.openedAtUnlock(vault: opened)
        let profile = try repository.create(name: "Northwind", configuration: ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo"))
        let kept = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: Data([1]))
        XCTAssertEqual(kept.key.count, 32)

        let again = try BiometricUnlock.unlock(root: root, record: kept.record, key: kept.key)
        let reopened = try ProfileRepository.openedAtUnlock(vault: again)
        XCTAssertEqual(reopened.list().map(\.name), ["Northwind"])
        XCTAssertEqual(try reopened.loadConfiguration(profile.id).timeZoneIdentifier, "Asia/Tokyo")
        // The whole vault, as with the password: it can make a profile too.
        XCTAssertNoThrow(try reopened.create(name: "Harbor", configuration: ProfileConfiguration()))
    }

    func testAnotherKeyDoesNotOpenIt() throws {
        let kept = try BiometricUnlock.enroll(try vault(), now: typed, bootTime: boot, biometryState: nil)
        var other = kept.key
        other[0] ^= 0xFF
        XCTAssertThrowsError(try BiometricUnlock.unlock(root: root, record: kept.record, key: other)) { error in
            XCTAssertEqual(error as? CoreError, .authenticationFailed)
        }
        XCTAssertThrowsError(try BiometricUnlock.unlock(root: root, record: kept.record, key: Data(count: 16)))
    }

    /// The dates are in the file in the clear, so that the rule can be asked before Touch ID is:
    /// a record with a later date, another start or another set of fingerprints is not the one
    /// that was sealed, and does not open.
    func testARecordEditedByHandDoesNotOpen() throws {
        let kept = try BiometricUnlock.enroll(try vault(), now: typed, bootTime: boot, biometryState: Data([1]))
        var later = kept.record
        later.passwordTypedAt += 30 * 86_400
        var restarted = kept.record
        restarted.bootTime += 3_600
        var fingerprints = kept.record
        fingerprints.biometryState = Data([2])
        var unknownFingerprints = kept.record
        unknownFingerprints.biometryState = nil
        for edited in [later, restarted, fingerprints, unknownFingerprints] {
            XCTAssertThrowsError(try BiometricUnlock.unlock(root: root, record: edited, key: kept.key)) { error in
                XCTAssertEqual(error as? CoreError, .authenticationFailed)
            }
        }
        XCTAssertNoThrow(try BiometricUnlock.unlock(root: root, record: kept.record, key: kept.key))
    }

    func testNeitherTheRecordNorTheKeyHoldsThePasswordOrTheVaultsKeyInTheClear() throws {
        let opened = try vault(password: "correct horse battery")
        let kept = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: nil)
        try BiometricUnlock.save(kept.record, in: root)
        let file = try Data(contentsOf: BiometricUnlock.recordURL(in: root))
        XCTAssertNil(file.range(of: Data("correct horse battery".utf8)))
        // Two enrolments of one vault: another key and another seal each time, of the same master key.
        let second = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: nil)
        XCTAssertNotEqual(second.key, kept.key)
        XCTAssertNotEqual(second.record.wrappedMasterKey, kept.record.wrappedMasterKey)
        // The key alone opens nothing: without the record there is nothing to unseal, and the
        // vault's own header does not open with it.
        XCTAssertThrowsError(try AEAD.open(opened.header.wrappedMasterKey, key: SymmetricKey(data: kept.key),
                                           aad: VaultHeader.aad(for: opened.vaultID)))
    }

    func testAProfilesOwnProcessCannotMakeIt() throws {
        let opened = try vault()
        let repository = try ProfileRepository.openedAtUnlock(vault: opened)
        let profile = try repository.create(name: "P", configuration: ProfileConfiguration())
        let granted = try MasterVault.open(in: root, grant: repository.grant(for: profile.id))
        XCTAssertThrowsError(try BiometricUnlock.enroll(granted, now: typed, bootTime: boot, biometryState: nil)) { error in
            guard case .notGranted? = error as? CoreError else { return XCTFail("\(error)") }
        }
    }

    // MARK: The record beside the vault

    func testTheRecordIsSavedReadAndRemoved() throws {
        let kept = try BiometricUnlock.enroll(try vault(), now: typed, bootTime: boot, biometryState: Data([7, 7]))
        XCTAssertNil(BiometricUnlock.load(in: root))
        try BiometricUnlock.save(kept.record, in: root)
        XCTAssertEqual(BiometricUnlock.load(in: root), kept.record)
        // As it was read back, it still opens: nothing of the seal's is lost in the file.
        let read = try XCTUnwrap(BiometricUnlock.load(in: root))
        XCTAssertNoThrow(try BiometricUnlock.unlock(root: root, record: read, key: kept.key))
        XCTAssertTrue(BiometricUnlock.remove(in: root))
        XCTAssertNil(BiometricUnlock.load(in: root))
        XCTAssertTrue(BiometricUnlock.remove(in: root), "removing what is not there leaves none")
    }

    func testARecordThisVersionCannotReadCountsAsOff() throws {
        let opened = try vault()
        let kept = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: nil)
        var newer = kept.record
        newer.format = BiometricUnlockRecord.currentFormat + 1
        try BiometricUnlock.save(newer, in: root)
        XCTAssertNil(BiometricUnlock.load(in: root))
        try Data("not json".utf8).write(to: BiometricUnlock.recordURL(in: root))
        XCTAssertNil(BiometricUnlock.load(in: root))
        XCTAssertEqual(decide(BiometricUnlock.load(in: root), opened), .off)
    }

    // MARK: The rule

    func testOffUntilTurnedOnThenTouchIDWithinTheDays() throws {
        let opened = try vault()
        XCTAssertEqual(decide(nil, opened), .off)
        let record = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: Data([1])).record
        XCTAssertEqual(decide(record, opened), .touchID)
        XCTAssertEqual(decide(record, opened, after: BiometricUnlock.passwordEveryDays * 86_400), .touchID, "the last second of the days")
        // The clock is corrected after sleep: a few seconds either way are the same start.
        XCTAssertEqual(decide(record, opened, boot: boot + BiometricUnlock.bootTolerance), .touchID)
        XCTAssertEqual(decide(record, opened, boot: boot - BiometricUnlock.bootTolerance), .touchID)
        // The fingerprints cannot be read just now (the lid is closed): not a change of them.
        XCTAssertEqual(decide(record, opened, fingerprints: nil), .touchID)
    }

    func testThePasswordIsAskedAfterARestartAndAfterTheDays() throws {
        let opened = try vault()
        let record = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: Data([1])).record
        XCTAssertEqual(decide(record, opened, boot: boot + 120), .password(.restarted))
        XCTAssertEqual(decide(record, opened, boot: boot - 86_400), .password(.restarted))
        XCTAssertEqual(decide(record, opened, after: BiometricUnlock.passwordEveryDays * 86_400 + 1), .password(.tooLong))
        XCTAssertEqual(decide(record, opened, after: -3_600), .password(.tooLong), "the clock set back is not more days")
        // Both keep it turned on: the next unlock with the password starts the days anew.
        XCTAssertFalse(BiometricUnlock.ends(.restarted))
        XCTAssertFalse(BiometricUnlock.ends(.tooLong))
    }

    func testAChangedMasterPasswordEndsIt() throws {
        let opened = try vault(password: "old password")
        let kept = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: Data([1]))
        try opened.changePassword(current: "old password", new: "new password", iterations: 1_000)
        XCTAssertEqual(decide(kept.record, opened), .password(.passwordChanged))
        XCTAssertTrue(BiometricUnlock.ends(.passwordChanged))
        // And what was kept before the change does not open the vault any more, even with its key.
        XCTAssertThrowsError(try BiometricUnlock.unlock(root: root, record: kept.record, key: kept.key)) { error in
            XCTAssertEqual(error as? CoreError, .wrongPassword)
        }
        // Turned on again with the new password, it does.
        let again = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: Data([1]))
        XCTAssertEqual(decide(again.record, opened), .touchID)
        XCTAssertNoThrow(try BiometricUnlock.unlock(root: root, record: again.record, key: again.key))
    }

    func testChangedFingerprintsAMissingKeyAndAnotherVaultEndIt() throws {
        let opened = try vault()
        let record = try BiometricUnlock.enroll(opened, now: typed, bootTime: boot, biometryState: Data([1])).record
        XCTAssertEqual(decide(record, opened, fingerprints: Data([1, 2])), .password(.fingerprintsChanged))
        XCTAssertEqual(decide(record, opened, keyKept: false), .password(.keyGone))
        var others = record
        others.vaultID = UUID()
        XCTAssertEqual(decide(others, opened), .password(.anotherVault))
        XCTAssertThrowsError(try BiometricUnlock.unlock(root: root, record: others, key: Data(count: 32)))
        for reason in [BiometricUnlock.PasswordReason.fingerprintsChanged, .keyGone, .anotherVault] {
            XCTAssertTrue(BiometricUnlock.ends(reason), "\(reason)")
        }
        // Every reason is one or the other.
        XCTAssertEqual(BiometricUnlock.PasswordReason.allCases.filter { !BiometricUnlock.ends($0) }, [.restarted, .tooLong])
    }
}
