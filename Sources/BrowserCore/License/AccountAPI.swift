import Foundation

/// The account server's API as the app uses it (the server's `docs/CONTRACT.md` §2–§6, §9): the
/// requests, the answers, and what each answer means for this Mac. The network itself is the app's
/// (`AccountTransport`): the manager process only, an ephemeral session — never a profile's process.
///
/// Nothing here is logged with what it carries: a request's body may hold a password or a key, and
/// tokens never say themselves (`ServerToken`, `AccountKey`).
public struct AccountRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    public var method: Method
    /// From the server's base address: `/v1/…`.
    public var path: String
    /// JSON, or nil.
    public var body: Data?
    /// `Authorization: Bearer <token>`: the session's or the device's, as the address asks (§2).
    public var bearer: ServerToken?

    public init(method: Method, path: String, body: Data? = nil, bearer: ServerToken? = nil) {
        self.method = method
        self.path = path
        self.body = body
        self.bearer = bearer
    }
}

/// What came back: the status, the body, the `Retry-After` header.
public struct AccountResponse: Sendable {
    public var status: Int
    public var body: Data
    public var retryAfter: String?

    public init(status: Int, body: Data, retryAfter: String? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Sends a request to the account server. Throws when no answer came at all (no network, DNS, TLS,
/// a timeout, a cut connection): that is "unreachable" (§9.3).
public protocol AccountTransport: Sendable {
    func send(_ request: AccountRequest) async throws -> AccountResponse
}

/// One of the license's Macs (`GET /v1/account/devices`, `device_limit_reached`, §10.6).
public struct AccountDevice: Codable, Equatable, Sendable, Identifiable {
    public var deviceID: String
    public var code: String
    public var label: String
    public var createdAt: Date?
    public var lastSeenAt: Date?
    public var profileCount: Int?
    public var appVersion: String?
    /// The account's own (a team member's Macs are not, for the owner).
    public var mine: Bool?
    /// A team member's email, shown to the team's owner only.
    public var accountEmail: String?

    public var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID, code, label, createdAt, lastSeenAt, profileCount, appVersion, mine, accountEmail
    }

    /// Read leniently: a field missing or of another type is left empty, so that one odd device
    /// does not make a whole list — or an error's list — unreadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        code = (try? container.decode(String.self, forKey: .code)) ?? ""
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        createdAt = try? container.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try? container.decode(Date.self, forKey: .lastSeenAt)
        profileCount = try? container.decode(Int.self, forKey: .profileCount)
        appVersion = try? container.decode(String.self, forKey: .appVersion)
        mine = try? container.decode(Bool.self, forKey: .mine)
        accountEmail = try? container.decode(String.self, forKey: .accountEmail)
    }

    public init(deviceID: String, code: String, label: String = "", createdAt: Date? = nil, lastSeenAt: Date? = nil,
                profileCount: Int? = nil, appVersion: String? = nil, mine: Bool? = nil, accountEmail: String? = nil) {
        self.deviceID = deviceID
        self.code = code
        self.label = label
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.profileCount = profileCount
        self.appVersion = appVersion
        self.mine = mine
        self.accountEmail = accountEmail
    }
}

/// The license's Macs, and when the next unlink is possible (`GET /v1/account/devices`).
public struct AccountDevices: Codable, Equatable, Sendable {
    public var devices: [AccountDevice]
    public var limit: Int?
    public var used: Int?
    public var unlinkAvailableAt: Date?
    public var unlinkCooldownSeconds: Int?
    public var offlineWorkSeconds: Int?

    public init(devices: [AccountDevice], limit: Int? = nil, used: Int? = nil, unlinkAvailableAt: Date? = nil,
                unlinkCooldownSeconds: Int? = nil, offlineWorkSeconds: Int? = nil) {
        self.devices = devices
        self.limit = limit
        self.used = used
        self.unlinkAvailableAt = unlinkAvailableAt
        self.unlinkCooldownSeconds = unlinkCooldownSeconds
        self.offlineWorkSeconds = offlineWorkSeconds
    }
}

/// A session after signing in with an email and a password (§5.2).
public struct AccountSession: Equatable, Sendable {
    public var token: ServerToken
    public var expiresAt: Date?
    public var accountID: String?
    public var idleTimeoutSeconds: Int?
}

/// An error answer of the server (§3): decided by `code` and the status, never by `message`.
public struct AccountServerError: Error, Equatable, Sendable {
    public var status: Int
    public var code: String
    public var field: String?
    /// Seconds (`rate_limited`), also from the `Retry-After` header.
    public var retryAfter: Int?
    /// When the next unlink is possible (`unlink_cooldown`).
    public var availableAt: Date?
    /// `device_limit_reached`: the license's Macs this account sees, and when an unlink is possible.
    public var devices: [AccountDevice]?
    public var unlinkAvailableAt: Date?
    public var unlinkCooldownSeconds: Int?
    public var offlineWorkSeconds: Int?

