import Foundation

/// A plain-language description of a failure, as localization keys.
///
/// The app looks up `titleKey` / `messageKey` in `Localizable.strings` (Russian first,
/// English fallback); `technical` (e.g. `"NSURLErrorDomain -1004"`) goes into a
/// "Details" disclosure and the log, never into the headline.
public struct UserFacingMessage: Equatable, Sendable {
    /// What failed, from the user's point of view. Drives the icon and the suggested action
    /// (open proxy settings, reload, check Wi‑Fi…).
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// The profile's proxy (or the system proxy) is the problem.
        case proxy
        /// A connection to the site failed for a network reason.
        case network
        /// The site, file or record does not exist.
        case notFound
        /// TLS / certificate / permission / blocked content.
        case security
        /// The site did not answer in time.
        case timeout
        /// This Mac has no usable network.
        case offline
        /// The site answered, but wrongly (bad response, redirect loop, crash of the page).
        case website
        /// The app's own storage, crypto or an unexpected error.
        case `internal`
    }

    public var titleKey: String
    public var messageKey: String
    public var kind: Kind
    /// Domain and code of the error and its underlying errors, e.g.
    /// `"NSURLErrorDomain -1004 (underlying: kCFErrorDomainCFNetwork 310)"`. Contains no
    /// URLs, hosts or user data, so it is safe to show and to log.
    public var technical: String

    public init(titleKey: String, messageKey: String, kind: Kind, technical: String) {
        self.titleKey = titleKey
        self.messageKey = messageKey
        self.kind = kind
        self.technical = technical
    }
}

/// Maps technical errors (WebKit navigation failures, URL loading, POSIX, Network.framework,
/// file system, `CoreError`) to `UserFacingMessage`s.
///
/// **Proxy awareness.** Profiles with a proxy use `allowFailover = false`, so the proxy is the
/// first network hop: if the connection fails at the connection level (cannot connect,
/// timeout, connection lost, SOCKS/HTTP-proxy codes), the proxy is by far the likeliest cause
/// and the message points at the profile's proxy settings. Without a profile proxy, WebKit
/// uses the macOS system proxy settings, so proxy-specific codes are reported as a *system*
/// proxy problem.
///
/// **Underlying errors.** URL-loading errors often wrap a more precise cause in
/// `NSUnderlyingErrorKey` (e.g. `NSURLErrorDomain -1004` wrapping
/// `kCFErrorDomainCFNetwork 310`, or `-1200` wrapping `kNWErrorDomainTLS -9814`). The chain is
/// walked (bounded depth) and the most specific mapping wins; ties go to the outermost error.
/// A cancellation in the outermost error suppresses the message whatever it wraps.
///
/// Code values are taken from the macOS SDK headers: `CFNetwork/CFNetworkErrors.h`
/// (`kCFHostError*`, `kCFSOCKS*Error*` 100–124, `kCFErrorHTTP*` 300–311, `kCFURLError*`),
/// `Security/SecureTransport.h` (`errSSL*`), `WebKit/WebKitErrors.h`, `WKErrorRef.h` /
/// `WKErrorPrivate.h` (WebKitErrorDomain 100–106, 204, 302–304), `WebKit/WKError.h`, and
/// `Network/error.h` (`kNWErrorDomain*`). They are spelled as literals because BrowserCore
/// builds on Linux, where those frameworks do not exist.
public enum UserFacingError {
    /// Error domain strings as they appear in `NSError.domain`.
    public enum Domain {
        public static let url = "NSURLErrorDomain"
        public static let cfNetwork = "kCFErrorDomainCFNetwork"
        public static let posix = "NSPOSIXErrorDomain"
        public static let cocoa = "NSCocoaErrorDomain"
        /// WebKit's policy/legacy errors (`WebKitErrorFrameLoadInterruptedByPolicyChange` …).
        public static let webKit = "WebKitErrorDomain"
        /// `WKError` (`WKErrorWebContentProcessTerminated` …).
        public static let wk = "WKErrorDomain"
        public static let networkPOSIX = "kNWErrorDomainPOSIX"
        public static let networkDNS = "kNWErrorDomainDNS"
        public static let networkTLS = "kNWErrorDomainTLS"
        /// Swift `NWError` bridged to `NSError`. The payload (POSIX/DNS/TLS code) does not
        /// survive that bridging, so only a generic network message is possible.
        public static let networkSwift = "Network.NWError"
    }

