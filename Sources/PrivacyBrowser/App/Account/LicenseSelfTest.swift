import BrowserCore
import CryptoKit
import Foundation
import Network
import OSLog

/// The self-test's licensing group: the app's own license (`LicenseModel`, `AccountHTTP` over this
/// Mac's loopback) against an account server played here — documents signed with a key made for
/// the run and trusted through the environment, as a development build allows (`AccountConfiguration`).
/// What it shows, each with how it could fail:
///
/// - without signing in, a profile does not open (the gate in `ProfileManager.launch`);
/// - a key signs in and connects this Mac; the key is then in no file but the vault's sealed one —
///   not in `account.json`, not in the app's defaults, not in the diagnostics ZIP, whose search is
///   first shown to find a key planted in a ZIP of its own (a search that cannot fail checks nothing);
/// - the server gone silent changes nothing: the Mac works on, and says until when (the GRACE date);
/// - the server's `device_revoked` signs this Mac out, and says why;
/// - an expired document, one under a forged signature, another Mac's, and a stored one changed on
///   disk are each refused — no work, no profile opens — where the document of step 2, through the
///   same activation and the same gate, passed: their control;
/// - the master password is not the key (§10.1): the key typed in this session, in every form it can
///   be typed in, or kept in the vault — another key and a plain password are not it (the controls);
/// - "don't remember the key": no copy in the vault, one kept before removed — where step 3 kept it;
/// - an email linked only with this purchase's code, confirmed by the letter's; the key replaced, the
///   vault keeping the new one, this Mac connected again with it; a kept key the server no longer
///   knows removed; the key, the new key and the purchase code in no log, file or address — the
///   searches first shown to find what they look for.
@MainActor
enum LicenseSelfTest {
    struct Result {
        let name: String
        let passed: Bool
        let detail: String
    }

    private static let keyText = "LMK-0123-4567-89AB-CDEF-GHJK-MNMT"
    /// Every form the key could be written in: as typed, without hyphens, in lower case.
    private static let keyForms = [keyText, "0123456789ABCDEFGHJKMNMT", "0123456789abcdefghjkmnmt", "0123-4567-89AB", "0123-4567-89ab"]
    /// The key a replacement gives (the server's vector), and the purchase's code — in every form.
    private static let newKeyText = "LMK-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZWB"
    private static let newKeyForms = [newKeyText, "ZZZZZZZZZZZZZZZZZZZZZZWB", "zzzzzzzzzzzzzzzzzzzzzzwb", "ZZZZ-ZZWB", "zzzz-zzwb"]
    private static let purchaseCodeText = "LPC-0123-4567-89AB-CDEF-GHSY"
    private static let purchaseCodeForms = [purchaseCodeText, "0123456789ABCDEFGHSY", "0123456789abcdefghsy", "CDEF-GHSY", "cdef-ghsy"]

    static func run(scratch: URL) async -> [Result] {
        let began = Date()
        var results: [Result] = []
        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            results.append(Result(name: "licensing: " + name, passed: passed, detail: passed ? "" : detail()))
        }
        let server = FakeAccountServer()
        guard await server.start() else {
            check("the account server played here listens on this Mac's loopback", false, "it did not start")
            return results
        }
        defer { server.stop() }
        let root = scratch.appendingPathComponent("license-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = AccountConfiguration(serverURL: URL(string: "http://127.0.0.1:\(server.port)")!,
                                                 siteURL: URL(string: "http://127.0.0.1:\(server.port)")!,
                                                 keys: [server.keyID: server.publicKey], source: .environment)
        let license = LicenseModel(root: root, configuration: configuration)
        guard MachineIdentity.machineID != nil else {
            check("this Mac's hardware UUID can be read (IOPlatformUUID)", false, "IOKit gave none")
            return results
        }

