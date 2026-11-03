import AppKit
import BrowserCore
import CryptoKit
import Foundation
import Network

/// `Lumen --selftest-account-switch`: what a profile's data does while this Mac signs out of one
/// account, into others, and back — the app's own model, as the account screen drives it; the app
/// quit and started again between steps, as a person does; the profiles started in their own
/// processes and a site opened in each, which keeps a cookie, a localStorage item and an IndexedDB
/// record and says what it found of them (the owner, 3 November: a person's history, cookies and
/// saved logins gone from every profile after signing out, into other accounts and back, the master
/// password the same). Profiles are this Mac's, not an account's (CONTRACT §2, §6.3, §12,
/// `signout.consequences`): nothing of them may change with the account.
///
/// One run of the app is one phase (`PB_SWITCH_PHASE`, 1 to `phases.count`); what has to outlive a
/// run — the account server's signing key, the site's port, the visits made — is in
/// `PB_SWITCH_STATE`. `scripts/account_switch_check.py` runs the phases in turn and judges.
///
/// At every measured step, for every profile: its files (path, size, SHA-256), what they hold — the
/// visits of its history, its saved logins, its bookmarks, its synced cookies, its settings' hash —
/// and what its sealed archives hold: WebKit's store (files, bytes, cookies, whether the site's
/// data is in it) and Safari's home (files, bytes, whether the site's address is in it).
///
/// Only with `PB_SELFTEST_ACCOUNT_SWITCH=1` and a vault folder of its own (`PRIVACYBROWSER_VAULT_DIR`).
/// The account server is played here (`FakeAccountServer`), one account at a time.
@MainActor
enum AccountSwitchScenario {
    static let password = "account-switch-check"
    static let visits = 25, logins = 3, bookmarks = 4

    enum Action {
        case make
        case unlock
        case signIn(account: String, email: String, exportOnly: String?)
        case signOut
        /// Each profile started, the site opened in it, its report waited for, the profile stopped.
        case visit
        /// A profile asked to start (export only: it must be refused, and nothing of it change).
        case tryLaunch
        case measure(String)
    }

    /// Each phase is one run of the app, quit at its end.
    static let phases: [[Action]] = [
        [.make, .signIn(account: "a", email: "first@example.com", exportOnly: nil),
         .measure("1 signed in as the first account; two profiles, each with 25 visits, 3 logins, 4 bookmarks"),
         .visit,
         .measure("2 the site opened in each profile (it keeps a cookie, localStorage, IndexedDB), as the first account")],
        [.unlock, .measure("3 the app quit and opened again, as the first account"),
         .visit, .measure("4 the site opened again, as the first account")],
        [.unlock, .signOut, .measure("5 signed out of the first account")],
        [.unlock, .measure("6 the app quit and opened again, signed out"),
         .signIn(account: "b", email: "second@example.com", exportOnly: nil),
         .measure("7 signed in as a second account"),
         .visit, .measure("8 the site opened in each profile, as the second account")],
        [.unlock, .signOut, .signIn(account: "c", email: "third@example.com", exportOnly: "no_license"),
         .measure("9 signed out of the second; signed in as a third account without a license (export only)"),
         .tryLaunch, .measure("10 a profile asked to start, as the third account")],
        [.unlock, .signOut, .measure("11 signed out of the third account")],
        [.unlock, .signIn(account: "a", email: "first@example.com", exportOnly: nil),
         .measure("12 signed in as the first account again"),
         .visit, .measure("13 the site opened in each profile, as the first account again")],
        [.unlock, .measure("14 the app quit and opened again, as the first account")],
    ]

    /// What outlives a run of the app.
    struct State: Codable {
        var signer: Data
        var sitePort: UInt16 = 0
        var profiles: [UUID] = []
        var names: [String: String] = [:]
        var account = "a"
        var deviceID = UUID().uuidString.lowercased()
        var deviceToken = "lmd_switch"
        var exportOnly: String?
        /// The site's visits each profile made so far: what the site must find at the next.
        var visitsMade: [String: Int] = [:]
    }

