import BrowserCore
import Foundation
import IOKit
import os

/// Where the account server is and which keys sign its documents (the server's `docs/CONTRACT.md`
/// §2, §7.2).
///
/// A build made to be released carries them in its `Info.plist` — `PBAccountServerURL` (https),
/// `PBAccountSiteURL`, `PBEntitlementPublicKeys` (`scripts/build-app.sh`, from `scripts/release.sh`) —
/// and then nothing in the environment changes them: the license is that build's, as made. A
/// development build carries none; the self-test gives it a server and keys of its own through the
/// environment (`PB_ACCOUNT_SERVER_URL`, `PB_ENTITLEMENT_PUBLIC_KEYS`), and without them it has no
/// licensing at all — its profiles open as before, and Settings → Account says the build has no
/// account server. `--release-check` refuses a build to be released that has no server, no keys, or
/// the development server's key (`ReleaseCheck`).
struct AccountConfiguration: Sendable {
    enum Source: String, Sendable {
        /// The build's own `Info.plist`.
        case build
        /// This process's environment, in a development build only.
        case environment
    }

    let serverURL: URL
    let siteURL: URL
    let keys: [String: Data]
    let source: Source

    /// The build's, or the environment's in a development build; nil in a profile's own process —
    /// it never talks to the account server (§2) — and where neither names a server.
    static let main: AccountConfiguration? = resolve(info: Bundle.main.infoDictionary ?? [:],
                                                     environment: ProcessInfo.processInfo.environment,
                                                     arguments: CommandLine.arguments)

    static func resolve(info: [String: Any], environment: [String: String], arguments: [String]) -> AccountConfiguration? {
        guard !arguments.contains("--profile-session") else { return nil }
        if let server = info["PBAccountServerURL"] as? String, !server.isEmpty {
            // A build made with a server: only its own values, whatever the environment says.
            guard let serverURL = URL(string: server), serverURL.scheme == "https" else { return nil }
            let site = (info["PBAccountSiteURL"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://lumenbrowser.io")!
            return AccountConfiguration(serverURL: serverURL, siteURL: site,
                                        keys: EntitlementKeys.fromInfoPlist(info["PBEntitlementPublicKeys"]), source: .build)
        }
        guard let server = environment["PB_ACCOUNT_SERVER_URL"], let serverURL = URL(string: server),
              serverURL.scheme == "https" || serverURL.host == "127.0.0.1" || serverURL.host == "localhost" else { return nil }
        let site = environment["PB_ACCOUNT_SITE_URL"].flatMap(URL.init(string:)) ?? serverURL
        var keys: [String: String] = [:]
        for entry in (environment["PB_ENTITLEMENT_PUBLIC_KEYS"] ?? "").split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { keys[parts[0]] = parts[1] }
        }
        return AccountConfiguration(serverURL: serverURL, siteURL: site, keys: EntitlementKeys.fromInfoPlist(keys), source: .environment)
    }

    /// The site's page at `path` (`/pricing`, `/account`, `/reset-password`, §11).
    func site(_ path: String) -> URL {
        siteURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

/// The account server over HTTPS (§2): an ephemeral session — no cookies, no cache — from the app's
/// own process only; JSON bodies; the token in `Authorization`; `User-Agent` with the versions and
/// nothing more; 10 seconds to connect, 30 for the whole request.
final class AccountHTTP: AccountTransport, @unchecked Sendable {
    private let base: URL
    private let session: URLSession
    private let userAgent: String

    init(base: URL) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        let info = Bundle.main.infoDictionary ?? [:]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        userAgent = AccountAPI.userAgent(version: info["CFBundleShortVersionString"] as? String ?? "0",
                                         build: info["CFBundleVersion"] as? String ?? "0",
                                         system: "\(system.majorVersion).\(system.minorVersion)")
    }

    func send(_ request: AccountRequest) async throws -> AccountResponse {
        // A profile's own process never talks to the account server (§2).
        guard !CommandLine.arguments.contains("--profile-session") else { throw URLError(.cancelled) }
        guard let url = URL(string: request.path, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
        var http = URLRequest(url: url)
        http.httpMethod = request.method.rawValue
        http.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = request.body {
            http.httpBody = body
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer = request.bearer {
            http.setValue("Bearer " + bearer.unredacted(), forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: http)
        guard let answer = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return AccountResponse(status: answer.statusCode, body: data, retryAfter: answer.value(forHTTPHeaderField: "Retry-After"))
    }
}

/// This Mac's hardware UUID (`IOPlatformUUID`), from which its id for the server is computed
/// (`MachineID`, §4.1). The UUID itself is never sent, stored or logged.
enum MachineIdentity {
    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return value as? String
    }

    /// Computed each time it is needed, never stored as the truth (§4.1).
    static var machineID: String? {
        platformUUID().map(MachineID.compute(platformUUID:))
    }
}
