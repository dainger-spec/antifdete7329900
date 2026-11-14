import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the sync server API in docs/SYNC_SERVER_API.md: a server of the person's own (an
/// address and a token typed in), or the Lumen account's (`AccountSync`: the account server with this
/// Mac's device token). It is tested against in-process stubs that implement the documented semantics
/// (`HTTPSyncTransportTests`, `ServerGenerationTests`); no server is included in this project.
///
/// The server stores opaque blobs per `(vaultID, objectID)` with a revision counter and
/// compare-and-swap writes. Everything it receives is already end-to-end encrypted by
/// `SyncCodec`, except the `vault-header` object (see SyncEngine).
///
/// The server's generation of the vault (`X-Lumen-Server-Generation`, the Lumen server's CONTRACT
/// §16.2): read from each list, sent with every write of the run, and taken from a write the server
/// accepted (a write that made the vault gets its new one). A server that never names one is spoken
/// to as before: no header is sent. A refusal whose body names its code (`{"error": {"code": …}}`)
/// is thrown as `SyncServerRefusal`, with `availableAt` and `retryAfter` when it carries them.
///
/// Transport security: HTTPS is required (App Transport Security also enforces it for the
/// app's own URLSession traffic). `allowInsecureLocalhost` permits `http://localhost` /
/// `http://127.0.0.1` for development servers only.
public final class HTTPSyncTransport: ServerGenerationTransport, @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var baseURL: URL
        public var vaultID: UUID
        /// Sent as `Authorization: Bearer <token>`. Account management is out of scope.
        public var bearerToken: String?
        public var allowInsecureLocalhost: Bool

        public init(baseURL: URL, vaultID: UUID, bearerToken: String? = nil, allowInsecureLocalhost: Bool = false) {
            self.baseURL = baseURL
            self.vaultID = vaultID
            self.bearerToken = bearerToken
            self.allowInsecureLocalhost = allowInsecureLocalhost
        }
    }

    public static let revisionHeader = "X-PB-Revision"
    /// The Lumen server's generation of the vault's data (its CONTRACT §16.2).
    public static let generationHeader = "X-Lumen-Server-Generation"

    private let configuration: Configuration
    private let session: URLSession
    private let lock = NSLock()
    private var generation: String?

    /// The server's address and the vault: a generation is this pair's alone.
    public var generationScope: String {
        "\(configuration.baseURL.absoluteString)|\(configuration.vaultID.uuidString.lowercased())"
    }

    /// As the last list said it, or a write the server accepted since; nil when it said none.
    public var serverGeneration: String? { lock.withLock { generation } }

    public init(configuration: Configuration, session: URLSession = .shared) throws {
        try Self.validate(configuration.baseURL, allowInsecureLocalhost: configuration.allowInsecureLocalhost)
        self.configuration = configuration
        self.session = session
    }

    public static func validate(_ url: URL, allowInsecureLocalhost: Bool = false) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            throw CoreError.invalidConfiguration("sync server URL must be absolute")
        }
        let localhost = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && allowInsecureLocalhost && localhost) else {
            throw CoreError.invalidConfiguration("sync server URL must use https")
        }
        guard url.query == nil, url.fragment == nil, url.user == nil else {
            throw CoreError.invalidConfiguration("sync server URL must not contain query, fragment or credentials")
        }
    }

    // MARK: SyncTransport

    private struct ListResponse: Decodable {
        struct Object: Decodable {
            var id: String
            var revision: Int
        }
        var objects: [Object]
    }

    public func listObjects() async throws -> [RemoteObjectInfo] {
        let (data, response) = try await send(request(path: "objects", method: "GET"))
        try Self.expect(response, data, [200])
        let objects: [RemoteObjectInfo]
        do {
            objects = try JSONDecoder().decode(ListResponse.self, from: data).objects
                .filter { SyncObjectID.isValid($0.id) }
                .map { RemoteObjectInfo(objectID: $0.id, revision: $0.revision) }
        } catch {
            throw CoreError.corruptData("sync server list response")
        }
        // The run's generation is the list's, or none at all when the list names none (§16.2, 2):
        // a server that keeps no generations is written to without the header, as before.
        let listed = Self.generationValue(in: response)
        lock.withLock { generation = listed }
        return objects
    }

    public func fetch(objectID: String) async throws -> Data? {
        let (data, response) = try await send(request(path: "objects/\(try Self.checked(objectID))", method: "GET"))
        if response.statusCode == 404 { return nil }
        try Self.expect(response, data, [200])
        return data
    }

    public func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws {
        var request = try request(path: "objects/\(try Self.checked(objectID))", method: "PUT")
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(revision), forHTTPHeaderField: Self.revisionHeader)
        if let expectedRevision {
            request.setValue("\"\(expectedRevision)\"", forHTTPHeaderField: "If-Match")
        } else {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        // Every write of the run names the generation it works with — `none` too: "no vault there,
        // this write makes it" (§16.2, 6). Another one there: `409 generation_changed`, nothing written.
        if let generation = serverGeneration {
            request.setValue(generation, forHTTPHeaderField: Self.generationHeader)
        }
        let (body, response) = try await send(request)
        if response.statusCode == 412 {
            throw CoreError.syncConflict(objectID: objectID, remoteRevision: Self.revision(fromETag: response) ?? 0)
        }
        try Self.expect(response, body, [200, 201, 204])
        // Accepted: the vault's generation from here on (a write that made the vault names its new
        // one). Never taken from a refusal: the run stops on a 409, and its records stay those of the
        // generation it began with.
        if let accepted = Self.generationValue(in: response) {
            lock.withLock { generation = accepted }
        }
    }

    // MARK: HTTP

    private func request(path: String, method: String) throws -> URLRequest {
        let url = configuration.baseURL
            .appendingPathComponent("v1/vaults/\(configuration.vaultID.uuidString.lowercased())/\(path)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = configuration.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: CoreError.io("sync request failed: \(error.localizedDescription)"))
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: CoreError.io("sync request returned no HTTP response"))
                }
            }.resume()
        }
    }

    private static func expect(_ response: HTTPURLResponse, _ body: Data, _ accepted: Set<Int>) throws {
        guard accepted.contains(response.statusCode) else {
            if let refusal = refusal(response, body) { throw refusal }
            let message = String(data: body.prefix(200), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CoreError.syncServer(status: response.statusCode, message: message)
        }
    }

    /// The server's refusal by its code, when the body names one (`{"error": {"code": …}}`); nil for
    /// any other body. What comes with the code is read field by field: one that does not read is
    /// left out.
    static func refusal(_ response: HTTPURLResponse, _ body: Data) -> SyncServerRefusal? {
        guard let envelope = try? AccountAPI.decoder.decode(RefusalEnvelope.self, from: body), !envelope.error.code.isEmpty else {
            return nil
        }
        var retryAfter = envelope.error.retryAfter
        if retryAfter == nil, let header = response.value(forHTTPHeaderField: "Retry-After") {
            retryAfter = Int(header.trimmingCharacters(in: .whitespaces))
        }
        return SyncServerRefusal(status: response.statusCode, code: envelope.error.code,
                                 availableAt: envelope.error.availableAt, retryAfter: retryAfter)
    }

    private struct RefusalEnvelope: Decodable {
        struct Body: Decodable {
            var code: String
            var availableAt: Date?
            var retryAfter: Int?

            enum CodingKeys: String, CodingKey { case code, availableAt, retryAfter }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                code = try container.decode(String.self, forKey: .code)
                availableAt = try? container.decode(Date.self, forKey: .availableAt)
                retryAfter = try? container.decode(Int.self, forKey: .retryAfter)
            }
        }

        var error: Body
    }

    /// `X-Lumen-Server-Generation` of an answer, nil when it has none (an empty one is none).
    static func generationValue(in response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: generationHeader)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        return value
    }

    private static func checked(_ objectID: String) throws -> String {
        guard SyncObjectID.isValid(objectID) else { throw CoreError.corruptData("invalid object ID") }
        return objectID
    }

    /// `ETag: "7"` → 7
    static func revision(fromETag response: HTTPURLResponse) -> Int? {
        guard let etag = response.value(forHTTPHeaderField: "ETag") else { return nil }
        return Int(etag.trimmingCharacters(in: CharacterSet(charactersIn: "\"W/ ")))
    }
}
