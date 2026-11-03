import AppKit
import BrowserCore
import CryptoKit
import Foundation

/// `Lumen --selftest-account-switch`: what a profile's data does while this Mac signs out of one
/// account, into another, and back — the app's own model, as the account screen drives it, and the
/// profiles launched and stopped in their own processes between (the owner, 3 November: a person's
/// history, cookies and saved logins gone from every profile after signing out, into other accounts
/// and back, the master password the same). Profiles are this Mac's, not an account's (CONTRACT §2,
/// §6.3, §12, `signout.consequences`): nothing of them may change with the account.
///
/// At every step it writes down, for every profile, its files (path, size, SHA-256) and what they
/// hold — the visits of its history, its saved logins, its bookmarks, its synced cookies, its
/// settings' hash — and whether WebKit's store of it is on disk outside the vault. `scripts/
/// account_switch_check.py` runs it and judges the counts.
///
/// Only with `PB_SELFTEST_ACCOUNT_SWITCH=1` and a vault folder of its own (`PRIVACYBROWSER_VAULT_DIR`)
/// that holds no vault yet. The account server is played here (`FakeAccountServer`), one account at
/// a time.
@MainActor
enum AccountSwitchScenario {
    static let password = "account-switch-check"
    static let visits = 25, logins = 3, bookmarks = 4, cookies = 5