        // 1. Not signed in: no profile opens.
        let vault: UnlockedVault
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            vault = try MasterVault.create(in: root.appendingPathComponent("vault"), password: "license-check", iterations: 1_000)
            repository = try ProfileRepository(vault: vault)
            profile = try repository.create(name: "License check", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 1), matchProxyLocation: false))
        } catch {
            check("a vault and a profile to check with", false, String(describing: error))
            return results
        }
        license.profilesHere = { [profile] in [profile] }
        let manager = ProfileManager(repository: repository)
        manager.launchGate = { [weak license] id in license?.refusalToOpen(id) }
        defer { Task { await manager.shutDown() } }
        check("not signed in, the mode is NOT_SIGNED_IN", license.mode == .notSignedIn, "\(String(describing: license.mode))")
        var refused: Error?
        do { try await manager.launch(profile.id, openingWindow: false) } catch { refused = error }
        check("not signed in, a profile does not open — and says it is the rule", refused is LicenseRefusal,
              refused.map { String(describing: $0) } ?? "it started")

        // 2. A key: read before anything is sent; then this Mac is connected.
        guard case .key(let key) = AccountKeyInput.classify(keyText.lowercased().replacingOccurrences(of: "-", with: " ")) else {
            check("a key typed in lower case with spaces reads", false, "it did not")
            return results
        }
        check("a typo in a key is caught before any request", AccountKeyInput.classify(String(keyText.dropLast()) + "U") == .typo
              && server.requests.isEmpty, "requests: \(server.requests)")
        license.useKey(key)
        let activation = await license.activate(label: "", vault: nil)
        check("a key connects this Mac (activation with the key in the body, no Authorization)",
              (try? activation.get()) != nil && license.mode == .full && license.record.signedInWith == .key
              && server.lastActivation?.hadAuthorization == false && server.lastActivation?.key == keyText,
              "\(activation), mode \(String(describing: license.mode)), request \(String(describing: server.lastActivation))")

        // 3. Where the key is, and is not.
        license.vaultOpened(vault)
        let accountFile = (try? Data(contentsOf: root.appendingPathComponent("account.json"))) ?? Data()
        check("account.json was written (0600) and holds no form of the key", !accountFile.isEmpty && !contains(accountFile, keyForms),
              accountFile.isEmpty ? "no account.json" : "a form of the key is in it")
        let sealed = (try? Data(contentsOf: vault.root.appendingPathComponent("account-key.bin"))) ?? Data()
        check("the key is kept in the vault, sealed: account-key.bin exists and holds no form of it",
              !sealed.isEmpty && !contains(sealed, keyForms) && (try? AccountKeyVault.load(from: vault)) == key,
              sealed.isEmpty ? "no account-key.bin" : "it is not sealed, or does not read back")
        let defaults = Data(String(describing: UserDefaults.standard.dictionaryRepresentation()).utf8)
        check("the app's defaults hold no form of the key", !contains(defaults, keyForms), "a form of the key is in the defaults")
        let planted = (try? StoredZip.archive([StoredZip.Entry(path: "planted.txt", data: Data(keyText.utf8))])) ?? Data()
        check("the diagnostics' search finds a key planted in a ZIP (the search can fail)", contains(planted, keyForms), "not found")
        let bundle = await Diagnostics.bundle(Diagnostics.snapshot(repository: repository), logMinutes: 1)
        check("the diagnostics ZIP holds no form of the key, and none of the server's tokens",
              !bundle.isEmpty && !contains(bundle, keyForms + [server.deviceToken]), bundle.isEmpty ? "no ZIP" : "a key or a token is in it")
        // The system's log, as this process wrote it since the group began: every line of every
        // subsystem, not only the app's. A marker written now in clear must be found in it first.
        let marker = "lumen-key-log-check-\(UUID().uuidString)"
        Logger(subsystem: "PrivacyBrowser", category: "SelfTest").notice("\(marker, privacy: .public)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let log = processLog(since: began)
        check("this process's log is read whole: a line just written in clear is found in it (the search can fail)",
              log.contains(marker), log.isEmpty ? "the log could not be read" : "the marker was not found in \(log.count) characters")
        check("this process's log holds no form of the key, and none of the server's tokens",
              !log.isEmpty && !contains(Data(log.utf8), keyForms + [server.deviceToken]), log.isEmpty ? "no log" : "a key or a token is in the log")
        // The automation API, signed in with the key: what every route answers (its handler, as the
        // server calls it), a start refused by the license among them.
        let automation = AutomationHandler(manager: manager, repository: repository)
        manager.launchGate = { _ in LicenseRefusal(text: "the automation API's start, refused for this check") }
        var answers = Data()
        let id = profile.id.uuidString
        for route: AutomationRoute in [.listProfiles, .profile(id), .start(id, window: false), .open(id, url: URL(string: "https://example.com")!), .stop(id)] {
            let response = await automation.handle(route)
            answers.append(Data("\(response.status) ".utf8))
            answers.append(response.body)
        }
        manager.launchGate = { [weak license] id in license?.refusalToOpen(id) }
        check("the automation API's answers (list, profile, start, open, stop) hold no form of the key, and none of the server's tokens",
              answers.count > 40 && !contains(answers, keyForms + [server.deviceToken]),
              answers.count > 40 ? "a key or a token is in them" : "no answers")

        // 4. The server silent: nothing changes, and the Mac says until when it works.
        server.stop()
        await license.refresh()
        let until = license.state?.worksWithoutServerUntil
        check("the server silent, the refresh is \"unreachable\" and the mode stays FULL",
              license.lastRefresh == .unreachable(retryAfter: nil) && license.mode == .full,
              "\(String(describing: license.lastRefresh)), \(String(describing: license.mode))")
        check("without the server, the Mac works until the GRACE date, and says so",
              until != nil && until == license.state?.entitlement.map(LicenseDecision.graceDate),
              "until \(String(describing: until))")

        // 5. Revoked: signed out, and the banner says why.
        server.revoked = true
        guard await server.start() else {
            check("the account server played here starts again", false, "it did not")
            return results
        }
        let revokedLicense = LicenseModel(root: root, configuration: AccountConfiguration(
            serverURL: URL(string: "http://127.0.0.1:\(server.port)")!, siteURL: configuration.siteURL, keys: configuration.keys, source: .environment))
        await revokedLicense.refresh()
        check("the server's device_revoked signs this Mac out, and the banner says why",
              revokedLicense.mode == .notSignedIn && revokedLicense.state?.banners.first == .deviceRevoked,
              "\(String(describing: revokedLicense.mode)), \(String(describing: revokedLicense.state?.banners))")

        // 6. Documents that must be refused (the owner, 2 November: an expired one, a forged
        //    signature, another Mac's — each must go red), each in an account of its own on this Mac,
        //    through the same activation and the same gate as the document of step 2, which passed
        //    and is their control. Then a stored document changed on disk.
        server.revoked = false
        let serverURL = URL(string: "http://127.0.0.1:\(server.port)")!
        func freshLicense(_ name: String) -> (model: LicenseModel, folder: URL) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let model = LicenseModel(root: folder, configuration: AccountConfiguration(
                serverURL: serverURL, siteURL: configuration.siteURL, keys: configuration.keys, source: .environment))
            model.profilesHere = { [profile] in [profile] }
            model.useKey(key)
            return (model, folder)
        }
        /// The gate a profile meets when it opens, with this license's decision.
        func gateRefuses(_ model: LicenseModel) async -> Bool {
            manager.launchGate = { [weak model] id in model?.refusalToOpen(id) }
            var refusal: Error?
            do { try await manager.launch(profile.id, openingWindow: false) } catch { refusal = error }
            if refusal == nil, manager.isRunning(profile.id) { try? await manager.stop(profile.id) }
            return refusal is LicenseRefusal
        }
        func refusedDocument(_ result: Swift.Result<LicenseModel.ActivationOutcome, AccountFailure>) -> EntitlementCheck? {
            if case .failure(.document(let check)) = result { return check }
            return nil
        }

        server.serve = .expired
        let expired = freshLicense("expired").model
        let expiredActivation = await expired.activate(label: "", vault: nil)
        let expiredGate = await gateRefuses(expired)
        check("an expired document (signed, for this Mac, its grace and period over) gives no work: export only, a profile does not open",
              expired.mode == .exportOnly && expiredGate,
              "activation \(expiredActivation), mode \(String(describing: expired.mode)), gate refused: \(expiredGate)")

        server.serve = .forgedSignature
        let forged = freshLicense("forged").model
        let forgedActivation = await forged.activate(label: "", vault: nil)
        let forgedGate = await gateRefuses(forged)
        check("a document under a forged signature is refused: this Mac is not connected, a profile does not open",
              refusedDocument(forgedActivation) == .badSignature && forged.mode == .notSignedIn && forgedGate,
              "activation \(forgedActivation), mode \(String(describing: forged.mode)), gate refused: \(forgedGate)")

        server.serve = .otherMac
        let other = freshLicense("other-mac").model
        let otherActivation = await other.activate(label: "", vault: nil)
        let otherGate = await gateRefuses(other)
        check("another Mac's document (signed, its machineID not this Mac's) is refused: not connected, a profile does not open",
              refusedDocument(otherActivation) == .wrongDevice && other.mode == .notSignedIn && otherGate,
              "activation \(otherActivation), mode \(String(describing: other.mode)), gate refused: \(otherGate)")

        // A stored document given a year more on disk, its signature kept: the same account worked
        // before the change (FULL, the profile opens), and is export-only after it.
        server.serve = .valid
        let (stored, folder) = freshLicense("changed-on-disk")
        _ = await stored.activate(label: "", vault: nil)
        let storedMode = stored.mode
        // Asked of the license alone: in FULL the gate would start the profile.
        let storedOpens = stored.refusalToOpen(profile.id) == nil
        let file = AccountFile(directory: folder)
        var changed = false
        if var record = try? file.load(), var envelope = record.entitlement,
           var payload = (try? JSONSerialization.jsonObject(with: envelope.payload)) as? [String: Any] {
            let later = Date().addingTimeInterval(365 * 86_400).formatted(.iso8601)
            for field in ["expiresAt", "graceEndsAt", "periodEndsAt"] { payload[field] = later }
            if let bytes = try? JSONSerialization.data(withJSONObject: payload) {
                envelope.payload = bytes
                record.entitlement = envelope
                changed = (try? file.save(record)) != nil
            }
        }
        let reread = LicenseModel(root: folder, configuration: AccountConfiguration(
            serverURL: serverURL, siteURL: configuration.siteURL, keys: configuration.keys, source: .environment))
        reread.profilesHere = { [profile] in [profile] }
        let rereadGate = await gateRefuses(reread)
        check("a stored document changed on disk (a year more, its signature kept) is refused at the next start: export only, a profile does not open"
              + " — unchanged it was FULL and the profile opened",
              storedMode == .full && storedOpens && changed && reread.state?.check == .badSignature && reread.mode == .exportOnly && rereadGate,
              "before: \(String(describing: storedMode)), opens \(storedOpens); changed: \(changed); after: \(String(describing: reread.state?.check)),"
              + " \(String(describing: reread.mode)), gate refused \(rereadGate)")

        // 7. §10.1: the master password is not the license's key. "Don't remember the key": the key is
        //    not held after its request, and no copy is in the vault — one kept before goes — where
        //    step 3's remembered key was kept: the control. Its echo still knows it, in every form.
        let unkeptFolder = root.appendingPathComponent("not-remembered", isDirectory: true)
        try? FileManager.default.createDirectory(at: unkeptFolder, withIntermediateDirectories: true)
        let unkept = LicenseModel(root: unkeptFolder, configuration: AccountConfiguration(
            serverURL: serverURL, siteURL: configuration.siteURL, keys: configuration.keys, source: .environment))
        unkept.profilesHere = { [profile] in [profile] }
        unkept.useKey(key, remember: false)
        let unkeptActivation = await unkept.activate(label: "", vault: nil)
        let heldAfterRequest = unkept.key != nil
        // A copy kept by an earlier sign-in, as a vault may hold one.
        let unkeptVault = try? MasterVault.create(in: unkeptFolder.appendingPathComponent("vault"), password: "license-check-unkept", iterations: 1_000)
        if let unkeptVault { try? AccountKeyVault.save(key, to: unkeptVault) }
        let keptBefore = unkeptVault.map { (try? AccountKeyVault.load(from: $0)) == key } ?? false
        if let unkeptVault { unkept.vaultOpened(unkeptVault) }
        let keptAfter = unkeptVault.flatMap { try? AccountKeyVault.load(from: $0) }
        let unkeptRecord = try? AccountFile(directory: unkeptFolder).load()
        let unkeptFile = (try? Data(contentsOf: unkeptFolder.appendingPathComponent("account.json"))) ?? Data()
        check("\"don't remember the key\": this Mac is connected, the key is not held after its request, the vault keeps no copy — the one kept before is"
              + " removed (step 3 kept it: the control) — and account.json says so, with no form of the key",
              (try? unkeptActivation.get()) != nil && !heldAfterRequest && keptBefore && unkeptVault != nil && keptAfter == nil
              && unkeptRecord?.rememberKey == false && !unkeptFile.isEmpty && !contains(unkeptFile, keyForms),
              "activation \(unkeptActivation), held after: \(heldAfterRequest), kept before: \(keptBefore), kept after: \(keptAfter != nil),"
              + " rememberKey \(String(describing: unkeptRecord?.rememberKey))")
        let typedForms = [keyText, keyText.lowercased(), keyText.replacingOccurrences(of: "-", with: ""), String(keyText.dropFirst(4)),
                          keyText.replacingOccurrences(of: "-", with: " "), keyText.replacingOccurrences(of: "1", with: "I")]
        let otherKey = "LMK-0000-0000-0000-0000-0000-0000"
        let knowsTheKey = typedForms.filter { unkept.isLicenseKey($0) }.count
        let takesOthers = unkept.isLicenseKey(otherKey) || unkept.isLicenseKey("correct horse battery staple") || unkept.isLicenseKey(keyText + "!")
        unkept.forgetComparisons()
        let afterForgetting = unkept.isLicenseKey(keyText)
        check("§10.1: a master password that is the key is refused even when the key is not kept — the key's echo knows it in each of"
              + " \(typedForms.count) forms it can be typed in; another key, a plain password and the key with a character more are not it"
              + " (the controls); after the master password's step nothing is left to compare",
              knowsTheKey == typedForms.count && !takesOthers && !afterForgetting,
              "known in \(knowsTheKey) of \(typedForms.count) forms, others taken: \(takesOthers), after forgetting: \(afterForgetting)")
        license.forgetComparisons()
        let byKeptKey = license.isLicenseKey(keyText.lowercased())
        license.vaultLocked()
        let afterLock = license.isLicenseKey(keyText)
        check("§10.1 at an unlock: the master password is compared with the key the vault keeps (no echo left): it is the key; after the lock,"
              + " nothing held, it is not — compared in memory only, nothing tried on the vault",
              byKeptKey && !afterLock, "with the kept key: \(byKeptKey), after the lock: \(afterLock)")

        // 8. An email linked, then the key replaced (§11.1) — with the key the vault keeps.
        guard let code = PurchaseCode(typed: purchaseCodeText.lowercased()), let otherCode = PurchaseCode(typed: "LPC-0000-0000-0000-0000-0000") else {
            check("the self-test's purchase codes read", false, "they did not")
            return results
        }
        let (linker, linkerFolder) = freshLicense("email-and-new-key")
        let linkerActivation = await linker.activate(label: "", vault: nil)
        guard (try? linkerActivation.get()) != nil,
              let linkerVault = try? MasterVault.create(in: linkerFolder.appendingPathComponent("vault"), password: "license-check-link", iterations: 1_000) else {
            check("a Mac connected with the key, its vault keeping it, to link an email from", false, "\(linkerActivation)")
            return results
        }
        linker.vaultOpened(linkerVault)
        // Another Mac of the license, its vault keeping the key too (the first license above talks to the
        // server's first port, gone since step 4).
        let (otherMac, otherMacFolder) = freshLicense("another-mac")
        let otherMacActivation = await otherMac.activate(label: "", vault: nil)
        let otherMacVault = try? MasterVault.create(in: otherMacFolder.appendingPathComponent("vault"), password: "license-check-other", iterations: 1_000)
        if let otherMacVault { otherMac.vaultOpened(otherMacVault) }
        let email = "person@example.com"
        let refusedProof = await linker.linkEmail(typedKey: nil, purchaseCode: otherCode, email: email, password: "a long password 1")
        let sent = await linker.linkEmail(typedKey: nil, purchaseCode: code, email: email, password: "a long password 1")
        let refusedCode: String? = { if case .failure(.server(let error)) = refusedProof { return error.code }; return nil }()
        check("an email is linked only with this purchase's code: another code is refused (proof_refused, error.proof_refused), this one"
              + " sends the letter (202 check_email, its numbers)",
              refusedCode == "proof_refused" && LicenseText.error(.server(AccountServerError(status: 403, code: "proof_refused")), withKey: true) == L("contract.error.proof_refused")
              && (try? sent.get()) == AccountAPI.CodeSent(codeValidSeconds: 900, codeAttempts: 5),
              "another code: \(refusedProof), this code: \(sent)")
        let wrongDigits = await linker.confirmEmail(typedKey: nil, email: email, code: "000000")
        let confirmed = await linker.confirmEmail(typedKey: nil, email: email, code: server.emailCode)
        let wrongDigitsCode: String? = { if case .server(let error)? = wrongDigits { return error.code }; return nil }()
        check("the letter's code confirms the address: a wrong one is refused (invalid_code); the right one links it — emailLinked, a session for"
              + " the account screen — and nothing is reissued: the key still works, this Mac stays connected by it",
              wrongDigitsCode == "invalid_code" && confirmed == nil && linker.record.emailLinked == true
              && linker.record.session?.sessionToken == ServerToken(server.sessionToken) && linker.record.signedInWith == .key
              && linker.mode == .full && linker.keyAtHand,
              "wrong code: \(String(describing: wrongDigits)), right code: \(String(describing: confirmed)), emailLinked \(String(describing: linker.record.emailLinked)),"
              + " mode \(String(describing: linker.mode))")
        let replaced = await linker.replaceKey(.purchase(key, code), label: "")
        let replacement = try? replaced.get()
        let newKey = AccountKey(typed: newKeyText)
        let keptNew = try? AccountKeyVault.load(from: linkerVault)
        check("the key replaced with the key and the purchase code: the new key comes, the vault keeps it instead of the old one, and this Mac —"
              + " unlinked with every other — is connected again with it; the email stays linked",
              replacement != nil && replacement?.key == newKey && replacement?.kept == true && replacement?.reconnection == nil && keptNew == newKey
              && server.lastActivation?.key == newKeyText && linker.mode == .full && linker.record.emailLinked == true,
              "\(replaced), kept: \(keptNew == newKey), activation \(String(describing: server.lastActivation)), mode \(String(describing: linker.mode))")
        // The old key, kept on the other Mac, is now unknown to the server.
        let heldBefore = (try? otherMacActivation.get()) != nil && otherMac.key == key
            && otherMacVault.map { (try? AccountKeyVault.load(from: $0)) == key } == true
        let stale = await otherMac.devices()
        let staleCode: String? = { if case .failure(.server(let error)) = stale { return error.code }; return nil }()
        check("a kept key the server no longer knows (replaced on another Mac: key_not_found, key.not_found) goes from the vault and is asked"
              + " for anew — it was kept and held before (the control)",
              heldBefore && staleCode == "key_not_found"
              && LicenseText.error(.server(AccountServerError(status: 404, code: "key_not_found")), withKey: true) == L("contract.key.not_found")
              && otherMac.key == nil && otherMacVault.map { (try? AccountKeyVault.load(from: $0)) == nil } == true,
              "held before: \(heldBefore), answer \(stale), held after: \(otherMac.key != nil)")
        let retrieval = await linker.keyRetrievalSeconds()

        // 9. Where the keys and the purchase code went: the requests' bodies, and the vault, sealed.
        let secretForms = keyForms + newKeyForms + purchaseCodeForms
        check("the key, the new key and the purchase code went in the requests' bodies only, never in an address — the purchase code was"
              + " found in a body (the search can find it)",
              server.bodies.contains { contains($0, purchaseCodeForms) } && !server.requests.contains { contains(Data($0.utf8), secretForms) },
              "addresses: \(server.requests)")
        let linkerFile = (try? Data(contentsOf: linkerFolder.appendingPathComponent("account.json"))) ?? Data()
        check("account.json after the email and the new key holds no form of either key nor of the purchase code",
              !linkerFile.isEmpty && !contains(linkerFile, secretForms), linkerFile.isEmpty ? "no account.json" : "a key or the code is in it")
        let sealedNew = (try? Data(contentsOf: linkerVault.root.appendingPathComponent("account-key.bin"))) ?? Data()
        check("the new key is kept sealed: account-key.bin holds no form of it", !sealedNew.isEmpty && !contains(sealedNew, newKeyForms),
              sealedNew.isEmpty ? "no account-key.bin" : "it is not sealed")
        let secondMarker = "lumen-key-log-check-\(UUID().uuidString)"
        Logger(subsystem: "PrivacyBrowser", category: "SelfTest").notice("\(secondMarker, privacy: .public)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let finalLog = processLog(since: began)
        check("this process's log after the email and the new key holds no form of either key, the purchase code or the session's token —"
              + " a line just written in clear is found in it (the search can fail)",
              finalLog.contains(secondMarker) && !contains(Data(finalLog.utf8), secretForms + [server.sessionToken]),
              finalLog.contains(secondMarker) ? "a key, the code or the token is in the log" : "the marker was not found in \(finalLog.count) characters")
        let finalBundle = await Diagnostics.bundle(Diagnostics.snapshot(repository: repository), logMinutes: 2)
        check("the diagnostics ZIP after the email and the new key holds no form of either key, the purchase code or the session's token",
              !finalBundle.isEmpty && !contains(finalBundle, secretForms + [server.sessionToken]), finalBundle.isEmpty ? "no ZIP" : "a secret is in it")
        // "Lost your key?" says how long the site gives the key again — from the server only (§17.1).
        server.stop()
        let retrievalOffline = await linker.keyRetrievalSeconds()
        check("\"Lost your key?\" takes the time the site gives the key again from GET /v1/plans (30 days here); the server silent, none — the screen"
              + " then says error.unreachable, never a number of its own",
              retrieval == 2_592_000 && retrievalOffline == nil, "from the server: \(String(describing: retrieval)), silent: \(String(describing: retrievalOffline))")
        manager.launchGate = { [weak license] id in license?.refusalToOpen(id) }
        return results
    }

    private static func contains(_ data: Data, _ forms: [String]) -> Bool {
        forms.contains { data.range(of: Data($0.utf8)) != nil }
    }

    /// `Lumen --key-crash-check [--control]` (scripts/key_crash_check.py, CI): this process signs in
    /// with the key against an account server played here, keeps the key in a vault, and crashes on
    /// purpose, the key still held; macOS writes its crash report, which the script searches for every
    /// form of the key. The crash is on a queue of its own, whose name the report keeps (the crash
    /// summary of CI finds the self-test's deliberate crash by its queue's name); a fatal error's own
    /// message is not in the report (CI run 601). The control crashes the same way on a queue named
    /// with the key's text: its report must hold it, or the search proves nothing.
    private static var keptForTheCrash: [Any] = []

    static func crashCheck(control: Bool) async -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let server = FakeAccountServer()
        guard await server.start() else {
            print("KEY-CRASH FAIL the account server played here did not start")
            exit(2)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-key-crash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = URL(string: "http://127.0.0.1:\(server.port)")!
        let license = LicenseModel(root: root, configuration: AccountConfiguration(
            serverURL: base, siteURL: base, keys: [server.keyID: server.publicKey], source: .environment))
        guard case .key(let key) = AccountKeyInput.classify(keyText) else {
            print("KEY-CRASH FAIL the key did not read")
            exit(2)
        }
        license.useKey(key)
        let activation = await license.activate(label: "", vault: nil)
        guard (try? activation.get()) != nil, license.mode == .full,
              let vault = try? MasterVault.create(in: root.appendingPathComponent("vault"), password: "key-crash", iterations: 1_000) else {
            print("KEY-CRASH FAIL the key did not sign in: \(activation)")
            exit(2)
        }
        license.vaultOpened(vault)
        let kept = (try? AccountKeyVault.load(from: vault)) == key
        try? FileManager.default.removeItem(at: root)
        let label = control ? "PBKeyCrashCheck.control." + keyText : "PBKeyCrashCheck.crash"
        let queueSaid = control ? "named with the key's text (the control)" : "PBKeyCrashCheck.crash"
        print("KEY-CRASH signed in with the key, kept in a vault: \(kept); pid \(getpid()); crashing on purpose on the queue \(queueSaid)")
        // Held until the crash: the key in memory, as the app holds it. (Xcode 26's compiler could not
        // check withExtendedLifetime around the fatal error inside the queue's block: CI runs 602, 603.)
        keptForTheCrash = [license, key, vault, server]
        DispatchQueue(label: label).async {
            fatalError("the key-in-a-crash-report check: a crash on purpose")
        }
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        print("KEY-CRASH FAIL the crash on purpose did not happen in 30 s")
        exit(3)
    }

    /// Every line this process wrote to the system's log since `start`, of every subsystem.
    private static func processLog(since start: Date) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: start)) else { return "" }
        var text = ""
        for entry in entries { text += entry.composedMessage + "\n" }
        return text
    }
}

