import BrowserCore
import Foundation
import Network

/// What the sidebar and the browser toolbar show about a profile's proxy.
enum ProxyStatus: Equatable {
    /// The profile has no proxy: it uses this Mac's normal network connection.
    case direct
    /// A proxy is set but nothing has been tried through it yet.
    case unchecked
    case checking
    /// The last check or page load through the proxy worked.
    case working(milliseconds: Int?)
    /// The last check or page load failed because of the proxy.
    case failed(UserFacingMessage)

    var symbol: String {
        switch self {
        case .direct: return "network"
        case .unchecked: return "questionmark.circle"
        case .checking: return "arrow.triangle.2.circlepath"
        case .working: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var labelKey: String {
        switch self {
        case .direct: return "proxy.status.direct"
        case .unchecked: return "proxy.status.unchecked"
        case .checking: return "proxy.status.checking"
        case .working: return "proxy.status.working"
        case .failed: return "proxy.status.failed"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Per-profile proxy status for the whole app. Updated by explicit checks (editor, profile page,
/// toolbar) and by page loads in running profiles: with failover disabled, a load that fails at
/// the connection level means the proxy (the first hop) failed, and any page that loads proves
/// it works.
@MainActor
final class ProxyStatusCenter: ObservableObject {
    @Published private(set) var statuses: [UUID: ProxyStatus] = [:]

    func status(for id: UUID, hasProxy: Bool) -> ProxyStatus {
        hasProxy ? statuses[id] ?? .unchecked : .direct
    }

    func set(_ status: ProxyStatus, for id: UUID) {
        if statuses[id] != status { statuses[id] = status }
    }

    func forget(_ id: UUID) {
        statuses[id] = nil
    }

    /// A page of a profile with a proxy finished loading.
    func reportLoadSucceeded(_ id: UUID) {
        switch statuses[id] {
        case .working, .checking: return
        default: set(.working(milliseconds: nil), for: id)
        }
    }

    /// A page load failed; only proxy-kind failures change the status.
    func reportLoadFailed(_ id: UUID, message: UserFacingMessage) {
        guard message.kind == .proxy else { return }
        set(.failed(message), for: id)
    }

    /// Connects to a test page through the proxy and records the outcome.
    @discardableResult
    func check(_ id: UUID, settings: ProxySettings) async -> ProxyStatus {
        set(.checking, for: id)
        let result = await ProxyChecker.check(settings)
        set(result, for: id)
        Log.info("proxy", "check \(id.uuidString.prefix(8)): \(Self.describe(result))")
        return result
    }

    static func describe(_ status: ProxyStatus) -> String {
        switch status {
        case .direct: return "direct"
        case .unchecked: return "unchecked"
        case .checking: return "checking"
        case .working(let ms): return "working" + (ms.map { " \($0) ms" } ?? "")
        case .failed(let message): return "failed (\(message.technical))"
        }
    }
}

/// One request through a profile's proxy, outside WebKit, with the same Network.framework proxy
/// configuration the profile's data store uses (`URLSessionConfiguration.proxyConfigurations`,
/// macOS 14+). Ephemeral: no cookies, cache or credentials are stored, nothing goes direct.
enum ProxyChecker {
    /// Small Apple page that answers "Success"; any HTTP response at all proves the tunnel works.
    static let probeURL = URL(string: "https://www.apple.com/library/test/success.html")!

    static func check(_ settings: ProxySettings, probe: URL = probeURL, timeout: TimeInterval = 12) async -> ProxyStatus {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = ProxyConfigurationFactory.make(settings)
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: probe)
        request.httpMethod = "HEAD"
        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard response is HTTPURLResponse else {
                return .failed(UserFacingError.message(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                                                       proxyConfigured: true) ?? fallbackMessage)
            }
            return .working(milliseconds: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return .failed(UserFacingError.message(for: error, proxyConfigured: true) ?? fallbackMessage)
        }
    }

    static var fallbackMessage: UserFacingMessage {
        UserFacingError.message(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, proxyConfigured: true)
            ?? UserFacingMessage(titleKey: "error.proxy.title", messageKey: "error.proxy.unreachable",
                                 kind: .proxy, technical: "proxy check failed")
    }
}
