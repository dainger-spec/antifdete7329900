import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the sync server API in docs/SYNC_SERVER_API.md.
///
/// STATUS: server-ready client. It is tested against an in-process stub that implements the
/// documented semantics (`HTTPSyncTransportTests`); no server is included in this project.
///
/// The server stores opaque blobs per `(vaultID, objectID)` with a revision counter and
/// compare-and-swap writes. Everything it receives is already end-to-end encrypted by
/// `SyncCodec`, except the `vault-header` object (see SyncEngine).
///
/// Transport security: HTTPS is required (App Transport Security also enforces it for the
/// app's own URLSession traffic). `allowInsecureLocalhost` permits `http://localhost` /
/// `http://127.0.0.1` for development servers only.
public final class HTTPSyncTransport: SyncTransport, @unchecked Sendable {
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

    private let configuration: Configuration
    private let session: URLSession

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
        do {
            return try JSONDecoder().decode(ListResponse.self, from: data).objects
                .filter { SyncObjectID.isValid($0.id) }
                .map { RemoteObjectInfo(objectID: $0.id, revision: $0.revision) }
        } catch {
            throw CoreError.corruptData("sync server list response")
        }
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
        let (body, response) = try await send(request)
        if response.statusCode == 412 {
            throw CoreError.syncConflict(objectID: objectID, remoteRevision: Self.revision(fromETag: response) ?? 0)
        }
        try Self.expect(response, body, [200, 201, 204])
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
            let message = String(data: body.prefix(200), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CoreError.syncServer(status: response.statusCode, message: message)
        }
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