    /// Maps one domain/code pair. `nil` means "not worth showing" (cancellations, a
    /// navigation that became a download, a web view torn down on close). Unknown pairs
    /// get a generic message rather than `nil`.
    public static func message(domain: String, code: Int, proxyConfigured: Bool) -> UserFacingMessage? {
        let technical = describe(domain: domain, code: code)
        switch classify(domain: domain, code: code, proxy: proxyConfigured) {
        case .ignore: return nil
        case .mapped(let template, _): return template.message(technical: technical)
        case .unmapped: return Template.generic.message(technical: technical)
        }
    }

    /// Maps any error: `CoreError`, `NSError` / bridged errors (with their
    /// `NSUnderlyingErrorKey` chain), `DecodingError`, `CancellationError` (`nil`).
    public static func message(for error: Error, proxyConfigured: Bool) -> UserFacingMessage? {
        var chain: [Error] = []
        var current: Error? = error
        while let next = current, chain.count < maxChainDepth {
            chain.append(next)
            current = underlying(of: next)
        }
        let classified = chain.map { classify($0, proxy: proxyConfigured) }
        let technical = describeChain(chain)
        guard let outermost = classified.first else { return nil }
        if case .ignore = outermost { return nil }

        var best: (template: Template, specificity: Specificity)?
        for case .mapped(let template, let specificity) in classified
        where best.map({ specificity > $0.specificity }) ?? true {
            best = (template, specificity)
        }
        return (best?.template ?? .generic).message(technical: technical)
    }

    /// Every title and message key the mapper can return. The app's string tables must
    /// contain all of them (enforced by a unit test against both `.lproj` files).
    public static var allKeys: [String] {
        var seen = Set<String>()
        return Template.all.flatMap { [$0.title, $0.message] }.filter { seen.insert($0).inserted }
    }

    // MARK: Classification

    static let maxChainDepth = 8

    enum Specificity: Int, Comparable {
        /// "Something with the connection" (`-1004`, `-1200`, unknown code in a known domain).
        case generic = 0
        case specific = 1
        /// A proxy/SOCKS protocol code: the most precise statement available.
        case proxyDetail = 2

