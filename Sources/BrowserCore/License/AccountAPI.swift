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
    /// Only in the key's view of its license (`POST /v1/anonymous/license`, §11.1): an email is linked
    /// to the purchase. The address itself is not shown to whoever holds the key.
    public var emailLinked: Bool?

    public init(devices: [AccountDevice], limit: Int? = nil, used: Int? = nil, unlinkAvailableAt: Date? = nil,
                unlinkCooldownSeconds: Int? = nil, offlineWorkSeconds: Int? = nil, emailLinked: Bool? = nil) {
        self.devices = devices
        self.limit = limit
        self.used = used
        self.unlinkAvailableAt = unlinkAvailableAt
        self.unlinkCooldownSeconds = unlinkCooldownSeconds
        self.offlineWorkSeconds = offlineWorkSeconds
        self.emailLinked = emailLinked
    }
}

/// A session after signing in with an email and a password (§5.2).
public struct AccountSession: Equatable, Sendable {
    public var token: ServerToken
    public var expiresAt: Date?
    public var accountID: String?
    public var idleTimeoutSeconds: Int?
}

/// A sign-in the server holds until the code from the letter it sent to the account's address
/// (`202 check_email`, §5.2): the password was right, but the address had many failed attempts
/// before it, or the account five wrong passwords in a row since its last sign-in.
public struct LoginCode: Equatable, Sendable {
    /// Lets whoever typed the right password have the same code sent again
    /// (`POST /v1/auth/login/resend`). Nil from a server older than v2026.11.04, which has no such
    /// thing. In memory only, for the code's screen: never written, never logged (`ServerToken`).
    public var challenge: ServerToken?
    /// How many times this code may still be typed.
    public var codeAttempts: Int?
    /// When the letter went out, and until when its code works. An older server sends neither: they
    /// are counted from when its answer came, and its `codeValidSeconds`.
    public var codeSentAt: Date?
    public var codeExpiresAt: Date?
    /// Not before then may the code be sent again; nil when it may not be sent again at all.
    public var resendAvailableAt: Date?
    /// How many more times it may be sent in this attempt.
    public var resendsLeft: Int?

    public init(challenge: ServerToken? = nil, codeAttempts: Int? = nil, codeSentAt: Date? = nil, codeExpiresAt: Date? = nil,
                resendAvailableAt: Date? = nil, resendsLeft: Int? = nil) {
        self.challenge = challenge
        self.codeAttempts = codeAttempts
        self.codeSentAt = codeSentAt
        self.codeExpiresAt = codeExpiresAt
        self.resendAvailableAt = resendAvailableAt
        self.resendsLeft = resendsLeft
    }

    /// The code may be sent again in this attempt — now, or from `resendAvailableAt` on.
    public var canResend: Bool { challenge != nil && (resendsLeft ?? 0) > 0 && resendAvailableAt != nil }
    /// This attempt has a challenge, and every resend of it is spent (`login.resends_used`).
    public var resendsUsed: Bool { challenge != nil && !canResend }
}

/// What the password gave (§5.2): a session, or a letter with a code to type first.
public enum LoginAnswer: Equatable, Sendable {
    case session(AccountSession)
    case code(LoginCode)
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

    /// `POST /v1/auth/login` (§5.2). `robotToken`: the robot check's (§5.5), only after the server
    /// asked for one (`403 robot_check`); good for one request.
    public static func login(email: String, password: String, robotToken: String? = nil) -> AccountRequest {
        var body: [String: Any] = ["email": email, "password": password]
        if let robotToken { body["robotToken"] = robotToken }
        return AccountRequest(method: .post, path: "/v1/auth/login", body: json(body))
    }

    /// `POST /v1/auth/login/confirm`: the code from the letter → a session (§5.2).
    public static func confirmLogin(email: String, code: String) -> AccountRequest {
        AccountRequest(method: .post, path: "/v1/auth/login/confirm", body: json(["email": email, "code": code]))
    }

