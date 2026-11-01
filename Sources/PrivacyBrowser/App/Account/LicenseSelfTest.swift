import BrowserCore
import CryptoKit
import Foundation
import Network

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
/// - the server's `device_revoked` signs this Mac out, and says why.
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

    static func run(scratch: URL) async -> [Result] {
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
        return results
    }

    private static func contains(_ data: Data, _ forms: [String]) -> Bool {
        forms.contains { data.range(of: Data($0.utf8)) != nil }
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
    private(set) var port: UInt16 = 0
    private(set) var requests: [String] = []
    private(set) var lastActivation: Activation?
    /// Refreshes answer `401 device_revoked`.
    var revoked = false
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
        let fields = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        let machineID = fields["machineID"] as? String ?? ""
        var status = 200
        var body: [String: Any]
        switch request.path {
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
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A pro plan's document for this Mac, issued now: four days full, three more of grace.
    private func document(machineID: String) -> [String: Any] {
        let now = Date()
        func at(_ hours: Double) -> String { now.addingTimeInterval(hours * 3_600).formatted(.iso8601) }
        let payload: [String: Any] = [
            "kind": "lumen.entitlement", "version": 1, "documentID": UUID().uuidString.lowercased(), "accountID": "a", "licenseID": "l",
            "deviceID": deviceID, "machineID": machineID, "role": "owner", "plan": "pro", "status": "active", "exportReason": NSNull(),
            "limits": ["profiles": 50, "devices": 3, "seats": 1], "profilesOnOtherDevices": 0, "periodEndsAt": at(30 * 24),
            "issuedAt": at(0), "refreshAfter": at(24), "expiresAt": at(96), "graceEndsAt": at(168),
        ]
        let bytes = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let signature = (try? signer.signature(for: bytes)) ?? Data()
        return ["format": 1, "keyID": keyID, "payload": bytes.base64EncodedString(), "signature": signature.base64EncodedString()]
    }
}
