import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asks an OCI registry for a tag's current digest, so the app can tell whether
/// a newer base image has been published without downloading it. The digest is
/// compared against the one recorded when the image was last pulled
/// (SetupStatus.baseImageDigest).
///
/// Only a read of the registry — no download. Best-effort: any failure (no
/// network, auth, private image) returns nil and the UI shows "unknown".
public enum RegistryClient {
    /// Accept both OCI and Docker manifest/index media types.
    static let manifestAccept = [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ].joined(separator: ", ")

    private struct TokenResponse: Decodable {
        let token: String?
        let access_token: String?  // swiftlint:disable:this identifier_name
    }

    /// Pull the bearer token out of a registry /token response.
    static func parseToken(_ data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else { return nil }
        return decoded.token ?? decoded.access_token
    }

    /// The tag's digest (e.g. "sha256:…"), or nil if it can't be determined.
    public static func remoteDigest(for reference: OCIReference, timeout: TimeInterval = 20) async -> String? {
        var token: String?
        if let tokenURL = reference.tokenURL, let data = await get(tokenURL, timeout: timeout)?.0 {
            token = parseToken(data)
        }
        guard let manifestURL = reference.manifestURL else { return nil }
        var request = URLRequest(url: manifestURL, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.setValue(manifestAccept, forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let response = await send(request)?.1 as? HTTPURLResponse else { return nil }
        return response.value(forHTTPHeaderField: "Docker-Content-Digest")
    }

    // Completion-handler dataTask bridged to async — portable across macOS and
    // the Linux toolchain without relying on a particular async-URLSession API.
    private static func get(_ url: URL, timeout: TimeInterval) async -> (Data, URLResponse)? {
        await send(URLRequest(url: url, timeoutInterval: timeout))
    }

    private static func send(_ request: URLRequest) async -> (Data, URLResponse)? {
        await withCheckedContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            task.resume()
        }
    }
}
