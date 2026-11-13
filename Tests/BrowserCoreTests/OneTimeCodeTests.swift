import XCTest
@testable import BrowserCore

/// One-time codes (TOTP) against RFC 6238's own test vectors, and what a person gives to set one
/// up: a secret in Base32, or an `otpauth://` link (what a QR code holds).
final class OneTimeCodeTests: XCTestCase {
    /// RFC 6238, Appendix B: the secrets are the ASCII digits repeated to the hash's length.
    private func secret(_ length: Int) -> Data {
        Data(String(repeating: "1234567890", count: 7).utf8.prefix(length))
    }

    private let times: [TimeInterval] = [59, 1_111_111_109, 1_111_111_111, 1_234_567_890, 2_000_000_000, 20_000_000_000]

    private func codes(_ algorithm: OneTimeCode.Algorithm, secret length: Int, digits: Int) throws -> [String] {
        let code = try XCTUnwrap(OneTimeCode(secret: secret(length), algorithm: algorithm, digits: digits, period: 30))
        return times.map { code.code(at: Date(timeIntervalSince1970: $0)) }
    }

    func testTheRFCsVectorsWithEightDigits() throws {
        XCTAssertEqual(try codes(.sha1, secret: 20, digits: 8),
                       ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"])
        XCTAssertEqual(try codes(.sha256, secret: 32, digits: 8),
                       ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"])
        XCTAssertEqual(try codes(.sha512, secret: 64, digits: 8),
                       ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"])
    }

    /// Six digits are the last six of the eight: the same number, taken modulo a million.
    func testTheRFCsVectorsWithSixDigits() throws {
        XCTAssertEqual(try codes(.sha1, secret: 20, digits: 6), ["287082", "081804", "050471", "005924", "279037", "353130"])
        XCTAssertEqual(try codes(.sha256, secret: 32, digits: 6), ["119246", "084774", "062674", "819424", "698825", "737706"])
        XCTAssertEqual(try codes(.sha512, secret: 64, digits: 6), ["693936", "091201", "943326", "441116", "618901", "863826"])
    }

    func testACodeStandsForItsPeriod() throws {
        let code = try XCTUnwrap(OneTimeCode(secret: secret(20)))
        let start = Date(timeIntervalSince1970: 1_111_111_110) // a multiple of 30
        XCTAssertEqual(code.secondsLeft(at: start), 30)
        XCTAssertEqual(code.secondsLeft(at: start.addingTimeInterval(29.9)), 1)
        XCTAssertEqual(code.code(at: start), code.code(at: start.addingTimeInterval(29.9)))
        XCTAssertNotEqual(code.code(at: start), code.code(at: start.addingTimeInterval(30)))
        let minute = try XCTUnwrap(OneTimeCode(secret: secret(20), period: 60))
        XCTAssertEqual(minute.secondsLeft(at: Date(timeIntervalSince1970: 1_111_111_125)), 15)
    }

    func testBase32() {
        // RFC 4648, section 10.
        let vectors = ["f": "MY", "fo": "MZXQ", "foo": "MZXW6", "foob": "MZXW6YQ", "fooba": "MZXW6YTB", "foobar": "MZXW6YTBOI"]
        for (plain, encoded) in vectors {
            XCTAssertEqual(Base32.encode(Data(plain.utf8)), encoded)
            XCTAssertEqual(Base32.decode(encoded), Data(plain.utf8))
            XCTAssertEqual(Base32.decode(encoded + "======"), Data(plain.utf8), "padding is taken")
        }
        XCTAssertEqual(Base32.decode("mzxw 6ytb-oi"), Data("foobar".utf8), "either case, spaces and dashes between groups")
        XCTAssertNil(Base32.decode("MZXW1"), "1 is not a Base32 digit")
        XCTAssertNil(Base32.decode(""))
        XCTAssertNil(Base32.decode(" = "))
    }

    func testASecretAloneIsSHA1SixDigitsThirtySeconds() throws {
        let code = try OneTimeCode.parse("  gezd gnbv gy3t qojq gezd gnbv gy3t qojq \n")
        XCTAssertEqual(code.secret, secret(20))
        XCTAssertEqual(code.algorithm, .sha1)
        XCTAssertEqual(code.digits, 6)
        XCTAssertEqual(code.period, 30)
        XCTAssertEqual(code.code(at: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(code.secretText, "GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ")
    }

    func testAnOtpauthLink() throws {
        let code = try OneTimeCode.parse(
            "otpauth://totp/Example%20Bank:alice@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example%20Bank&algorithm=SHA256&digits=8&period=60")
        XCTAssertEqual(code.secret, secret(20))
        XCTAssertEqual(code.algorithm, .sha256)
        XCTAssertEqual(code.digits, 8)
        XCTAssertEqual(code.period, 60)
        XCTAssertEqual(code.issuer, "Example Bank")
        XCTAssertEqual(code.account, "alice@example.com")

        // No issuer parameter: the label's part before the colon; no colon: the account alone.
        XCTAssertEqual(try OneTimeCode.parse("otpauth://totp/Shop:bob?secret=MZXW6YTBOI").issuer, "Shop")
        let alone = try OneTimeCode.parse("OTPAUTH://TOTP/bob?secret=MZXW6YTBOI")
        XCTAssertNil(alone.issuer)
        XCTAssertEqual(alone.account, "bob")
        XCTAssertEqual(alone.algorithm, .sha1)
        XCTAssertEqual(alone.digits, 6)
        XCTAssertEqual(alone.period, 30)
    }

    func testWhatIsNotACodeSaysWhy() {
        func failure(_ text: String) -> OneTimeCodeError? {
            do { _ = try OneTimeCode.parse(text); return nil } catch { return error as? OneTimeCodeError }
        }
        XCTAssertEqual(failure("   "), .empty)
        XCTAssertEqual(failure("not a secret!"), .notASecret)
        XCTAssertEqual(failure("https://example.com/"), .notASecret)
        XCTAssertEqual(failure("otpauth://totp/a?issuer=b"), .notASecret, "a link without a secret")
        XCTAssertEqual(failure("otpauth://hotp/a?secret=MZXW6YTBOI&counter=1"), .counterBased)
        XCTAssertEqual(failure("otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8"), .severalAccounts)
        XCTAssertEqual(failure("otpauth://totp/a?secret=MZXW6YTBOI&algorithm=MD5"), .unsupported)
        XCTAssertEqual(failure("otpauth://totp/a?secret=MZXW6YTBOI&digits=10"), .unsupported)
        XCTAssertEqual(failure("otpauth://totp/a?secret=MZXW6YTBOI&period=0"), .unsupported)
        XCTAssertNil(OneTimeCode(secret: Data()))
    }

    /// A file may hold what `init` refuses (another program's export, a damaged field): a code is
    /// still computed, never a crash.
    func testACodeFromOddValuesIsStillACode() throws {
        var code = try XCTUnwrap(OneTimeCode(secret: secret(20)))
        code.digits = 40
        code.period = 0
        XCTAssertEqual(code.code(at: Date(timeIntervalSince1970: 59)).count, 8)
        XCTAssertEqual(code.secondsLeft(at: Date(timeIntervalSince1970: 59)), 1)
        code.digits = 0
        XCTAssertEqual(code.code(at: Date(timeIntervalSince1970: -5)).count, 6)
    }

    // MARK: In a saved login

    func testALoginKeepsItsCodeThroughTheFileAndAPagesSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-otp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
        let vault = try repository.passwordVault(for: id)
        let generator = try OneTimeCode.parse("otpauth://totp/Example:alice?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        try vault.upsert(PasswordEntry(origin: "https://example.com", username: "alice", password: "one", totp: generator))

        // A page saves a changed password for the same login: it knows nothing of the code.
        try vault.upsert(PasswordEntry(origin: "https://example.com", username: "alice", password: "two"))
        let reopened = try repository.passwordVault(for: id).allEntries()
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.password, "two")
        XCTAssertEqual(reopened.first?.totp, generator)

        // Offered for a code's field on the site; a code alone is not offered for a password's.
        let page = try XCTUnwrap(WebOrigin("https://login.example.com"))
        try vault.upsert(PasswordEntry(origin: "https://example.com", username: "codes-only", password: "", totp: generator))
        XCTAssertEqual(vault.codeCandidates(for: page).map(\.username).sorted(), ["alice", "codes-only"])
        XCTAssertEqual(vault.candidates(for: page).map(\.username), ["alice"])

        // Taking the code away is an edit.
        var edited = try XCTUnwrap(vault.allEntries().first { $0.username == "alice" })
        edited.totp = nil
        try vault.update(edited)
        XCTAssertNil(vault.allEntries().first { $0.username == "alice" }?.totp)
    }

    /// Two devices changed the same login at the same time, one of them adding the code: both
    /// versions are kept, and the one with the code is not folded away as "the same password".
    func testAMergeDoesNotLoseACodeAddedOnOneDevice() throws {
        let generator = try OneTimeCode.parse("MZXW6YTBOI")
        let base = PasswordEntry(origin: "https://example.com", username: "alice", password: "p",
                                 updatedAt: Date(timeIntervalSince1970: 1_000), version: UUID(), ancestors: [])
        var withCode = base
        withCode.totp = generator
        withCode.version = UUID()
        withCode.ancestors = [base.currentVersion]
        withCode.updatedAt = Date(timeIntervalSince1970: 2_000)

        // The other device still has the version before: the change with the code is taken.
        let merged = PasswordDocument.merge(PasswordDocument(entries: [base]), PasswordDocument(entries: [withCode]))
        XCTAssertEqual(merged.entries.count, 1)
        XCTAssertEqual(merged.entries.first?.totp, generator)
        XCTAssertEqual(merged.writtenFormat, 3)
        XCTAssertEqual(PasswordDocument(entries: [base]).writtenFormat, 2)

        // The same login saved separately on two devices, one with the code: neither is dropped.
        var separate = withCode
        separate.id = UUID()
        let folded = PasswordDocument.merge(PasswordDocument(entries: [base]), PasswordDocument(entries: [separate]))
        XCTAssertTrue(folded.entries.contains { $0.totp == generator }, "the code survives the folding of duplicates")
    }
}
