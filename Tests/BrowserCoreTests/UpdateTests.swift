#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import BrowserCore

/// The update feed and its checks (docs/UPDATES.md §2): what may be installed, and everything that
/// is refused.
final class UpdateTests: XCTestCase {
    var root: URL!
    var key: (privateKey: Data, publicKey: Data)!
    var keys: [String: Data]!
    let macOS14 = BuildVersion("14.6")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        key = UpdateSigner.newKey()
        keys = [UpdateKeys.keyID(of: key.publicKey): key.publicKey]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// A zip stand-in of `size` bytes, and its release signed with `privateKey` (the test key).
    private func release(build: String, minimumSystem: String = "14.0", size: Int = 4096,
                         privateKey: Data? = nil) throws -> (archive: URL, item: AppcastItem) {
        let archive = root.appendingPathComponent("PrivacyBrowser-\(build)-\(UUID().uuidString).zip")
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ build.count) }).write(to: archive)
        let item = try UpdateSigner.item(archive: archive, version: "0.\(build)", build: build, minimumSystemVersion: minimumSystem,
                                         url: URL(string: "https://updates.example/\(archive.lastPathComponent)")!,
                                         notes: "Build \(build).\n<b>not markup</b>", publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         privateKey: privateKey ?? key.privateKey)
        return (archive, item)
    }

    private func appcast(_ items: [AppcastItem], generatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Appcast {
        Appcast(generatedAt: generatedAt, items: items)
    }

    private func assertRefused(_ expected: UpdateError, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), line: line) { error in
            XCTAssertEqual(error as? UpdateError, expected, line: line)
        }
    }

    /// The envelope's JSON, changed by `change` (payload and signature as raw bytes).
    private func tampered(_ envelope: Data, _ change: (inout [String: Any], inout Data, inout Data) throws -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        var payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(json["payload"] as? String)))
        var signature = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(json["signature"] as? String)))
        try change(&json, &payload, &signature)
        json["payload"] = payload.base64EncodedString()
        json["signature"] = signature.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: json)
    }

    // MARK: Versions

    func testBuildsCompareComponentByComponent() {
        func build(_ text: String) -> BuildVersion { BuildVersion(text)! }
        XCTAssertLessThan(build("1.9"), build("1.10"), "numbers, not text")
        XCTAssertLessThan(build("1.99.99"), build("2"))
        XCTAssertEqual(build("2"), build("2.0.0"), "a missing component is 0")
        XCTAssertEqual(Set([build("2"), build("2.0")]).count, 1)
        XCTAssertLessThan(build("41"), build("42"))
        XCTAssertFalse(build("42") < build("42"))
        XCTAssertEqual(BuildVersion(OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)), build("15.1"))
        for invalid in ["", "1.", ".1", "1..2", "1.2a", "v2", "-1", "1 2", "١٢", "1.2.3.4.5.6.7.8.9", "1234567890"] {
            XCTAssertNil(BuildVersion(invalid), invalid)
        }
    }

    // MARK: The appcast

    func testAnAppcastSignedWithACarriedKeyIsRead() throws {
        let (_, item) = try release(build: "2")
        let envelope = try UpdateSigner.envelope(of: appcast([item]), privateKey: key.privateKey)
        let read = try UpdateVerifier.appcast(from: envelope, keys: keys)
        XCTAssertEqual(read, appcast([item]))
        XCTAssertEqual(read.items.first?.notes, "Build 2.\n<b>not markup</b>", "notes are text, kept as they are")
    }

    func testAForgedAppcastIsRefused() throws {
        let (_, item) = try release(build: "2")
        let envelope = try UpdateSigner.envelope(of: appcast([item]), privateKey: key.privateKey)

        // A byte of the list changed: a build, a URL, a hash.
        assertRefused(.badSignature("appcast")) {
            _ = try UpdateVerifier.appcast(from: try tampered(envelope) { _, payload, _ in
                payload = Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\"build\":\"2\"", with: "\"build\":\"3\"").utf8)
            }, keys: keys)
        }
        // The same list, written differently: the signature is over the bytes, not the meaning.
        assertRefused(.badSignature("appcast")) {
            _ = try UpdateVerifier.appcast(from: try tampered(envelope) { _, payload, _ in payload.append(contentsOf: Array(" ".utf8)) },
                                           keys: keys)
        }
        // A byte of the signature changed.
        assertRefused(.badSignature("appcast")) {
            _ = try UpdateVerifier.appcast(from: try tampered(envelope) { _, _, signature in signature[0] ^= 1 }, keys: keys)
        }
        // Signed by another key that claims a carried key's id.
        let other = UpdateSigner.newKey()
        let forged = try UpdateSigner.envelope(of: appcast([item]), privateKey: other.privateKey)
        assertRefused(.badSignature("appcast")) {
            _ = try UpdateVerifier.appcast(from: try tampered(forged) { json, _, _ in json["keyID"] = UpdateKeys.keyID(of: self.key.publicKey) },
                                           keys: keys)
        }
        // Signed by a key this app does not carry, under its own id.
        assertRefused(.unknownKey(UpdateKeys.keyID(of: other.publicKey))) { _ = try UpdateVerifier.appcast(from: forged, keys: keys) }
        // No signature at all, or not an appcast.
        assertRefused(.badSignature("appcast")) {
            _ = try UpdateVerifier.appcast(from: try tampered(envelope) { _, _, signature in signature = Data() }, keys: keys)
        }
        assertRefused(.notAnAppcast) { _ = try UpdateVerifier.appcast(from: Data("<rss/>".utf8), keys: keys) }
        assertRefused(.notAnAppcast) { _ = try UpdateVerifier.appcast(from: Data(#"{"items": []}"#.utf8), keys: keys) }
    }

    func testAnAppcastOfANewerFormatIsNotJudged() throws {
        let envelope = try UpdateSigner.envelope(of: appcast([]), privateKey: key.privateKey)
        assertRefused(.newerAppcastFormat(2)) {
            _ = try UpdateVerifier.appcast(from: try tampered(envelope) { json, _, _ in json["format"] = 2 }, keys: keys)
        }
    }

    /// A release that cannot be judged refuses the whole list, signed or not.
    func testAReleaseThatCannotBeJudgedRefusesTheList() throws {
        let (_, good) = try release(build: "2")
        var insecure = good
        insecure.url = URL(string: "http://updates.example/a.zip")!
        var notABuild = good
        notABuild.build = "2-beta"
        var notAHash = good
        notAHash.sha256 = String(repeating: "Z", count: 64)
        for (item, detail) in [(insecure, "2: not an https URL"), (notABuild, "2-beta: not a build number"), (notAHash, "2: not a SHA-256")] {
            XCTAssertThrowsError(try UpdateSigner.envelope(of: appcast([item]), privateKey: key.privateKey), "the tooling signs no such list")
            // Signed anyway, by hand.
            let payload = try JSONCoding.encoder.encode(appcast([good, item]))
            let signed = try JSONCoding.encoder.encode(AppcastEnvelope(
                format: 1, keyID: UpdateKeys.keyID(of: key.publicKey), payload: payload,
                signature: Curve25519.Signing.PrivateKey(rawRepresentation: key.privateKey).signature(for: payload)))
            assertRefused(.invalidItem(detail)) { _ = try UpdateVerifier.appcast(from: signed, keys: keys) }
        }
    }

    func testAnOlderAppcastIsRefused() throws {
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        assertRefused(.staleAppcast(generatedAt: seen.addingTimeInterval(-1), newestAccepted: seen)) {
            try UpdateVerifier.checkFreshness(appcast([], generatedAt: seen.addingTimeInterval(-1)), newestAccepted: seen)
        }
        XCTAssertNoThrow(try UpdateVerifier.checkFreshness(appcast([], generatedAt: seen), newestAccepted: seen), "the same one again")
        XCTAssertNoThrow(try UpdateVerifier.checkFreshness(appcast([], generatedAt: seen.addingTimeInterval(60)), newestAccepted: seen))
        XCTAssertNoThrow(try UpdateVerifier.checkFreshness(appcast([], generatedAt: seen), newestAccepted: nil), "the first one")
    }

    // MARK: Which release

    func testOnlyANewerBuildIsEverOffered() throws {
        let older = try release(build: "41").item
        let same = try release(build: "42").item
        let newer = try release(build: "43").item
        let newest = try release(build: "44").item
        let running = BuildVersion("42")!
        XCTAssertEqual(UpdateVerifier.update(in: appcast([older, newest, same, newer]), running: running, system: macOS14, keys: keys), newest)
        XCTAssertNil(UpdateVerifier.update(in: appcast([older, same]), running: running, system: macOS14, keys: keys),
                     "nothing newer: no downgrade, no reinstall")
        assertRefused(.notNewer(build: "41", running: "42")) {
            try UpdateVerifier.checkInstallable(older, running: running, system: self.macOS14, keys: self.keys)
        }
        assertRefused(.notNewer(build: "42", running: "42")) {
            try UpdateVerifier.checkInstallable(same, running: running, system: self.macOS14, keys: self.keys)
        }
        XCTAssertNoThrow(try UpdateVerifier.checkInstallable(newer, running: running, system: macOS14, keys: keys))
    }

    func testAReleaseForANewerMacOSOrAnotherKeyIsNotOffered() throws {
        let forMacOS15 = try release(build: "50", minimumSystem: "15.0").item
        let forMacOS14 = try release(build: "49").item
        let otherKey = try release(build: "51", privateKey: UpdateSigner.newKey().privateKey).item
        let running = BuildVersion("42")!
        let all = appcast([forMacOS15, forMacOS14, otherKey])
        XCTAssertEqual(UpdateVerifier.update(in: all, running: running, system: macOS14, keys: keys), forMacOS14)
        XCTAssertEqual(UpdateVerifier.update(in: all, running: running, system: BuildVersion("15.0")!, keys: keys), forMacOS15)
        assertRefused(.needsNewerSystem("15.0")) {
            try UpdateVerifier.checkInstallable(forMacOS15, running: running, system: self.macOS14, keys: self.keys)
        }
        assertRefused(.unknownKey(otherKey.keyID)) {
            try UpdateVerifier.checkInstallable(otherKey, running: running, system: BuildVersion("15.0")!, keys: self.keys)
        }
    }

    // MARK: The download

    func testTheDownloadIsTheRelease() throws {
        let (archive, item) = try release(build: "43", size: 200_000)
        XCTAssertNoThrow(try UpdateVerifier.checkArchive(at: archive, item: item, keys: keys))

        // One byte changed.
        var bytes = try Data(contentsOf: archive)
        bytes[1000] ^= 0xFF
        try bytes.write(to: archive)
        assertRefused(.archiveHash) { try UpdateVerifier.checkArchive(at: archive, item: item, keys: self.keys) }
        // Cut short, or longer.
        try bytes.prefix(1000).write(to: archive)
        assertRefused(.archiveLength(expected: 200_000, found: 1000)) { try UpdateVerifier.checkArchive(at: archive, item: item, keys: self.keys) }
        // Another archive with its own length and hash in the item, but the release's signature.
        let (other, otherItem) = try release(build: "43", size: 5000)
        var swapped = otherItem
        swapped.edSignature = item.edSignature
        assertRefused(.badSignature("archive")) { try UpdateVerifier.checkArchive(at: other, item: swapped, keys: self.keys) }
        // Signed by a key this app does not carry.
        let (foreign, foreignItem) = try release(build: "43", privateKey: UpdateSigner.newKey().privateKey)
        assertRefused(.unknownKey(foreignItem.keyID)) { try UpdateVerifier.checkArchive(at: foreign, item: foreignItem, keys: self.keys) }
    }

    // MARK: Keys in Info.plist

    func testTheKeysAnInfoPlistNames() {
        let id = UpdateKeys.keyID(of: key.publicKey)
        let other = UpdateSigner.newKey().publicKey
        let keys = UpdateKeys.fromInfoPlist([
            id: key.publicKey.base64EncodedString(),
            "0000000000000000": other.base64EncodedString(), // an id that is not its key's
            UpdateKeys.keyID(of: Data(count: 31)): Data(count: 31).base64EncodedString(), // not a key
        ])
        XCTAssertEqual(keys, [id: key.publicKey])
        XCTAssertEqual(UpdateKeys.fromInfoPlist(nil), [:], "no keys: no updates")
        XCTAssertEqual(id.count, 16)
    }
}