/// An account server played on this Mac's loopback for the self-test: activation and refresh, its
/// documents signed with a key made for the run.
@MainActor
final class FakeAccountServer {
    struct Activation: CustomStringConvertible {
        var hadAuthorization: Bool
        var key: String?
        var description: String { "Authorization \(hadAuthorization ? "sent" : "none"), key \(key == nil ? "none" : "sent")" }
    }

    private let signer = Curve25519.Signing.PrivateKey()
    let deviceID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    let deviceToken = "lmd_selftest_device_token"
    /// The purchase this server plays (§11.1): its key — replaced by `/v1/anonymous/key/replace` — and
    /// its purchase code; the letter's code; the session a linked email opens.
    private(set) var currentKey = "LMK-0123-4567-89AB-CDEF-GHJK-MNMT"
    let replacementKey = "LMK-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZWB"
    let purchaseCode = "LPC-0123-4567-89AB-CDEF-GHSY"
    let emailCode = "424242"
    let sessionToken = "lms_selftest_session_token"
    private(set) var emailLinked = false
    private(set) var port: UInt16 = 0
    private(set) var requests: [String] = []
    /// Every request's body, as it came.
    private(set) var bodies: [Data] = []
    private(set) var lastActivation: Activation?
    /// Refreshes answer `401 device_revoked`.
    var revoked = false
    /// The documents it signs: as they should be, or one this app must refuse.
    enum Serve { case valid, expired, forgedSignature, otherMac }
    var serve = Serve.valid
    /// Another key, claiming to be the server's (`.forgedSignature`).
    private let forger = Curve25519.Signing.PrivateKey()
    private var listener: NWListener?