    /// `POST /v1/auth/login/resend`: the same code once more, asked with the challenge the password's
    /// answer gave — so only whoever typed the right password can have a letter sent (§5.2).
    public static func resendLoginCode(_ challenge: ServerToken) -> AccountRequest {
        AccountRequest(method: .post, path: "/v1/auth/login/resend", body: json(["challenge": challenge.unredacted()]))
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

    /// `POST /v1/devices/activate` (§6.1). `label`: what the person left in the field, which shows
    /// this Mac's name to begin with (the owner, 3 November: by default the Mac's name from the
    /// system); empty when they cleared it.
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

    /// `POST /v1/device/entitlement` with the device's token (§6.2): no session needed. `label`: this
    /// Mac's label — the one it was connected with, or this Mac's name — sent with each renewal
    /// (the owner, 3 November); nil leaves it out (a server that refused it, `LicenseClient`).
    public static func refresh(deviceToken: ServerToken, machineID: String, profileCount: Int, appVersion: String,
                               label: String? = nil) -> AccountRequest {
        var body: [String: Any] = ["machineID": machineID, "profileCount": profileCount, "appVersion": appVersion]
        if let label { body["label"] = label }
        // BROKEN ON PURPOSE (measurement branch): the renewal goes to an address the server does not have.
        return AccountRequest(method: .post, path: "/v1/device/entitlement-broken", body: json(body), bearer: deviceToken)
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

    // MARK: A purchase without registration: an email, a new key (§11.1; the site's SITE_API §12.9–§12.10)

    /// `POST /v1/anonymous/email`: an email and a password to link to the purchase, proved with the key
    /// and the purchase code — the key alone is not enough. The server answers `202 check_email` the
    /// same way for every address; a six-digit code goes to an address that has no account.
    public static func linkEmail(key: AccountKey, purchaseCode: PurchaseCode, email: String, password: String, locale: String?) -> AccountRequest {
        var body: [String: Any] = ["key": key.unredacted(), "purchaseCode": purchaseCode.unredacted(), "email": email, "password": password]
        if let locale { body["locale"] = locale }
        return AccountRequest(method: .post, path: "/v1/anonymous/email", body: json(body))
    }

    /// `POST /v1/anonymous/email/confirm`: the code from the letter, with the same key and address →
    /// a session, the email linked.
    public static func confirmEmail(key: AccountKey, email: String, code: String) -> AccountRequest {
        AccountRequest(method: .post, path: "/v1/anonymous/email/confirm", body: json(["key": key.unredacted(), "email": email, "code": code]))
    }

    /// How a key's replacement is proved (§11.1): the key and the purchase code, or — an email linked —
    /// the account's session and its password.
    public enum KeyReplacementProof: Sendable {
        case purchase(AccountKey, PurchaseCode)
        case account(session: ServerToken, password: String)
    }

    /// `POST /v1/anonymous/key/replace` or `POST /v1/account/key/replace` → `{"key"}`: a new key; the
    /// old one stops working at once and every Mac of the license is unlinked.
    public static func replaceKey(_ proof: KeyReplacementProof) -> AccountRequest {
        switch proof {
        case let .purchase(key, code):
            return AccountRequest(method: .post, path: "/v1/anonymous/key/replace",
                                  body: json(["key": key.unredacted(), "purchaseCode": code.unredacted()]))
        case let .account(session, password):
            return AccountRequest(method: .post, path: "/v1/account/key/replace", body: json(["password": password]), bearer: session)
        }
    }

    /// `GET /v1/plans`, without authorization: for "Lost your key?" — how long after a payment the key
    /// can be fetched again with the invoice's number and the purchase code (`keyRetrievalSeconds`).
    public static func plans() -> AccountRequest {
        AccountRequest(method: .get, path: "/v1/plans")
    }

    // MARK: Answers

    /// The answer as the server's error, when it is one (§3); nil for a success.
    /// Throws `AccountFailure.unreachable` for what is not the server's answer at all.
    public static func failure(of response: AccountResponse) -> AccountFailure? {
        if (200..<300).contains(response.status) { return nil }
        let envelope = try? decoder.decode(ErrorEnvelope.self, from: response.body)
        // 5xx, 408: unreachable whatever they carry (§9.3) — but for the two 503s a sign-in says in
        // words, with when to try again (§3): the queue to check a password is full, the robot
        // check's service did not answer. A refresh still takes them as unreachable (`LicenseClient`).
        if response.status >= 500 || response.status == 408 {
            guard response.status == 503, let code = envelope?.error.code, busyCodes.contains(code) else { return .unreachable }
        }
        guard let envelope, !envelope.error.code.isEmpty else {
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

    /// The 503 codes that are the server's answer, not its absence (§3).
    static let busyCodes: Set<String> = ["server_busy", "robot_check_unavailable"]

    /// A session's answer: `POST /v1/auth/login/confirm`, `…/email/confirm`.
    public static func session(from response: AccountResponse) -> Result<AccountSession, AccountFailure> {
        decode(SessionBody.self, from: response).map {
            AccountSession(token: ServerToken($0.sessionToken), expiresAt: $0.expiresAt, accountID: $0.accountID,
                           idleTimeoutSeconds: $0.idleTimeoutSeconds)
        }
    }

    /// `POST /v1/auth/login`'s answer: a session (200), or a code to type first (202, §5.2).
    /// `receivedAt`: when it came — for the times an older server does not send.
    public static func loginAnswer(from response: AccountResponse, receivedAt: Date) -> Result<LoginAnswer, AccountFailure> {
        if response.status == 202 { return loginCode(from: response, receivedAt: receivedAt).map(LoginAnswer.code) }
        return session(from: response).map(LoginAnswer.session)
    }

    /// A sign-in's `202 check_email` — the password's, or a resend's, which is "of the same kind".
    /// `keeping`: a resend's attempt, whose challenge stays when its answer does not repeat it.
    public static func loginCode(from response: AccountResponse, receivedAt: Date,
                                 keeping kept: ServerToken? = nil) -> Result<LoginCode, AccountFailure> {
        decode(LoginCodeBody.self, from: response).flatMap { body -> Result<LoginCode, AccountFailure> in
            guard response.status == 202, body.status == "check_email" else { return .failure(.unreachable) }
            let sentAt = body.codeSentAt ?? receivedAt
            let expiresAt = body.codeExpiresAt ?? body.codeValidSeconds.map { sentAt.addingTimeInterval(TimeInterval($0)) }
            let challenge = body.challenge.flatMap { $0.isEmpty ? nil : ServerToken($0) } ?? kept
            return .success(LoginCode(challenge: challenge, codeAttempts: body.codeAttempts, codeSentAt: sentAt, codeExpiresAt: expiresAt,
                                      resendAvailableAt: challenge == nil ? nil : body.resendAvailableAt,
                                      resendsLeft: challenge == nil ? nil : body.resendsLeft))
        }
    }

    /// An activation's or a refresh's answer: the document's JSON exactly as it came, and the server's
    /// time. The document is checked by the caller (`EntitlementVerifier`).
    public struct DocumentAnswer: Sendable {
        public var document: Data
        public var serverTime: Date
        public var device: AccountDevice?
        public var deviceToken: ServerToken?
        /// The license's unlink cooldown (§6.3), for `signout.consequences`; nil from a server older
        /// than v2026.11.04, whose sign-out has none.
        public var unlinkCooldownSeconds: Int?
    }

    public static func documentAnswer(from response: AccountResponse) -> Result<DocumentAnswer, AccountFailure> {
        if let failure = failure(of: response) { return .failure(failure) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let entitlement = object["entitlement"], JSONSerialization.isValidJSONObject(entitlement),
              let document = try? JSONSerialization.data(withJSONObject: entitlement),
              let serverTimeText = object["serverTime"] as? String,
              let serverTime = try? Date.ISO8601FormatStyle().parse(serverTimeText) else { return .failure(.unreachable) }
        var answer = DocumentAnswer(document: document, serverTime: serverTime)
        // Read on its own: a field that does not read leaves the cooldown unknown, not the answer.
        if let cooldown = (try? decoder.decode(CooldownExtra.self, from: response.body))?.unlinkCooldownSeconds, cooldown >= 0 {
            answer.unlinkCooldownSeconds = cooldown
        }
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

    /// A letter with a code went out (`202 {"status": "check_email", "codeValidSeconds", "codeAttempts"}`).
    public struct CodeSent: Equatable, Sendable {
        public var codeValidSeconds: Int?
        public var codeAttempts: Int?

        public init(codeValidSeconds: Int?, codeAttempts: Int?) {
            self.codeValidSeconds = codeValidSeconds
            self.codeAttempts = codeAttempts
        }
    }

    public static func codeSent(from response: AccountResponse) -> Result<CodeSent, AccountFailure> {
        decode(CodeSentBody.self, from: response).flatMap { body -> Result<CodeSent, AccountFailure> in
            guard body.status == "check_email" else { return .failure(.unreachable) }
            return .success(CodeSent(codeValidSeconds: body.codeValidSeconds, codeAttempts: body.codeAttempts))
        }
    }

    /// A replacement's answer: the new key, read as any key is (§18). One that does not read is not
    /// the server's answer.
    public static func newKey(from response: AccountResponse) -> Result<AccountKey, AccountFailure> {
        decode(NewKeyBody.self, from: response).flatMap { body -> Result<AccountKey, AccountFailure> in
            guard let key = AccountKey(typed: body.key) else { return .failure(.unreachable) }
            return .success(key)
        }
    }

    /// `GET /v1/plans`' `withoutRegistration.keyRetrievalSeconds`.
    public static func keyRetrievalSeconds(from response: AccountResponse) -> Result<Int, AccountFailure> {
        decode(PlansBody.self, from: response).flatMap { body -> Result<Int, AccountFailure> in
            guard let seconds = body.withoutRegistration?.keyRetrievalSeconds else { return .failure(.unreachable) }
            return .success(seconds)
        }
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

    private struct CodeSentBody: Decodable {
        var status: String
        var codeValidSeconds: Int?
        var codeAttempts: Int?
    }

    private struct CooldownExtra: Decodable {
        var unlinkCooldownSeconds: Int?
    }

    /// A sign-in's `202` (§5.2), read field by field: `status` is the answer; a time or a number that
    /// does not read is left out — an older server sends none of them.
    private struct LoginCodeBody: Decodable {
        var status: String
        var codeValidSeconds: Int?
        var codeAttempts: Int?
        var challenge: String?
        var codeExpiresAt: Date?
        var codeSentAt: Date?
        var resendAvailableAt: Date?
        var resendsLeft: Int?

        enum CodingKeys: String, CodingKey {
            case status, codeValidSeconds, codeAttempts, challenge, codeExpiresAt, codeSentAt, resendAvailableAt, resendsLeft
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            codeValidSeconds = try? container.decode(Int.self, forKey: .codeValidSeconds)
            codeAttempts = try? container.decode(Int.self, forKey: .codeAttempts)
            challenge = try? container.decode(String.self, forKey: .challenge)
            codeExpiresAt = try? container.decode(Date.self, forKey: .codeExpiresAt)
            codeSentAt = try? container.decode(Date.self, forKey: .codeSentAt)
            resendAvailableAt = try? container.decode(Date.self, forKey: .resendAvailableAt)
            resendsLeft = try? container.decode(Int.self, forKey: .resendsLeft)
        }
    }

    private struct NewKeyBody: Decodable {
        var key: String
    }

    private struct PlansBody: Decodable {
        struct WithoutRegistration: Decodable {
            var keyRetrievalSeconds: Int?
        }

        var withoutRegistration: WithoutRegistration?
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
