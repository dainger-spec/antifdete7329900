import XCTest
@testable import BrowserCore

final class Argon2Tests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testBlake2b() {
        XCTAssertEqual(hex(Blake2b.hash([], outputLength: 64)),
                       "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        XCTAssertEqual(hex(Blake2b.hash(Array("abc".utf8), outputLength: 64)),
                       "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        // Two full blocks (the last block is full, not padded) and a 32-byte digest.
        XCTAssertEqual(hex(Blake2b.hash((0..<256).map { UInt8($0) }, outputLength: 32)),
                       "39a7eb9fedc19aabc83425c6755dd90e6f9d0c804964a1f4aaeea3b9fb599835")
    }

    /// RFC 9106 §5.3: Argon2id, version 0x13, with secret and associated data.
    func testRFC9106Vector() {
        let tag = Argon2id.hash(password: [UInt8](repeating: 1, count: 32), salt: [UInt8](repeating: 2, count: 16),
                                secret: [UInt8](repeating: 3, count: 8), associatedData: [UInt8](repeating: 4, count: 12),
                                passes: 3, memoryKiB: 32, lanes: 4, tagLength: 32)
        XCTAssertEqual(hex(tag), "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    /// The reference implementation's own test vectors (src/test.c, Argon2id v0x13, m = 2^8 KiB).
    func testReferenceVectors() {
        let one = Argon2id.hash(password: Array("password".utf8), salt: Array("somesalt".utf8),
                                passes: 2, memoryKiB: 256, lanes: 1, tagLength: 32)
        XCTAssertEqual(hex(one), "9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe")
        let two = Argon2id.hash(password: Array("password".utf8), salt: Array("somesalt".utf8),
                                passes: 2, memoryKiB: 256, lanes: 2, tagLength: 32)
        XCTAssertEqual(hex(two), "6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037")
    }

    func testKeyDerivationWithArgon2id() throws {
        let parameters = KDFParameters.argon2idParameters(memoryKiB: 64, passes: 1, lanes: 1)
        let a = try KeyDerivation.deriveKey(password: "correct horse", parameters: parameters)
        XCTAssertEqual(a.rawBytes, try KeyDerivation.deriveKey(password: "correct horse", parameters: parameters).rawBytes)
        XCTAssertNotEqual(a.rawBytes, try KeyDerivation.deriveKey(password: "correct horsf", parameters: parameters).rawBytes)
        // Composed and decomposed Unicode derive the same key, as with PBKDF2.
        XCTAssertEqual(try KeyDerivation.deriveKey(password: "caf\u{e9}", parameters: parameters).rawBytes,
                       try KeyDerivation.deriveKey(password: "cafe\u{301}", parameters: parameters).rawBytes)
        // Costs a header cannot ask for.
        for bad in [KDFParameters.argon2idParameters(memoryKiB: 4, passes: 1, lanes: 1),
                    KDFParameters.argon2idParameters(memoryKiB: 64, passes: 0, lanes: 1),
                    KDFParameters.argon2idParameters(memoryKiB: 64, passes: 1, lanes: 0),
                    KDFParameters.argon2idParameters(memoryKiB: 4 * 1024 * 1024, passes: 1, lanes: 1),
                    KDFParameters(algorithm: KDFParameters.argon2id, iterations: 1, salt: Data(count: 16))] {
            XCTAssertThrowsError(try KeyDerivation.deriveKey(password: "x", parameters: bad))
        }
        let recommended = KDFParameters.recommended()
        XCTAssertEqual([recommended.algorithm, "\(recommended.memoryKiB ?? 0)", "\(recommended.iterations)", "\(recommended.parallelism ?? 0)"],
                       ["argon2id", "65536", "3", "4"])
    }

    /// A PBKDF2 header still encodes exactly as before Argon2id (no new keys).
    func testPBKDF2HeaderEncodingUnchanged() throws {
        let json = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(KDFParameters.generate(iterations: 1_000))) as? [String: Any]
        XCTAssertEqual(json.map { Set($0.keys) }, ["algorithm", "iterations", "salt"])
    }

    /// A vault from before Argon2id is re-wrapped under it with the password that opens it; its
    /// data stays readable, a wrong password changes nothing.
    func testPBKDF2VaultUpgradesToArgon2id() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("argon2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let small = KDFParameters.argon2idParameters(memoryKiB: 64, passes: 1, lanes: 2)
        let old = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        let profile = try ProfileRepository(vault: old).create(name: "Kept", configuration: ProfileConfiguration())
        XCTAssertFalse(old.header.kdf.isMemoryHard)

        XCTAssertThrowsError(try old.upgradeKDFIfNeeded(password: "wrong", to: small))
        XCTAssertFalse(try MasterVault.readHeader(in: root).kdf.isMemoryHard)

        XCTAssertTrue(try old.upgradeKDFIfNeeded(password: "pw", to: small))
        XCTAssertFalse(try old.upgradeKDFIfNeeded(password: "pw", to: small))
        let header = try MasterVault.readHeader(in: root)
        XCTAssertEqual(header.kdf.algorithm, KDFParameters.argon2id)
        XCTAssertEqual(header.vaultID, old.vaultID)

        let reopened = try MasterVault.unlock(in: root, password: "pw")
        XCTAssertEqual(try ProfileRepository(vault: reopened).list().map(\.id), [profile.id])
        XCTAssertThrowsError(try MasterVault.unlock(in: root, password: "wrong"))
    }
}