        static func < (lhs: Specificity, rhs: Specificity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Classification {
        case ignore
        case unmapped
        case mapped(Template, Specificity)
    }

    static func classify(_ error: Error, proxy: Bool) -> Classification {
        if let core = error as? CoreError { return .mapped(template(for: core), .specific) }
        if error is CancellationError { return .ignore }
        if error is DecodingError { return .mapped(.coreCorrupt, .specific) }
        let nsError = error as NSError
        return classify(domain: nsError.domain, code: nsError.code, proxy: proxy)
    }

    static func classify(domain: String, code: Int, proxy: Bool) -> Classification {
        switch domain {
        case Domain.url, Domain.cfNetwork: return classifyURLLoading(code, proxy: proxy)
        case Domain.posix: return classifyPOSIX(code, proxy: proxy, network: false)
        case Domain.networkPOSIX: return classifyPOSIX(code, proxy: proxy, network: true)
        case Domain.networkDNS: return .mapped(proxy ? .hostNotFoundProxy : .hostNotFound, .specific)
        case Domain.networkTLS: return classifyTLS(code)
        case Domain.networkSwift: return .mapped(.network, .generic)
        case Domain.webKit: return classifyWebKit(code)
        case Domain.wk: return classifyWK(code)
        case Domain.cocoa: return classifyCocoa(code)
        default: return .unmapped
        }
    }

    /// `NSURLErrorDomain` and `kCFErrorDomainCFNetwork` share code values (CFNetworkErrors.h);
    /// CFNetwork's positive proxy/SOCKS codes also show up re-wrapped in `NSURLErrorDomain`.
    private static func classifyURLLoading(_ code: Int, proxy: Bool) -> Classification {
        switch code {
        case -999, // kCFURLErrorCancelled
             -1012: // kCFURLErrorUserCancelledAuthentication: the user dismissed the sign-in sheet
            return .ignore

        case -1001: return .mapped(proxy ? .proxyTimeout : .timeout, .specific) // TimedOut
        case -1003, -1006, // CannotFindHost, DNSLookupFailed
             1, 2: // kCFHostErrorHostNotFound, kCFHostErrorUnknown
            return .mapped(proxy ? .hostNotFoundProxy : .hostNotFound, .specific)
        case -1004: return .mapped(proxy ? .proxyUnreachable : .connect, .generic) // CannotConnectToHost
        case -1005, // NetworkConnectionLost
             302: // kCFErrorHTTPConnectionLost
            return .mapped(proxy ? .proxyConnectionLost : .connectionLost, .generic)
        case -1009: return .mapped(.offline, .specific) // NotConnectedToInternet: no path at all, proxy or not
        case -1018, -1019, -1020: // InternationalRoamingOff, CallIsActive, DataNotAllowed
            return .mapped(.dataNotAllowed, .specific)

        case -1000, -1002, 305: return .mapped(.badURL, .specific) // BadURL, UnsupportedURL, kCFErrorHTTPBadURL
        case -1007, 304: return .mapped(.redirectLoop, .specific) // HTTPTooManyRedirects, kCFErrorHTTPRedirectionLoopDetected
        case -1008: return .mapped(.unavailable, .specific) // ResourceUnavailable
        case -1010, -1011, -1014, -1015, -1016, -1017, 303:
            // RedirectToNonExistentLocation, BadServerResponse, ZeroByteResource, CannotDecodeRawData,
            // CannotDecodeContentData, CannotParseResponse, kCFErrorHTTPParseFailure
            return .mapped(.badResponse, .specific)
        case -1013, 300, 301: // UserAuthenticationRequired, kCFErrorHTTPAuthenticationTypeUnsupported, kCFErrorHTTPBadCredentials
            return .mapped(.authRequired, .specific)

        case -1100: return .mapped(.fileNotFound, .specific) // FileDoesNotExist
        case -1101, -1102, -1104: return .mapped(.fileAccess, .specific) // FileIsDirectory, NoPermissionsToReadFile, FileOutsideSafeArea

        case -1200: return .mapped(.tls, .generic) // SecureConnectionFailed
        case -1201, -1204: return .mapped(.certDate, .specific) // ServerCertificateHasBadDate, ServerCertificateNotYetValid
        case -1202, -1203: return .mapped(.certUntrusted, .specific) // ServerCertificateUntrusted, ServerCertificateHasUnknownRoot
        case -1205, -1206: return .mapped(.clientCert, .specific) // ClientCertificateRejected, ClientCertificateRequired

        case -3005 ... -3000: return .mapped(.downloadSave, .specific) // CannotCreateFile … CannotMoveFile
        case -3007, -3006: return .mapped(.downloadCorrupt, .specific) // DownloadDecodingFailedMidStream/ToComplete

        // SOCKS (kCFSOCKSError*, kCFSOCKS4Error*, kCFSOCKS5Error*)
        case 100, 101, // UnknownClientVersion, UnsupportedServerVersion: not a SOCKS server / wrong version
             120, 121, 123: // SOCKS5 BadState, BadResponseAddr, UnsupportedNegotiationMethod
            return .mapped(proxy ? .proxyProtocol : .proxySystem, .proxyDetail)
        case 110, 111, 112, 113: // SOCKS4 RequestFailed, IdentdFailed, IdConflict, UnknownStatusCode
            return .mapped(proxy ? .proxyRefused : .proxySystem, .proxyDetail)
        case 122, 124: // SOCKS5 BadCredentials, NoAcceptableMethod (server wants auth we did not offer)
            return .mapped(proxy ? .proxyAuth : .proxySystem, .proxyDetail)

        // HTTP(S) proxy (kCFErrorHTTP*)
        case 306, 310: // HTTPProxyConnectionFailure, HTTPSProxyConnectionFailure
            return .mapped(proxy ? .proxyUnreachable : .proxySystem, .proxyDetail)
        case 307: // HTTPBadProxyCredentials
            return .mapped(proxy ? .proxyAuth : .proxySystem, .proxyDetail)
        case 311: // kCFStreamErrorHTTPSProxyFailureUnexpectedResponseToCONNECTMethod (403/407/502 to CONNECT)
            return .mapped(proxy ? .proxyRefused : .proxySystem, .proxyDetail)
        case 308, 309: // PACFileError, PACFileAuth: profiles never use PAC, so this is the system's
            return .mapped(.proxySystem, .proxyDetail)

        default: return .mapped(.network, .generic)
        }
    }

    /// POSIX codes come from the running platform's `errno.h` (Darwin and glibc numbers
    /// differ), which is right: the error was produced on the same platform.
    private static func classifyPOSIX(_ code: Int, proxy: Bool, network: Bool) -> Classification {
        guard let value = Int32(exactly: code) else { return .mapped(network ? .network : .generic, .generic) }
        switch value {
        case ECANCELED: return .ignore
        case ECONNREFUSED, EHOSTUNREACH, EHOSTDOWN:
            return .mapped(proxy ? .proxyUnreachable : .connect, .specific)
        case ENETUNREACH: return .mapped(proxy ? .proxyUnreachable : .offline, .specific)
        case ENETDOWN: return .mapped(.offline, .specific)
        case ETIMEDOUT: return .mapped(proxy ? .proxyTimeout : .timeout, .specific)
        case ECONNRESET, ECONNABORTED, EPIPE, ENOTCONN:
            return .mapped(proxy ? .proxyConnectionLost : .connectionLost, .specific)
        case ENOSPC, EDQUOT: return .mapped(.diskFull, .specific)
        case EACCES, EPERM, EROFS: return .mapped(.fileAccess, .specific)
        case ENOENT: return .mapped(.fileNotFound, .specific)
        default: return .mapped(network ? .network : .generic, .generic)
        }
    }

    /// `kNWErrorDomainTLS` carries SecureTransport `errSSL*` OSStatus values. Only the
    /// server-certificate verdicts are singled out; `errSSLPeer*` are alerts *from* the server
    /// about us and read as a generic TLS failure.
    private static func classifyTLS(_ code: Int) -> Classification {
        switch code {
        case -9814, -9815: // errSSLCertExpired, errSSLCertNotYetValid
            return .mapped(.certDate, .specific)
        case -9807, -9808, -9812, -9813, -9843:
            // errSSLXCertChainInvalid, errSSLBadCert, errSSLUnknownRootCert, errSSLNoRootCert, errSSLHostNameMismatch
            return .mapped(.certUntrusted, .specific)
        default: return .mapped(.tls, .generic)
        }
    }

    private static func classifyWebKit(_ code: Int) -> Classification {
        switch code {
        case 102, // FrameLoadInterruptedByPolicyChange: navigation became a download or was replaced
             204, // PlugInWillHandleLoad
             302: // kWKErrorCodeCancelled
            return .ignore
        case 100: return .mapped(.unsupportedContent, .specific) // CannotShowMIMEType
        case 101: return .mapped(.badURL, .specific) // CannotShowURL
        case 103: return .mapped(.portBlocked, .specific) // CannotUseRestrictedPort
        case 104, 105, 106: return .mapped(.blocked, .specific) // BlockedByContentBlocker / ContentFilter / Restrictions
        case 303: return .mapped(.fileNotFound, .specific) // kWKErrorCodeFileDoesNotExist
        case 304: return .mapped(.redirectLoop, .specific) // HTTPSUpgradeRedirectLoop
        default: return .mapped(.generic, .generic)
        }
    }

    private static func classifyWK(_ code: Int) -> Classification {
        switch code {
        case 2: return .mapped(.pageCrashed, .specific) // WKErrorWebContentProcessTerminated
        case 3: return .ignore // WKErrorWebViewInvalidated: the tab is being closed
        default: return .mapped(.generic, .generic)
        }
    }

    private static func classifyCocoa(_ code: Int) -> Classification {
        switch code {
        case 3072: return .ignore // NSUserCancelledError
        case 4, 260: return .mapped(.fileNotFound, .specific) // NSFileNoSuchFileError, NSFileReadNoSuchFileError
        case 257, 513, 642: // NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError
            return .mapped(.fileAccess, .specific)
        case 640: return .mapped(.diskFull, .specific) // NSFileWriteOutOfSpaceError
        case 259, 3840, 4864: // NSFileReadCorruptFileError, NSPropertyListReadCorruptError (JSON), NSCoderReadCorruptError
            return .mapped(.coreCorrupt, .specific)
        default: return .mapped(.generic, .generic)
        }
    }

    static func template(for error: CoreError) -> Template {
        switch error {
        case .authenticationFailed: return .coreDecrypt
        case .wrongPassword: return .coreWrongPassword
        case .vaultAlreadyExists: return .coreVaultExists
        case .vaultNotFound: return .coreVaultNotFound
        case .corruptData: return .coreCorrupt
        case .cryptoFailure: return .coreCrypto
        case .invalidConfiguration: return .coreInvalidConfiguration
        case .profileNotFound: return .coreProfileNotFound
        case .unsupportedFormat: return .coreUnsupportedFormat
        case .unsafeArchivePath: return .coreUnsafeArchive
        case .syncConflict: return .coreSyncConflict
        case .syncServer(let status, _): return status == 401 || status == 403 ? .coreSyncAuth : .coreSyncServer
        case .io: return .coreIO
        }
    }

    // MARK: Chain helpers

    private static func underlying(of error: Error) -> Error? {
        if error is CoreError { return nil }
        return (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
    }

    /// Case name only: `CoreError` details can contain file names, and `technical` must stay
    /// free of user data.
    static func describe(_ error: Error) -> String {
        if let core = error as? CoreError {
            switch core {
            case .authenticationFailed: return "CoreError.authenticationFailed"
            case .wrongPassword: return "CoreError.wrongPassword"
            case .vaultAlreadyExists: return "CoreError.vaultAlreadyExists"
            case .vaultNotFound: return "CoreError.vaultNotFound"
            case .corruptData: return "CoreError.corruptData"
            case .cryptoFailure: return "CoreError.cryptoFailure"
            case .invalidConfiguration: return "CoreError.invalidConfiguration"
            case .profileNotFound: return "CoreError.profileNotFound"
            case .unsupportedFormat: return "CoreError.unsupportedFormat"
            case .unsafeArchivePath: return "CoreError.unsafeArchivePath"
            case .syncConflict: return "CoreError.syncConflict"
            case .syncServer(let status, _): return "CoreError.syncServer \(status)"
            case .io: return "CoreError.io"
            }
        }
        if error is DecodingError { return "DecodingError" }
        if error is CancellationError { return "CancellationError" }
        let nsError = error as NSError
        return describe(domain: nsError.domain, code: nsError.code)
    }

    static func describe(domain: String, code: Int) -> String { "\(domain) \(code)" }

    static func describeChain(_ chain: [Error]) -> String {
        guard let first = chain.first else { return "" }
        let head = describe(first)
        guard chain.count > 1 else { return head }
        return head + " (underlying: " + chain.dropFirst().map(describe).joined(separator: ", ") + ")"
    }

    // MARK: Templates

    /// One user-facing message: localization keys + kind. Titles may be shared.
    struct Template: Equatable {
        let title: String
        let message: String
        let kind: UserFacingMessage.Kind

        init(_ base: String, _ kind: UserFacingMessage.Kind, title: String? = nil) {
            self.title = title ?? "error.\(base).title"
            self.message = "error.\(base).message"
            self.kind = kind
        }

        func message(technical: String) -> UserFacingMessage {
            UserFacingMessage(titleKey: title, messageKey: message, kind: kind, technical: technical)
        }

        // Proxy
        static let proxyUnreachable = Template("proxy.unreachable", .proxy)
        static let proxyTimeout = Template("proxy.timeout", .proxy)
        static let proxyConnectionLost = Template("proxy.connectionLost", .proxy)
        static let proxyAuth = Template("proxy.auth", .proxy)
        static let proxyProtocol = Template("proxy.protocol", .proxy)
        static let proxyRefused = Template("proxy.refused", .proxy)
        static let proxySystem = Template("proxy.system", .proxy)
        // Network / timeout / offline
        static let connect = Template("connect", .network)
        static let connectionLost = Template("connectionLost", .network)
        static let network = Template("network", .network)
        static let timeout = Template("timeout", .timeout)
        static let offline = Template("offline", .offline)
        static let dataNotAllowed = Template("dataNotAllowed", .offline)
        // Not found
        static let hostNotFound = Template("hostNotFound", .notFound)
        static let hostNotFoundProxy = Template("hostNotFound.proxy", .notFound, title: "error.hostNotFound.title")
        static let fileNotFound = Template("fileNotFound", .notFound)
        // Security
        static let tls = Template("tls", .security)
        static let certDate = Template("certDate", .security)
        static let certUntrusted = Template("certUntrusted", .security)
        static let clientCert = Template("clientCert", .security)
        static let fileAccess = Template("fileAccess", .security)
        static let portBlocked = Template("portBlocked", .security)
        static let blocked = Template("blocked", .security)
        // Website
        static let badResponse = Template("badResponse", .website)
        static let unavailable = Template("unavailable", .website)
        static let redirectLoop = Template("redirectLoop", .website)
        static let badURL = Template("badURL", .website)
        static let unsupportedContent = Template("unsupportedContent", .website)
        static let authRequired = Template("authRequired", .website)
        static let pageCrashed = Template("pageCrashed", .website)
        static let downloadCorrupt = Template("downloadCorrupt", .website)
        // Internal
        static let generic = Template("generic", .internal)
        static let diskFull = Template("diskFull", .internal)
        static let downloadSave = Template("downloadSave", .internal)
        // CoreError
        static let coreWrongPassword = Template("core.wrongPassword", .security)
        static let coreDecrypt = Template("core.decrypt", .security)
        static let coreUnsafeArchive = Template("core.unsafeArchive", .security)
        static let coreSyncAuth = Template("core.syncAuth", .security)
        static let coreProfileNotFound = Template("core.profileNotFound", .notFound)
        static let coreSyncServer = Template("core.syncServer", .website)
        static let coreCorrupt = Template("core.corrupt", .internal)
        static let coreUnsupportedFormat = Template("core.unsupportedFormat", .internal)
        static let coreVaultExists = Template("core.vaultExists", .internal)
        static let coreVaultNotFound = Template("core.vaultNotFound", .internal)
        static let coreInvalidConfiguration = Template("core.invalidConfiguration", .internal)
        static let coreCrypto = Template("core.crypto", .internal)
        static let coreIO = Template("core.io", .internal)
        static let coreSyncConflict = Template("core.syncConflict", .internal)

        static let all: [Template] = [
            proxyUnreachable, proxyTimeout, proxyConnectionLost, proxyAuth, proxyProtocol, proxyRefused, proxySystem,
            connect, connectionLost, network, timeout, offline, dataNotAllowed,
            hostNotFound, hostNotFoundProxy, fileNotFound,
            tls, certDate, certUntrusted, clientCert, fileAccess, portBlocked, blocked,
            badResponse, unavailable, redirectLoop, badURL, unsupportedContent, authRequired, pageCrashed, downloadCorrupt,
            generic, diskFull, downloadSave,
            coreWrongPassword, coreDecrypt, coreUnsafeArchive, coreSyncAuth, coreProfileNotFound, coreSyncServer,
            coreCorrupt, coreUnsupportedFormat, coreVaultExists, coreVaultNotFound, coreInvalidConfiguration,
            coreCrypto, coreIO, coreSyncConflict,
        ]
    }
}