    static func start() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let environment = ProcessInfo.processInfo.environment
        guard environment["PB_SELFTEST_ACCOUNT_SWITCH"] == "1",
              let folder = environment["PRIVACYBROWSER_VAULT_DIR"], !folder.isEmpty,
              let statePath = environment["PB_SWITCH_STATE"], !statePath.isEmpty,
              let phase = Int(environment["PB_SWITCH_PHASE"] ?? ""), (1...phases.count).contains(phase) else {
            print("ACCOUNT-SWITCH usage: scripts/account_switch_check.py runs this, with PB_SELFTEST_ACCOUNT_SWITCH=1, "
                + "a vault folder of its own in PRIVACYBROWSER_VAULT_DIR, PB_SWITCH_STATE and PB_SWITCH_PHASE (1–\(phases.count))")
            exit(64)
        }
        let root = AppEnvironment.vaultDirectory
        if phase == 1, MasterVault.exists(in: root) {
            print("ACCOUNT-SWITCH FAIL a vault is already in its folder: this scenario makes its own")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 280) {
            print("ACCOUNT-SWITCH FAIL phase \(phase): no end in 280 s")
            exit(3)
        }
        Task { @MainActor in
            do {
                try await run(phase: phase, root: root, statePath: URL(fileURLWithPath: statePath))
                print("ACCOUNT-SWITCH phase \(phase) done")
                if phase == phases.count { print("ACCOUNT-SWITCH last phase done") }
                exit(0)
            } catch {
                print("ACCOUNT-SWITCH FAIL phase \(phase): \(error)")
                exit(1)
            }
        }
        app.run()
    }

    private static func run(phase: Int, root: URL, statePath: URL) async throws {
        var state: State
        if phase == 1 {
            state = State(signer: Curve25519.Signing.PrivateKey().rawRepresentation)
        } else {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: statePath))
        }
        func save() throws { try JSONEncoder().encode(state).write(to: statePath, options: .atomic) }

        // The account server as it stands: the same signing key in every run, the account and this
        // Mac's device as the last run left them.
        let server = FakeAccountServer(signer: try Curve25519.Signing.PrivateKey(rawRepresentation: state.signer))
        server.accountID = state.account
        server.deviceID = state.deviceID
        server.deviceToken = state.deviceToken
        server.exportOnlyReason = state.exportOnly
        guard await server.start() else { throw Failure("the account server played here did not start") }
        defer { server.stop() }
        setenv("PB_ACCOUNT_SERVER_URL", "http://127.0.0.1:\(server.port)", 1)
        setenv("PB_ENTITLEMENT_PUBLIC_KEYS", "\(server.keyID)=\(server.publicKey.base64EncodedString())", 1)

        // The site, on the same port in every run: localStorage and IndexedDB are kept per origin.
        let site = SwitchSite()
        guard await site.start(port: state.sitePort) else {
            throw Failure("the site played here did not start on port \(state.sitePort)")
        }
        defer { site.stop() }
        state.sitePort = site.port
        try save()
        print("ACCOUNT-SWITCH phase \(phase): account server on \(server.port), site on \(site.port)")

        var model: AppModel?
        for action in phases[phase - 1] {
            switch action {
            case .make:
                let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: password, iterations: 10_000))
                for name in ["One", "Two"] {
                    let profile = try repository.create(name: "Switch \(name)", configuration: ProfileConfiguration())
                    try seed(repository, profile.id)
                    state.profiles.append(profile.id)
                    state.names[profile.id.uuidString] = "Switch \(name)"
                }
                try save()
                print("ACCOUNT-SWITCH a vault with \(state.profiles.count) profiles made, each with \(visits) visits, "
                    + "\(logins) logins, \(bookmarks) bookmarks")
                model = try await opened()
            case .unlock:
                model = try await opened()
                print("ACCOUNT-SWITCH opened: mode \(String(describing: model?.license.mode)), signed in: \(model?.license.record.isSignedIn == true)")
            case .signIn(let account, let email, let exportOnly):
                guard let model else { throw Failure("signing in before the vault was opened") }
                state.account = account
                state.deviceID = UUID().uuidString.lowercased()
                state.deviceToken = "lmd_switch_\(account)_\(UUID().uuidString.prefix(8))"
                state.exportOnly = exportOnly
                server.accountID = account
                server.deviceID = state.deviceID
                server.deviceToken = state.deviceToken
                server.exportOnlyReason = exportOnly
                try save()
                try await signIn(model, server: server, account: account, email: email)
            case .signOut:
                guard let model else { throw Failure("signing out before the vault was opened") }
                let outcome = await model.license.signOut(vault: model.unlockedVaultForAccount)
                print("ACCOUNT-SWITCH signed out: \(String(describing: outcome)), mode \(String(describing: model.license.mode))")
                // The control (`account_switch_check.py --control`): the loss the person saw, made here
                // at the first sign-out — the check must fail on it.
                if ProcessInfo.processInfo.environment["PB_SWITCH_CONTROL"] == "1", phase == 3, let repository = model.repositoryForChecks {
                    for id in state.profiles {
                        for name in ["webdata.pbsa", "cookies.bin", "history.bin", "passwords.bin"] {
                            try? FileManager.default.removeItem(at: repository.directory(for: id).appendingPathComponent(name))
                        }
                    }
                    print("ACCOUNT-SWITCH CONTROL removed every profile's webdata.pbsa, cookies.bin, history.bin, passwords.bin")
                }
            case .visit:
                guard let model else { throw Failure("a visit before the vault was opened") }
                for id in state.profiles {
                    let expected = state.visitsMade[id.uuidString] ?? 0
                    let name = state.names[id.uuidString] ?? id.uuidString
                    if try await visit(model, site: site, id: id, name: name, step: phase, expected: expected) {
                        state.visitsMade[id.uuidString] = expected + 1
                        try save()
                    }
                }
            case .tryLaunch:
                guard let model, let id = state.profiles.first else { throw Failure("a launch before the vault was opened") }
                await model.launch(id)
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let running = model.isRunning(id)
                print("ACCOUNT-SWITCH asked to start \(state.names[id.uuidString] ?? "?"): \(running ? "STARTED" : "refused, as export only must")")
                if running {
                    await model.stop(id)
                    try await waitStopped(model, id)
                }
            case .measure(let step):
                guard let model else { throw Failure("a measure before the vault was opened") }
                measure(step, model, state: state)
            }
        }
        await model?.lock()
    }

    /// The app as it starts: its model made, the vault opened with the master password.
    private static func opened() async throws -> AppModel {
        let model = AppModel()
        await model.unlock(password: password)
        guard model.phase == .unlocked else { throw Failure("the vault did not open: \(model.phase)") }
        return model
    }

    // MARK: Steps

    private static func signIn(_ model: AppModel, server: FakeAccountServer, account: String, email: String) async throws {
        guard case .signedIn = await model.license.signIn(email: email, password: server.signInPassword) else {
            throw Failure("signing in as \(account) did not give a session")
        }
        switch await model.license.activate(label: "", vault: model.unlockedVaultForAccount) {
        case .success:
            print("ACCOUNT-SWITCH signed in as account \(account), mode \(String(describing: model.license.mode))")
        case .failure(let failure):
            print("ACCOUNT-SWITCH signed in as account \(account), this Mac not connected: \(failure); mode \(String(describing: model.license.mode))")
        }
    }

    /// The profile started as the list starts it — its own process, Safari's window — the site opened
    /// in a window of its own, its report waited for, the profile stopped (which seals its data).
    /// True when the site reported.
    private static func visit(_ model: AppModel, site: SwitchSite, id: UUID, name: String, step: Int, expected: Int) async throws -> Bool {
        await model.launch(id)
        let up = Date().addingTimeInterval(90)
        while !model.isRunning(id), Date() < up { try await Task.sleep(nanoseconds: 200_000_000) }
        guard model.isRunning(id) else {
            print("ACCOUNT-SWITCH PAGE \(name) step=\(step) expected=\(expected) NOT-STARTED")
            return false
        }
        let marker = UUID().uuidString.prefix(8).lowercased()
        site.reports[String(marker)] = nil
        let url = URL(string: "http://127.0.0.1:\(site.port)/switch?profile=\(marker)&step=\(step)")!
        model.manager?.openWindow(id, url: url)
        let deadline = Date().addingTimeInterval(45)
        while site.reports[String(marker)] == nil, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        let report = site.reports[String(marker)]
        if let report {
            print("ACCOUNT-SWITCH PAGE \(name) step=\(step) expected=\(expected) \(report)")
        } else {
            print("ACCOUNT-SWITCH PAGE \(name) step=\(step) expected=\(expected) NO-REPORT")
        }
        // The page's writes reach WebKit's store before the profile is stopped.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await model.stop(id)
        try await waitStopped(model, id)
        return report != nil
    }

    private static func waitStopped(_ model: AppModel, _ id: UUID) async throws {
        let down = Date().addingTimeInterval(90)
        while model.isRunning(id) || model.isBusy(id), Date() < down { try await Task.sleep(nanoseconds: 200_000_000) }
        print("ACCOUNT-SWITCH stopped \(id.uuidString.prefix(8)): \(model.isRunning(id) || model.isBusy(id) ? "STILL running after 90 s" : "stopped and sealed")")
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
    }

    /// One step's facts, as lines the script reads: `ACCOUNT-SWITCH STEP`, then for each profile a
    /// `COUNT` line and a `FILE` line per file (hashes cut to twelve characters).
    private static func measure(_ step: String, _ model: AppModel, state: State) {
        print("ACCOUNT-SWITCH STEP \(step)")
        guard let repository = model.repositoryForChecks else {
            print("ACCOUNT-SWITCH COUNT - the vault is not open")
            return
        }
        let listed = repository.list()
        print("ACCOUNT-SWITCH LISTED \(listed.count) profiles: \(listed.map(\.name).sorted().joined(separator: ", "))")
        for summary in listed {
            let id = summary.id
            let name = summary.name.replacingOccurrences(of: " ", with: "_")
            var counts: [String] = []
            do {
                let key = try repository.profileKey(for: id)
                counts.append("history=\(try repository.historyStore(for: id, key: key).count)")
                counts.append("logins=\(try repository.passwordVault(for: id).allEntries().count)")
                counts.append("bookmarks=\(try repository.bookmarkStore(for: id, key: key).all().count)")
                let jar = try repository.cookieJar(for: id).cookies
                counts.append("cookies=\(jar.count)")
                counts.append("cookies-site=\(jar.contains { $0.cookie.name == "pbswitch" } ? "yes" : "no")")
                let configuration = try repository.loadConfiguration(id, key: key)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                counts.append("settings=\(hash((try? encoder.encode(configuration)) ?? Data()))")
                counts.append(contentsOf: archive(repository.webDataArchiveURL(for: id), key: key, prefix: "webdata",
                                                  needles: ["pbswitch"]))
                counts.append(contentsOf: archive(repository.safariHomeArchiveURL(for: id), key: key, prefix: "safarihome",
                                                  needles: ["127.0.0.1:\(state.sitePort)/switch"]))
            } catch {
                counts.append("unreadable=\(String(describing: error).replacingOccurrences(of: " ", with: "_"))")
            }
            let live = webKitStore(of: id)
            counts.append("webkit-store-outside-the-vault=\(live.map { "\($0)B" } ?? "none")")
            print("ACCOUNT-SWITCH COUNT \(name) \(counts.joined(separator: " "))")
            let directory = repository.directory(for: id)
            let base = directory.resolvingSymlinksInPath().path
            let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])?
                .compactMap { $0 as? URL } ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path }
            let total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            print("ACCOUNT-SWITCH FILES \(name) \(files.count) files, \(total) bytes")
            for file in files where !file.path.contains("/home.noindex/") {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let digest = (try? Data(contentsOf: file)).map(hash) ?? "unreadable"
                let full = file.resolvingSymlinksInPath().path
                let path = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : full
                print("ACCOUNT-SWITCH FILE \(name) \(path.replacingOccurrences(of: " ", with: "_")) \(size) \(digest)")
            }
        }
    }

    /// A sealed archive opened into a folder of its own, read, and removed: its files and bytes,
    /// the cookies of a `Cookies.binarycookies` in it, and which of its files hold each needle (as
    /// UTF-8 or UTF-16). `<prefix>=none` without one.
    private static func archive(_ url: URL, key: SymmetricKey, prefix: String, needles: [String]) -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return ["\(prefix)=none"] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pb-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try EncryptedDirectoryArchive.unseal(from: url, key: key) { label in folder.appendingPathComponent(label, isDirectory: true) }
        } catch {
            return ["\(prefix)=unreadable"]
        }
        var files = 0, bytes = 0, cookies = 0
        var holding: [String: [String]] = [:]
        let found = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        for file in found {
            guard let data = try? Data(contentsOf: file) else { continue }
            files += 1
            bytes += data.count
            if file.lastPathComponent.hasSuffix(".binarycookies") { cookies += cookieNames(data).count }
            for needle in needles {
                let forms = [Data(needle.utf8), needle.data(using: .utf16LittleEndian) ?? Data()]
                if forms.contains(where: { !$0.isEmpty && data.range(of: $0) != nil }) {
                    holding[needle, default: []].append(file.lastPathComponent.replacingOccurrences(of: " ", with: "_"))
                }
            }
        }
        var facts = ["\(prefix)-files=\(files)", "\(prefix)-bytes=\(bytes)"]
        if prefix == "webdata" { facts.append("\(prefix)-cookies=\(cookies)") }
        for (index, needle) in needles.enumerated() {
            let where_ = holding[needle].map { Set($0).sorted().joined(separator: "+") } ?? "nowhere"
            facts.append("\(prefix)-site\(index == 0 ? "" : "\(index)")=\(where_)")
        }
        return facts
    }

    /// The cookies' names in WebKit's `Cookies.binarycookies` (big-endian page table, little-endian
    /// pages): counted, never printed.
    private static func cookieNames(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<4]) == [0x63, 0x6f, 0x6f, 0x6b] else { return [] }
        func be32(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= bytes.count else { return 0 }
            return (0..<4).reduce(0) { ($0 << 8) | Int(bytes[at + $1]) }
        }
        func le32(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= bytes.count else { return 0 }
            return (0..<4).reversed().reduce(0) { ($0 << 8) | Int(bytes[at + $1]) }
        }
        func text(_ at: Int) -> String {
            guard at >= 0, at < bytes.count else { return "" }
            var end = at
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }
        let pages = be32(4)
        guard pages > 0, pages < 10_000 else { return [] }
        var start = 8 + 4 * pages
        var names: [String] = []
        for page in 0..<pages {
            let size = be32(8 + 4 * page)
            let count = le32(start + 4)
            if count > 0, count < 100_000 {
                for index in 0..<count {
                    let cookie = start + le32(start + 8 + 4 * index)
                    names.append(text(cookie + le32(cookie + 20)))
                }
            }
            start += size
        }
        return names
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