    static func start() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let environment = ProcessInfo.processInfo.environment
        guard environment["PB_SELFTEST_ACCOUNT_SWITCH"] == "1",
              let folder = environment["PRIVACYBROWSER_VAULT_DIR"], !folder.isEmpty else {
            print("ACCOUNT-SWITCH usage: scripts/account_switch_check.py runs this, with PB_SELFTEST_ACCOUNT_SWITCH=1 "
                + "and a vault folder of its own in PRIVACYBROWSER_VAULT_DIR")
            exit(64)
        }
        let root = AppEnvironment.vaultDirectory
        guard !MasterVault.exists(in: root) else {
            print("ACCOUNT-SWITCH FAIL a vault is already in its folder: this scenario makes its own")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 900) {
            print("ACCOUNT-SWITCH FAIL no end in 900 s")
            exit(3)
        }
        Task { @MainActor in
            do {
                try await run(root: root)
                print("ACCOUNT-SWITCH done")
                exit(0)
            } catch {
                print("ACCOUNT-SWITCH FAIL \(error)")
                exit(1)
            }
        }
        app.run()
    }

    private static func run(root: URL) async throws {
        let server = FakeAccountServer()
        guard await server.start() else { throw Failure("the account server played here did not start") }
        setenv("PB_ACCOUNT_SERVER_URL", "http://127.0.0.1:\(server.port)", 1)
        setenv("PB_ENTITLEMENT_PUBLIC_KEYS", "\(server.keyID)=\(server.publicKey.base64EncodedString())", 1)

        // A vault with two profiles and their data, as the app keeps them.
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: password, iterations: 10_000))
        var ids: [UUID] = []
        for name in ["One", "Two"] {
            let profile = try repository.create(name: "Switch \(name)", configuration: ProfileConfiguration())
            try seed(repository, profile.id)
            ids.append(profile.id)
        }
        print("ACCOUNT-SWITCH a vault with \(ids.count) profiles made, each with \(visits) visits, \(logins) logins, "
            + "\(bookmarks) bookmarks, \(cookies) cookies")

        let model = AppModel()
        await model.unlock(password: password)
        guard model.phase == .unlocked else { throw Failure("the vault did not open: \(model.phase)") }

        try await signIn(model, server: server, account: "a", email: "first@example.com")
        measure("1 signed in as the first account, the data made", model)
        try await launchAndStop(model, ids)
        measure("2 the profiles launched and stopped, as the first account", model)

        await signOut(model)
        measure("3 signed out of the first account", model)

        try await signIn(model, server: server, account: "b", email: "second@example.com")
        measure("4 signed in as a second account", model)
        try await launchAndStop(model, ids)
        measure("5 the profiles launched and stopped, as the second account", model)

        await model.lock()
        await model.unlock(password: password)
        measure("6 locked and opened again, as the second account", model)

        await signOut(model)
        measure("7 signed out of the second account", model)

        try await signIn(model, server: server, account: "a", email: "first@example.com")
        measure("8 signed in as the first account again", model)
        try await launchAndStop(model, ids)
        measure("9 the profiles launched and stopped, as the first account again", model)

        await model.lock()
        server.stop()
    }

    // MARK: Steps

    private static func signIn(_ model: AppModel, server: FakeAccountServer, account: String, email: String) async throws {
        server.accountID = account
        server.deviceID = UUID().uuidString.lowercased()
        server.deviceToken = "lmd_switch_\(account)_\(UUID().uuidString.prefix(8))"
        guard case .signedIn = await model.license.signIn(email: email, password: server.signInPassword) else {
            throw Failure("signing in as \(account) did not give a session")
        }
        switch await model.license.activate(label: "", vault: model.unlockedVaultForAccount) {
        case .success:
            print("ACCOUNT-SWITCH signed in as account \(account), mode \(String(describing: model.license.mode))")
        case .failure(let failure):
            throw Failure("activating as \(account) failed: \(failure)")
        }
    }

    private static func signOut(_ model: AppModel) async {
        let outcome = await model.license.signOut(vault: model.unlockedVaultForAccount)
        print("ACCOUNT-SWITCH signed out: \(String(describing: outcome)), mode \(String(describing: model.license.mode))")
    }

    /// Each profile started as the list starts it — its own process, Safari's window — and stopped
    /// after a few seconds, which seals its data again.
    private static func launchAndStop(_ model: AppModel, _ ids: [UUID]) async throws {
        for id in ids {
            await model.launch(id)
            let up = Date().addingTimeInterval(90)
            while !model.isRunning(id), Date() < up { try await Task.sleep(nanoseconds: 200_000_000) }
            print("ACCOUNT-SWITCH launched \(id.uuidString.prefix(8)): \(model.isRunning(id) ? "running" : "NOT running after 90 s")")
            try await Task.sleep(nanoseconds: 4_000_000_000)
            await model.stop(id)
            let down = Date().addingTimeInterval(90)
            while model.isRunning(id) || model.isBusy(id), Date() < down { try await Task.sleep(nanoseconds: 200_000_000) }
            print("ACCOUNT-SWITCH stopped \(id.uuidString.prefix(8)): \(model.isRunning(id) || model.isBusy(id) ? "STILL running after 90 s" : "stopped and sealed")")
        }
    }

    // MARK: The data

    private static func seed(_ repository: ProfileRepository, _ id: UUID) throws {
        let key = try repository.profileKey(for: id)
        let history = try repository.historyStore(for: id, key: key)
        for number in 0..<visits {
            _ = history.recordVisit(url: URL(string: "https://site\(number % 7).example/page/\(number)")!, title: "Page \(number)",
                                    at: Date().addingTimeInterval(Double(-number) * 60))
        }
        try history.save()
        let passwordVault = try repository.passwordVault(for: id)
        for number in 0..<logins {
            try passwordVault.upsert(PasswordEntry(origin: "https://login\(number).example", username: "person\(number)",
                                                   password: "secret-\(number)-\(UUID().uuidString.prefix(6))"))
        }
        let marks = try repository.bookmarkStore(for: id, key: key)
        for number in 0..<bookmarks {
            _ = try marks.add(title: "Mark \(number)", url: URL(string: "https://mark\(number).example/")!) // l10n: not text
        }
        // As a stop records the store's cookies into the synced document.
        let store = (0..<cookies).map { number in
            ImportedCookie(name: "c\(number)", value: "v\(number)", domain: "cookie\(number).example", hostOnly: true,
                           expires: Date().addingTimeInterval(30 * 86_400), secure: true)
        }
        try repository.saveCookieJar(CookieJarDocument().recording(store: store, baseline: [], at: Date()), for: id)
    }

    /// One step's facts, as lines the script reads: `ACCOUNT-SWITCH STEP`, then for each profile a
    /// `COUNT` line and a `FILE` line per file (hashes cut to twelve characters).
    private static func measure(_ step: String, _ model: AppModel) {
        print("ACCOUNT-SWITCH STEP \(step)")
        guard let repository = model.repositoryForChecks else {
            print("ACCOUNT-SWITCH COUNT - the vault is not open")
            return
        }
        for summary in repository.list() {
            let id = summary.id
            let name = summary.name
            var counts: [String] = []
            do {
                let key = try repository.profileKey(for: id)
                counts.append("history=\(try repository.historyStore(for: id, key: key).count)")
                counts.append("logins=\(try repository.passwordVault(for: id).allEntries().count)")
                counts.append("bookmarks=\(try repository.bookmarkStore(for: id, key: key).all().count)")
                counts.append("cookies=\(try repository.cookieJar(for: id).cookies.count)")
                let configuration = try repository.loadConfiguration(id, key: key)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let data = (try? encoder.encode(configuration)) ?? Data()
                counts.append("settings=\(hash(data))")
            } catch {
                counts.append("unreadable: \(error)")
            }
            let live = webKitStore(of: id)
            counts.append("webkit-store-outside-the-vault=\(live.map { "\($0) bytes" } ?? "none")")
            print("ACCOUNT-SWITCH COUNT \(name) \(counts.joined(separator: " "))")
            let directory = repository.directory(for: id)
            let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])?
                .compactMap { $0 as? URL } ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path }
            let total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            print("ACCOUNT-SWITCH FILES \(name) \(files.count) files, \(total) bytes")
            for file in files where !file.path.contains("/home.noindex/") {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let digest = (try? Data(contentsOf: file)).map(hash) ?? "unreadable"
                let path = String(file.path.dropFirst(directory.path.count + 1))
                print("ACCOUNT-SWITCH FILE \(name) \(path) \(size) \(digest)")
            }
        }
    }

    /// WebKit's store of the profile outside the vault (while it runs, or left unsealed): its size.
    private static func webKitStore(of id: UUID) -> Int? {
        let bundle = Bundle.main.bundleIdentifier ?? "io.lumenbrowser.Lumen"
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/\(bundle)/WebsiteDataStore", isDirectory: true)
        for name in [id.uuidString, id.uuidString.lowercased()] {
            let folder = base.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let sizes = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?
                .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } } ?? []
            return sizes.reduce(0, +)
        }
        return nil
    }

    private static func hash(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }
}