    public init(status: Int, code: String, field: String? = nil, retryAfter: Int? = nil, availableAt: Date? = nil,
                devices: [AccountDevice]? = nil, unlinkAvailableAt: Date? = nil, unlinkCooldownSeconds: Int? = nil,
                offlineWorkSeconds: Int? = nil) {
        self.status = status
        self.code = code
        self.field = field
        self.retryAfter = retryAfter
        self.availableAt = availableAt
        self.devices = devices
        self.unlinkAvailableAt = unlinkAvailableAt
        self.unlinkCooldownSeconds = unlinkCooldownSeconds
        self.offlineWorkSeconds = offlineWorkSeconds
    }
}

/// Why a request did not do what was asked.
public enum AccountFailure: Error, Equatable, Sendable {
    /// No answer of the server's: no network, TLS, a timeout, 5xx, 408, a body that is not the
    /// server's JSON (a captive portal's page) — `error.unreachable` (§3, §9.3).
    case unreachable
    /// An answer of the server's, with its code (§3).
    case server(AccountServerError)
    /// A 200 whose document did not pass the check (§6.1): an activation that did not happen.
    case document(EntitlementCheck)
}

/// The requests, and reading their answers.
public enum AccountAPI {
    /// `User-Agent: Lumen/<version> (<build>) macOS/<system>` and nothing more (§2).
    public static func userAgent(version: String, build: String, system: String) -> String {
        "Lumen/\(version) (\(build)) macOS/\(system)"
    }

    /// `<version> (<build>)`, at most 32 characters of `[0-9A-Za-z.+-_ ()]` (§6.1).
    public static func appVersion(version: String, build: String) -> String {
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+-_ ()")
        return String("\(version) (\(build))".filter { allowed.contains($0) }.prefix(32))
    }

    // MARK: Requests

    public static func login(email: String, password: String) -> AccountRequest {
        AccountRequest(method: .post, path: "/v1/auth/login", body: json(["email": email, "password": password]))
    }

    public static func logout(session: ServerToken) -> AccountRequest {
        AccountRequest(method: .post, path: "/v1/auth/logout", bearer: session)
    }

    /// What signs this Mac in to the license: the account's session (after the email and password),
    /// or the license's key (a purchase without registration — then without `Authorization`).
    public enum Credential: Sendable {
        case session(ServerToken)
        case key(AccountKey)
    }

    /// `POST /v1/devices/activate` (§6.1). `label`: only what the person typed — never the
    /// computer's name (§1); empty when they typed none.
    public static func activate(_ credential: Credential, machineID: String, label: String, profileCount: Int, appVersion: String) -> AccountRequest {
        var body: [String: Any] = ["machineID": machineID, "label": label, "profileCount": profileCount, "appVersion": appVersion]
        switch credential {
        case .session(let token):
            return AccountRequest(method: .post, path: "/v1/devices/activate", body: json(body), bearer: token)
        case .key(let key):
            body["key"] = key.unredacted()
            return AccountRequest(method: .post, path: "/v1/devices/activate", body: json(body))
        }
    }

    /// `POST /v1/device/entitlement` with the device's token (§6.2): no session needed.
    public static func refresh(deviceToken: ServerToken, machineID: String, profileCount: Int, appVersion: String) -> AccountRequest {
        AccountRequest(method: .post, path: "/v1/device/entitlement",
                       body: json(["machineID": machineID, "profileCount": profileCount, "appVersion": appVersion]), bearer: deviceToken)
    }

    /// `DELETE /v1/device` (§6.3): this Mac leaves the license; its place is free at once.
    public static func signOutDevice(deviceToken: ServerToken) -> AccountRequest {
        AccountRequest(method: .delete, path: "/v1/device", bearer: deviceToken)
    }

    /// The license's Macs: with the account's session, or — an account without an email — with its key.
    public static func devices(_ credential: Credential) -> AccountRequest {
        switch credential {
        case .session(let token):
            return AccountRequest(method: .get, path: "/v1/account/devices", bearer: token)
        case .key(let key):
            return AccountRequest(method: .post, path: "/v1/anonymous/license", body: json(["key": key.unredacted()]))
        }
    }

    /// Unlinks another Mac of the license (§10.6, §11).
    public static func unlink(deviceID: String, _ credential: Credential) -> AccountRequest {
        switch credential {
        case .session(let token):
            let id = deviceID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? deviceID
            return AccountRequest(method: .delete, path: "/v1/account/devices/\(id)", bearer: token)
        case .key(let key):
            return AccountRequest(method: .post, path: "/v1/anonymous/devices/unlink", body: json(["key": key.unredacted(), "deviceID": deviceID]))
        }
    }

    /// `GET /v1/account`: the account's email and the team's owner, for the account screen only —
    /// the rights come from the document alone (§11).
    public static func account(session: ServerToken) -> AccountRequest {
        AccountRequest(method: .get, path: "/v1/account", bearer: session)
    }

    // MARK: Answers