    var publicKey: Data { signer.publicKey.rawRepresentation }
    var keyID: String { EntitlementKeys.keyID(of: publicKey) }

    func start() async -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if listener.state == .ready, let port = listener.port?.rawValue, port != 0 {
                self.port = port
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var data = buffer
                if let chunk { data.append(chunk) }
                if let request = Self.parse(data) {
                    self.answer(request, on: connection)
                } else if done || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: data)
                }
            }
        }
    }

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = head.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        requests.append("\(request.method) \(request.path)")
        bodies.append(request.body)
        let fields = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        let machineID = fields["machineID"] as? String ?? ""
        let sentKey = fields["key"] as? String
        let keyUnknown = sentKey != nil && sentKey != currentKey
        func refusal(_ code: String) -> [String: Any] { ["error": ["code": code, "message": "self-test"]] }
        var status = 200
        var body: [String: Any]
        switch request.path {
        case "/v1/devices/activate" where keyUnknown,
             "/v1/anonymous/license" where keyUnknown,
             "/v1/anonymous/email" where keyUnknown,
             "/v1/anonymous/email/confirm" where keyUnknown,
             "/v1/anonymous/key/replace" where keyUnknown:
            status = 404
            body = refusal("key_not_found")
        case "/v1/anonymous/license":
            body = ["devices": [["deviceID": deviceID, "code": "B119", "label": "", "mine": true]], "limit": 3, "used": 1,
                    "unlinkAvailableAt": NSNull(), "unlinkCooldownSeconds": 604_800, "offlineWorkSeconds": 604_800, "emailLinked": emailLinked]
        case "/v1/anonymous/email" where fields["purchaseCode"] as? String != purchaseCode,
             "/v1/anonymous/key/replace" where fields["purchaseCode"] as? String != purchaseCode:
            status = 403
            body = refusal("proof_refused")
        case "/v1/anonymous/email":
            status = 202
            body = ["status": "check_email", "codeValidSeconds": 900, "codeAttempts": 5]
        case "/v1/anonymous/email/confirm" where fields["code"] as? String != emailCode:
            status = 400
            body = refusal("invalid_code")
        case "/v1/anonymous/email/confirm":
            emailLinked = true
            status = 201
            body = ["sessionToken": sessionToken, "expiresAt": Date().addingTimeInterval(30 * 86_400).formatted(.iso8601),
                    "accountID": "a", "idleTimeoutSeconds": 604_800]
        case "/v1/anonymous/key/replace":
            currentKey = replacementKey
            body = ["key": replacementKey]
        case "/v1/plans":
            body = ["withoutRegistration": ["plans": ["personal", "pro"], "keyRetrievalSeconds": 2_592_000]]
        case "/v1/devices/activate":
            lastActivation = Activation(hadAuthorization: request.headers["authorization"] != nil, key: fields["key"] as? String)
            body = ["device": ["deviceID": deviceID, "code": "B119", "label": "", "mine": true],
                    "deviceToken": deviceToken, "entitlement": document(machineID: machineID), "serverTime": Date().formatted(.iso8601)]
        case "/v1/device/entitlement" where revoked:
            status = 401
            body = ["error": ["code": "device_revoked", "message": "unlinked"]]
        case "/v1/device/entitlement":
            body = ["entitlement": document(machineID: machineID), "serverTime": Date().formatted(.iso8601)]
        default:
            status = 404
            body = ["error": ["code": "not_found", "message": "no such address"]]
        }
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var response = Data("HTTP/1.1 \(status) \((200..<300).contains(status) ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A pro plan's document for this Mac, issued now: four days full, three more of grace. As
    /// `serve` says: issued a month ago (its grace and its period over), signed by another key under
    /// the server's key id, or for another Mac.
    private func document(machineID: String) -> [String: Any] {
        let now = Date()
        let issued: Double = serve == .expired ? -30 * 24 : 0
        func at(_ hours: Double) -> String { now.addingTimeInterval((issued + hours) * 3_600).formatted(.iso8601) }
        let forMachine = serve == .otherMac ? MachineID.compute(platformUUID: UUID().uuidString) : machineID
        let payload: [String: Any] = [
            "kind": "lumen.entitlement", "version": 1, "documentID": UUID().uuidString.lowercased(), "accountID": "a", "licenseID": "l",
            "deviceID": deviceID, "machineID": forMachine, "role": "owner", "plan": "pro", "status": "active", "exportReason": NSNull(),
            "limits": ["profiles": 50, "devices": 3, "seats": 1], "profilesOnOtherDevices": 0,
            "periodEndsAt": at(serve == .expired ? 14 * 24 : 30 * 24),
            "issuedAt": at(0), "refreshAfter": at(24), "expiresAt": at(96), "graceEndsAt": at(168),
        ]
        let bytes = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let signature = (try? (serve == .forgedSignature ? forger : signer).signature(for: bytes)) ?? Data()
        return ["format": 1, "keyID": keyID, "payload": bytes.base64EncodedString(), "signature": signature.base64EncodedString()]
    }
}
