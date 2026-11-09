import Foundation
import LumenCore
import UIKit

/// The app's requests to the Lumen account server (its docs/CONTRACT.md §2): JSON over https, an
/// ephemeral session — no cookies, no cache — and nothing sent but what the contract names.
enum AccountClient {
    /// The account server. A DEBUG build's test points it at its stand-in (LUMEN_TEST_ACCOUNT_SERVER).
    static var server: URL {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["LUMEN_TEST_ACCOUNT_SERVER"], let url = URL(string: value) { return url }
        #endif
        let value = Bundle.main.object(forInfoDictionaryKey: "PBAccountServerURL") as? String
        return value.flatMap(URL.init(string:)) ?? URL(string: "https://api.lumenbrowser.io")!
    }

    /// The site: plans, a forgotten password, the robot check. A test points it at its testbed.
    static var site: URL {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["LUMEN_TEST_SITE_URL"], let url = URL(string: value) { return url }
        #endif
        let value = Bundle.main.object(forInfoDictionaryKey: "PBAccountSiteURL") as? String
        return value.flatMap(URL.init(string:)) ?? URL(string: "https://lumenbrowser.io")!
    }

    /// The keys documents of rights are trusted by: the app's own (`PBEntitlementPublicKeys` in its
    /// Info.plist). A DEBUG build's test adds its stand-in's (LUMEN_TEST_ENTITLEMENT_KEYS, "id:base64").
    static let keys: [String: Data] = {
        var keys = EntitlementKeys.from(Bundle.main.object(forInfoDictionaryKey: "PBEntitlementPublicKeys"))
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["LUMEN_TEST_ENTITLEMENT_KEYS"] {
            var named: [String: String] = [:]
            for entry in value.split(separator: ",") {
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { named[parts[0]] = parts[1] }
            }
            keys.merge(EntitlementKeys.from(named)) { _, new in new }
        }
        #endif
        return keys
    }()

    /// "<CFBundleShortVersionString> (<CFBundleVersion>)", as the activation sends it (§6.1).
    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Lumen/\(appVersion) iOS/\(UIDevice.current.systemVersion)"]
        return URLSession(configuration: configuration)
    }()

    /// One request. Nil: no answer at all (no network, a timeout) — "unreachable" (§9.3). What came
    /// back is judged by the caller: a body that is not the server's JSON is "unreachable" too.
    static func send(_ method: String, _ path: String, body: Data?, token: String?) async -> (status: Int, data: Data)? {
        var request = URLRequest(url: server.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    /// A JSON object of an answer; nil when the body is not one.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