    /// The answer as the server's error, when it is one (§3); nil for a success.
    /// Throws `AccountFailure.unreachable` for what is not the server's answer at all.
    public static func failure(of response: AccountResponse) -> AccountFailure? {
        if (200..<300).contains(response.status) { return nil }
        // 5xx, 408: unreachable whatever they carry (§9.3).
        if response.status >= 500 || response.status == 408 { return .unreachable }
        guard let envelope = try? decoder.decode(ErrorEnvelope.self, from: response.body), !envelope.error.code.isEmpty else {
            return .unreachable
        }
        var error = envelope.error.serverError(status: response.status)
        if error.retryAfter == nil, let header = response.retryAfter, let seconds = Int(header.trimmingCharacters(in: .whitespaces)) {
            error.retryAfter = seconds
        }
        return .server(error)
    }

    /// The body of a success as `T`; `unreachable` when it is not (a captive portal answers 200 too).
    public static func decode<T: Decodable>(_ type: T.Type, from response: AccountResponse) -> Result<T, AccountFailure> {
        if let failure = failure(of: response) { return .failure(failure) }
        guard let value = try? decoder.decode(T.self, from: response.body) else { return .failure(.unreachable) }
        return .success(value)
    }

    /// `POST /v1/auth/login`'s answer.
    public static func session(from response: AccountResponse) -> Result<AccountSession, AccountFailure> {
        decode(SessionBody.self, from: response).map {
            AccountSession(token: ServerToken($0.sessionToken), expiresAt: $0.expiresAt, accountID: $0.accountID,
                           idleTimeoutSeconds: $0.idleTimeoutSeconds)
        }
    }

    /// An activation's or a refresh's answer: the document's JSON exactly as it came, and the server's
    /// time. The document is checked by the caller (`EntitlementVerifier`).
    public struct DocumentAnswer: Sendable {
        public var document: Data
        public var serverTime: Date
        public var device: AccountDevice?
        public var deviceToken: ServerToken?
    }

    public static func documentAnswer(from response: AccountResponse) -> Result<DocumentAnswer, AccountFailure> {
        if let failure = failure(of: response) { return .failure(failure) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let entitlement = object["entitlement"], JSONSerialization.isValidJSONObject(entitlement),
              let document = try? JSONSerialization.data(withJSONObject: entitlement),
              let serverTimeText = object["serverTime"] as? String,
              let serverTime = try? Date.ISO8601FormatStyle().parse(serverTimeText) else { return .failure(.unreachable) }
        var answer = DocumentAnswer(document: document, serverTime: serverTime)
        if let activation = try? decoder.decode(ActivationExtras.self, from: response.body) {
            answer.device = activation.device
            answer.deviceToken = activation.deviceToken.map(ServerToken.init)
        }
        return .success(answer)
    }

    /// The devices list, from either way of asking (`devices(_:)`): the session's list, or the key's
    /// license view with its Macs.
    public static func devices(from response: AccountResponse) -> Result<AccountDevices, AccountFailure> {
        decode(AccountDevices.self, from: response)
    }

    // MARK: Private

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private struct SessionBody: Decodable {
        var sessionToken: String
        var expiresAt: Date?
        var accountID: String?
        var idleTimeoutSeconds: Int?
    }

    private struct ActivationExtras: Decodable {
        var device: AccountDevice?
        var deviceToken: String?
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            var code: String
            var field: String?
            var retryAfter: Int?
            var availableAt: Date?
            var devices: [AccountDevice]?
            var unlinkAvailableAt: Date?
            var unlinkCooldownSeconds: Int?
            var offlineWorkSeconds: Int?

            enum CodingKeys: String, CodingKey {
                case code, field, retryAfter, availableAt, devices, unlinkAvailableAt, unlinkCooldownSeconds, offlineWorkSeconds
            }

            /// The code is the answer; what comes with it is read field by field.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                code = try container.decode(String.self, forKey: .code)
                field = try? container.decode(String.self, forKey: .field)
                retryAfter = try? container.decode(Int.self, forKey: .retryAfter)
                availableAt = try? container.decode(Date.self, forKey: .availableAt)
                devices = try? container.decode([AccountDevice].self, forKey: .devices)
                unlinkAvailableAt = try? container.decode(Date.self, forKey: .unlinkAvailableAt)
                unlinkCooldownSeconds = try? container.decode(Int.self, forKey: .unlinkCooldownSeconds)
                offlineWorkSeconds = try? container.decode(Int.self, forKey: .offlineWorkSeconds)
            }

            func serverError(status: Int) -> AccountServerError {
                AccountServerError(status: status, code: code, field: field, retryAfter: retryAfter, availableAt: availableAt,
                                   devices: devices, unlinkAvailableAt: unlinkAvailableAt, unlinkCooldownSeconds: unlinkCooldownSeconds,
                                   offlineWorkSeconds: offlineWorkSeconds)
            }
        }

        var error: Body
    }
}