/// The site the profiles open (`AccountSwitchScenario`): `/switch` reads its cookie, localStorage
/// item and IndexedDB record, writes each as one more visit, and reports what it read to `/report`.
@MainActor
final class SwitchSite {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    /// What each page reported, by the marker its address carried: `cookie=… local=… idb=…`.
    var reports: [String: String] = [:]

    func start(port wanted: UInt16) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let endpoint = wanted == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: wanted) ?? .any)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpoint)
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if listener.state == .ready, let bound = listener.port?.rawValue, bound != 0 {
                port = bound
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
                if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                    let first = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                    let parts = first.split(separator: " ")
                    self.answer(parts.count >= 2 ? String(parts[1]) : "/", on: connection)
                } else if done || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: data)
                }
            }
        }
    }

    private func answer(_ target: String, on connection: NWConnection) {
        var status = 404
        var type = "text/plain"
        var body = Data("not here".utf8)
        if target.hasPrefix("/switch") {
            status = 200
            type = "text/html; charset=utf-8"
            body = Data(Self.page.utf8)
        } else if target.hasPrefix("/report?") {
            let query = String(target.dropFirst("/report?".count))
            var fields: [String: String] = [:]
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { fields[parts[0]] = parts[1].replacingOccurrences(of: " ", with: "_") }
            }
            if let marker = fields["profile"] {
                reports[marker] = ["cookie", "local", "idb", "next", "idbWritten"].map { "\($0)=\(fields[$0] ?? "?")" }.joined(separator: " ")
            }
            status = 204
            body = Data()
        }
        var response = Data("HTTP/1.1 \(status) \(status < 300 ? "OK" : "Not Found")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Reads, then writes one more visit to, a persistent cookie, a localStorage item and an
    /// IndexedDB record — all named `pbswitch` — and reports what it read.
    static let page = """
        <!doctype html><meta charset="utf-8"><title>Account switch check</title>
        <p id="state">reading</p>
        <script>
        (async () => {
          const q = new URLSearchParams(location.search);
          const read = {};
          const m = document.cookie.match(/(?:^|; )pbswitch=(\\d+)/);
          read.cookie = m ? Number(m[1]) : 0;
          read.local = Number(localStorage.getItem('pbswitch') || 0);
          let db = null;
          try {
            db = await new Promise((ok, fail) => {
              const r = indexedDB.open('pbswitch', 1);
              r.onupgradeneeded = () => r.result.createObjectStore('kv');
              r.onsuccess = () => ok(r.result);
              r.onerror = () => fail(r.error);
            });
            read.idb = await new Promise((ok, fail) => {
              const r = db.transaction('kv').objectStore('kv').get('visits');
              r.onsuccess = () => ok(Number(r.result || 0));
              r.onerror = () => fail(r.error);
            });
          } catch (e) { read.idb = 'error ' + e; }
          const next = Math.max(read.cookie, read.local, typeof read.idb === 'number' ? read.idb : 0) + 1;
          document.cookie = 'pbswitch=' + next + '; max-age=2592000; path=/';
          localStorage.setItem('pbswitch', String(next));
          let written = 'no';
          if (db) {
            written = await new Promise((ok) => {
              const t = db.transaction('kv', 'readwrite');
              t.objectStore('kv').put(next, 'visits');
              t.oncomplete = () => ok('yes');
              t.onerror = () => ok('error');
            });
          }
          document.getElementById('state').textContent = 'visit ' + next;
          await fetch('/report?profile=' + encodeURIComponent(q.get('profile')) + '&cookie=' + read.cookie + '&local=' + read.local
            + '&idb=' + encodeURIComponent(read.idb) + '&next=' + next + '&idbWritten=' + written, {cache: 'no-store'});
        })();
        </script>
        """
}
