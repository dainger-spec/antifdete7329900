import XCTest
@testable import BrowserCore

/// Saved passwords since `passwords.bin` format 2: each login has versions and the file keeps
/// deletions, so two copies merge login by login (docs/SYNC_FORMAT.md). The owner's question: a
/// password changed on two devices between syncs — one change silently over the other? No: both
/// are kept, the later in place and the other beside it, for the person to choose.
final class PasswordMergeTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-pwmerge-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let base = PasswordEntry(origin: "https://site.example", username: "me", password: "first",
                                     updatedAt: Date(timeIntervalSince1970: 1_800_000_000), version: UUID(), ancestors: [])

    /// `entry` changed on a device at `time`: a new version, made from the old one.
    private func changed(_ entry: PasswordEntry, password: String, at time: TimeInterval) -> PasswordEntry {
        var next = entry
        next.password = password
        next.updatedAt = Date(timeIntervalSince1970: time)
        next.version = UUID()
        next.ancestors = (entry.ancestors ?? []) + [entry.currentVersion]
        return next
    }

    private func document(_ entries: [PasswordEntry], deleted: [PasswordTombstone] = []) -> PasswordDocument {
        PasswordDocument(entries: entries, deleted: deleted)
    }

    private func passwords(_ document: PasswordDocument) -> [String] { document.entries.map(\.password).sorted() }

    // MARK: Merge

    func testAPasswordChangedOnTwoDevicesBetweenSyncsKeepsBothChanges() {
        let onA = changed(base, password: "from A", at: 1_800_000_100)
        let onB = changed(base, password: "from B", at: 1_800_000_200)
        let merged = PasswordDocument.merge(document([onA]), document([onB]))

        XCTAssertEqual(passwords(merged), ["from A", "from B"], "one change went over the other")
        let login = try? XCTUnwrap(merged.entries.first { $0.id == base.id })
        XCTAssertEqual(login?.password, "from B", "the later change is the login")
        XCTAssertNil(login?.conflictOf)
        let other = merged.entries.first { $0.id != base.id }
        XCTAssertEqual(other?.password, "from A")
        XCTAssertEqual(other?.conflictOf, base.id, "the other change is kept as a version of the same login")
        // The same whichever copy is which, and once only.
        XCTAssertEqual(PasswordDocument.merge(document([onB]), document([onA])), merged)
        XCTAssertEqual(PasswordDocument.merge(merged, merged), merged)
        XCTAssertEqual(PasswordDocument.merge(merged, document([onA])), merged, "merging again with A's copy added something")
        XCTAssertEqual(PasswordDocument.merge(merged, document([onB])), merged, "merging again with B's copy added something")
        // A third device, on the version before both, gets the merge as it is.
        XCTAssertEqual(PasswordDocument.merge(merged, document([base])), merged)
        // And clocks out of step decide which stays, never whether both do.
        let skewed = PasswordDocument.merge(document([changed(base, password: "from A", at: 1_900_000_000)]), document([onB]))
        XCTAssertEqual(passwords(skewed), ["from A", "from B"])
    }

    func testAChangeMadeAfterTheOtherDevicesVersionWinsWithoutAConflict() {
        let onA = changed(base, password: "second", at: 1_800_000_100)
        let onB = changed(onA, password: "third", at: 1_800_000_200)   // B pulled A's, then changed it
        let merged = PasswordDocument.merge(document([onA]), document([onB]))
        XCTAssertEqual(passwords(merged), ["third"])
        // Even when A's clock is ahead.
        let aheadOnA = changed(base, password: "second", at: 1_900_000_000)
        XCTAssertEqual(passwords(PasswordDocument.merge(document([aheadOnA]), document([changed(aheadOnA, password: "third", at: 1_800_000_300)]))),
                       ["third"])
    }

    func testADeletionTakesOnlyTheVersionItSaw() {
        let deleted = PasswordTombstone(id: base.id, versions: [base.currentVersion], deletedAt: Date(timeIntervalSince1970: 1_800_000_100))
        // Deleted on A, unchanged on B: deleted.
        let gone = PasswordDocument.merge(document([], deleted: [deleted]), document([base]))
        XCTAssertEqual(gone.entries, [])
        XCTAssertEqual(gone.deleted.map(\.id), [base.id])
        // Deleted on A while B changed it: B's change survives the deletion.
        let onB = changed(base, password: "changed on B", at: 1_800_000_050)
        let kept = PasswordDocument.merge(document([], deleted: [deleted]), document([onB]))
        XCTAssertEqual(passwords(kept), ["changed on B"])
        XCTAssertEqual(PasswordDocument.merge(document([onB]), document([], deleted: [deleted])), kept)
    }

    func testLoginsSavedBeforeVersionsAgreeOnTwoDevices() throws {
        // Format 1: no versions. The same login on two devices is one login after a merge.
        let old = PasswordEntry(origin: "https://site.example", username: "me", password: "pw", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let array = try JSONCoding.encoder.encode([old])
        let a = try PasswordDocument.decode(array), b = try PasswordDocument.decode(array)
        XCTAssertEqual(PasswordDocument.merge(a, b).entries.count, 1)
        // Changed on one device before the update, not on the other: both kept, none lost.
        var newer = old
        newer.password = "pw2"
        newer.updatedAt = Date(timeIntervalSince1970: 1_700_000_500)
        XCTAssertEqual(passwords(PasswordDocument.merge(a, try PasswordDocument.decode(JSONCoding.encoder.encode([newer])))), ["pw", "pw2"])
    }

    // MARK: The vault

    private func vault() throws -> (PasswordVault, ProfileRepository, UUID) {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root.appendingPathComponent(UUID().uuidString), password: "pw", iterations: 1_000))
        let id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
        return (try repository.passwordVault(for: id), repository, id)
    }

    func testAFillIsNotAChange() throws {
        let (vault, _, _) = try vault()
        try vault.upsert(PasswordEntry(origin: "https://site.example", username: "me", password: "pw"))
        let before = try XCTUnwrap(vault.allEntries().first)
        try vault.markUsed(id: before.id)
        let after = try XCTUnwrap(vault.allEntries().first)
        XCTAssertEqual(after.version, before.version, "a fill made a new version: two devices filling would conflict")
        XCTAssertNotNil(after.lastUsedAt)
    }

    func testAPasswordSavedAgainForTheSameLoginIsAChangeOfIt() throws {
        let (vault, _, _) = try vault()
        try vault.upsert(PasswordEntry(origin: "https://site.example", username: "me", password: "one"))
        let first = try XCTUnwrap(vault.allEntries().first)
        try vault.upsert(PasswordEntry(origin: "https://site.example", username: "me", password: "two"))
        let entries = vault.allEntries()
        XCTAssertEqual(entries.map(\.password), ["two"])
        XCTAssertEqual(entries.first?.id, first.id, "a new login replaced the old one instead of changing it")
        XCTAssertEqual(entries.first?.ancestors, [try XCTUnwrap(first.version)])
    }

    func testAVersionKeptAfterAConflictIsNeverOfferedAndCanBeChosen() throws {
        let (vault, repository, id) = try vault()
        try vault.upsert(PasswordEntry(origin: "https://site.example", username: "me", password: "kept"))
        let login = try XCTUnwrap(vault.allEntries().first)
        // A conflict, as a merge leaves it.
        var other = login
        other.password = "the other"
        other.version = UUID()
        let merged = PasswordDocument.merge(PasswordDocument(entries: [login]),
                                            PasswordDocument(entries: [{ var e = other; e.updatedAt = login.updatedAt.addingTimeInterval(-60); return e }()]))
        let url = repository.passwordsURL(for: id)
        let key = try repository.profileKey(for: id)
        try SecureFile.write(AEAD.seal(JSONCoding.encoder.encode(merged), key: PasswordVault.fileKey(profileID: id, profileKey: key),
                                       aad: PasswordVault.aad(profileID: id)), to: url)
        let reopened = try repository.passwordVault(for: id)
        XCTAssertEqual(reopened.allEntries().count, 2)
        let conflict = try XCTUnwrap(reopened.conflictVersions().first)
        XCTAssertEqual(conflict.password, "the other")
        let origin = try XCTUnwrap(WebOrigin("https://site.example"))
        XCTAssertEqual(reopened.candidates(for: origin).map(\.password), ["kept"], "a version kept after a conflict was offered to a page")
        // Editing the login is not refused as a duplicate of the version kept beside it.
        var edit = try XCTUnwrap(reopened.entry(id: login.id))
        edit.note = "n"
        XCTAssertNoThrow(try reopened.update(edit))

        try reopened.keepConflictVersion(conflict.id)
        XCTAssertEqual(reopened.allEntries().map(\.password), ["the other"])
        XCTAssertEqual(reopened.allEntries().first?.id, login.id)
        XCTAssertEqual(reopened.conflictVersions(), [])
        // A device that still has the conflict takes the choice, and the conflict does not come back.
        let resolved = try PasswordDocument.decode(PasswordVault.open(Data(contentsOf: url), profileID: id, profileKey: key))
        XCTAssertEqual(PasswordDocument.merge(resolved, merged).entries.map(\.password), ["the other"])
    }

    func testAPasswordsFileThatWentAfterItWasReadIsNotEmpty() throws {
        let (vault, repository, id) = try vault()
        for n in 1...3 { try vault.upsert(PasswordEntry(origin: "https://p\(n).example", username: "u", password: "p\(n)")) }
        XCTAssertEqual(vault.allEntries().count, 3)
        try FileManager.default.removeItem(at: repository.passwordsURL(for: id))
        try vault.upsert(PasswordEntry(origin: "https://new.example", username: "u", password: "new"))
        XCTAssertEqual(try repository.passwordVault(for: id).allEntries().map(\.password), ["new", "p1", "p2", "p3"],
                       "the logins read before the file went were dropped")
    }

    // MARK: Two devices

    private func twoDevices() async throws -> (LocalDirectorySyncTransport, ProfileRepository, ProfileRepository, UUID) {
        let transport = LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))
        let a = try ProfileRepository.openedAtUnlock(vault: MasterVault.create(in: root.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let id = try a.create(name: "Shared", configuration: ProfileConfiguration()).id
        _ = try await SyncEngine(repository: a, transport: transport).sync()
        let b = try ProfileRepository.openedAtUnlock(vault: await SyncEngine.bootstrap(transport: transport, root: root.appendingPathComponent("B"), password: "pw"))
        _ = try await SyncEngine(repository: b, transport: transport).sync()
        return (transport, a, b, id)
    }

    private func sync(_ repository: ProfileRepository, _ transport: SyncTransport) async throws {
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
    }

    private func saved(_ repository: ProfileRepository, _ id: UUID) throws -> [String] {
        try repository.passwordVault(for: id).allEntries().map(\.password).sorted()
    }

    func testPasswordsLostOnOneDeviceAreKeptOnTheOthers() async throws {
        let (transport, a, b, id) = try await twoDevices()
        for n in 1...3 { try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://p\(n).example", username: "u", password: "p\(n)")) }
        try await sync(a, transport)
        try await sync(b, transport)
        XCTAssertEqual(try saved(b, id), ["p1", "p2", "p3"])

        try FileManager.default.removeItem(at: a.passwordsURL(for: id))
        try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://new.example", username: "u", password: "new"))
        try await sync(a, transport)
        try await sync(b, transport)
        XCTAssertEqual(try saved(b, id), ["new", "p1", "p2", "p3"], "device B lost the passwords device A had lost")
        try await sync(a, transport)
        XCTAssertEqual(try saved(a, id), ["new", "p1", "p2", "p3"], "device A did not get them back")
    }

    func testAPasswordChangedOnTwoDevicesBetweenSyncsIsKeptBothWaysOnBoth() async throws {
        let (transport, a, b, id) = try await twoDevices()
        try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://site.example", username: "me", password: "first"))
        try await sync(a, transport)
        try await sync(b, transport)
        try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://site.example", username: "me", password: "from A"))
        try b.passwordVault(for: id).upsert(PasswordEntry(origin: "https://site.example", username: "me", password: "from B"))
        try await sync(a, transport)
        try await sync(b, transport)
        try await sync(a, transport)
        for (device, repository) in [("A", a), ("B", b)] {
            XCTAssertEqual(try saved(repository, id), ["from A", "from B"], "device \(device)")
            XCTAssertEqual(try repository.passwordVault(for: id).conflictVersions().count, 1, "device \(device)")
        }
    }

    func testAPasswordDeletedOnOneDeviceIsDeletedOnTheOther() async throws {
        let (transport, a, b, id) = try await twoDevices()
        try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://keep.example", username: "u", password: "keep"))
        try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://gone.example", username: "u", password: "gone"))
        try await sync(a, transport)
        try await sync(b, transport)
        let gone = try XCTUnwrap(b.passwordVault(for: id).allEntries().first { $0.password == "gone" })
        try b.passwordVault(for: id).remove(id: gone.id)
        try await sync(b, transport)
        try await sync(a, transport)
        XCTAssertEqual(try saved(a, id), ["keep"])
    }

    /// The audit's finding 7: `sync-state.bin` lost, so every file looks changed on both sides — a
    /// password saved only on this device was moved to `passwords.bin.conflict` and lost at the next
    /// conflict. Merged now, nothing is set aside.
    func testALostSyncStateLosesNoPassword() async throws {
        let (transport, a, b, id) = try await twoDevices()
        try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://shared.example", username: "u", password: "shared"))
        try await sync(a, transport)
        try await sync(b, transport)
        for n in 1...2 {
            try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://only-a-\(n).example", username: "u", password: "only A \(n)"))
            try FileManager.default.removeItem(at: a.root.appendingPathComponent("sync-state.bin"))
            try await sync(a, transport)
        }
        XCTAssertEqual(try saved(a, id), ["only A 1", "only A 2", "shared"])
        try await sync(b, transport)
        XCTAssertEqual(try saved(b, id), ["only A 1", "only A 2", "shared"])
    }

    // MARK: The vault's generation

    func testUnlockingRaisesTheVaultsGenerationAndSyncCarriesItToTheSyncLocation() async throws {
        let folder = root.appendingPathComponent("old")
        let vault = try MasterVault.create(in: folder, password: "pw", iterations: 1_000)
        // A vault as a version before this one leaves it: generation 1.
        let headerURL = MasterVault.headerURL(in: folder)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: headerURL)) as? [String: Any])
        json["format"] = 1
        try JSONSerialization.data(withJSONObject: json).write(to: headerURL)
        _ = vault
        let transport = LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))
        // A sync location set up by that version.
        let before = try ProfileRepository(vault: MasterVault.unlock(in: folder, password: "pw"))
        XCTAssertEqual(before.vault.header.format, 1)
        _ = try await SyncEngine(repository: before, transport: transport).sync()

        let repository = try ProfileRepository.openedAtUnlock(vault: MasterVault.unlock(in: folder, password: "pw"))
        XCTAssertEqual(try MasterVault.readHeader(in: folder).format, 2)
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        let remote = try await XCTUnwrapAsync(await transport.fetch(objectID: SyncEngine.vaultHeaderObjectID))
        XCTAssertEqual(try VaultHeader.decodeChecked(remote).format, 2, "the sync location keeps generation 1")
        // Records are written in the new envelope, and the old one is still read.
        for object in try await transport.listObjects() where object.objectID != SyncEngine.vaultHeaderObjectID {
            let blob = try await XCTUnwrapAsync(await transport.fetch(objectID: object.objectID))
            let envelope = try JSONCoding.decoder.decode(SyncEnvelope.self, from: blob)
            XCTAssertTrue(SyncEnvelope.readableFormats.contains(envelope.format))
        }
    }

    func testARecordInTheOldEnvelopeIsStillRead() throws {
        let vault = try MasterVault.create(in: root.appendingPathComponent("env"), password: "pw", iterations: 1_000)
        let codec = try SyncCodec(vault: vault)
        let payload = SyncPayload(logicalName: "index", deleted: false, data: Data("x".utf8))
        let objectID = codec.objectID(for: "index")
        let old = try AEAD.seal(JSONCoding.encoder.encode(payload), key: vault.syncEnvelopeKey,
                                aad: SyncCodec.aad(format: "pbsync-1", vaultID: vault.vaultID, objectID: objectID, revision: 3))
        let blob = try JSONCoding.encoder.encode(SyncEnvelope(format: "pbsync-1", vaultID: vault.vaultID, objectID: objectID, revision: 3, ciphertext: old))
        XCTAssertEqual(try codec.decode(blob).payload, payload)
        let new = try JSONCoding.decoder.decode(SyncEnvelope.self, from: codec.encode(payload, revision: 4))
        XCTAssertEqual(new.format, "pbsync-2")
        var newer = new
        newer.format = "pbsync-3"
        XCTAssertThrowsError(try codec.decode(JSONCoding.encoder.encode(newer)))
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
