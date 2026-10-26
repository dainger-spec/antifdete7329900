import XCTest
@testable import BrowserCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class UserFacingErrorTests: XCTestCase {
    private typealias Kind = UserFacingMessage.Kind
    private let url = UserFacingError.Domain.url
    private let cf = UserFacingError.Domain.cfNetwork

    private func map(_ domain: String, _ code: Int, proxy: Bool = false) -> UserFacingMessage? {
        UserFacingError.message(domain: domain, code: code, proxyConfigured: proxy)
    }

    private func nsError(_ domain: String, _ code: Int, underlying: Error? = nil) -> NSError {
        NSError(domain: domain, code: code, userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }

    private func assertMaps(_ domain: String, _ code: Int, proxy: Bool = false, to base: String, _ kind: Kind,
                            title: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard let message = map(domain, code, proxy: proxy) else {
            return XCTFail("\(domain) \(code) mapped to nil", file: file, line: line)
        }
        XCTAssertEqual(message.messageKey, "error.\(base).message", "\(domain) \(code) proxy=\(proxy)", file: file, line: line)
        XCTAssertEqual(message.titleKey, title ?? "error.\(base).title", file: file, line: line)
        XCTAssertEqual(message.kind, kind, "\(domain) \(code) proxy=\(proxy)", file: file, line: line)
        XCTAssertEqual(message.technical, "\(domain) \(code)", file: file, line: line)
    }

    // MARK: Domain/code mapping

    func testURLErrorsWithoutProxy() {
        assertMaps(url, -1001, to: "timeout", .timeout)
        assertMaps(url, -1003, to: "hostNotFound", .notFound)
        assertMaps(url, -1006, to: "hostNotFound", .notFound)
        assertMaps(url, -1004, to: "connect", .network)
        assertMaps(url, -1005, to: "connectionLost", .network)
        assertMaps(url, -1009, to: "offline", .offline)
        assertMaps(url, -1020, to: "dataNotAllowed", .offline)
        assertMaps(url, -1200, to: "tls", .security)
        assertMaps(url, -1201, to: "certDate", .security)
        assertMaps(url, -1204, to: "certDate", .security)
        assertMaps(url, -1202, to: "certUntrusted", .security)
        assertMaps(url, -1203, to: "certUntrusted", .security)
        assertMaps(url, -1205, to: "clientCert", .security)
        assertMaps(url, -1206, to: "clientCert", .security)
        assertMaps(url, -1100, to: "fileNotFound", .notFound)
        assertMaps(url, -1102, to: "fileAccess", .security)
        assertMaps(url, -1011, to: "badResponse", .website)
        assertMaps(url, -1007, to: "redirectLoop", .website)
        assertMaps(url, -1002, to: "badURL", .website)
        assertMaps(url, -1013, to: "authRequired", .website)
        assertMaps(url, -3000, to: "downloadSave", .internal)
        assertMaps(url, -3007, to: "downloadCorrupt", .website)
        assertMaps(url, -1, to: "network", .network) // unknown code in a known domain
        // kCFErrorDomainCFNetwork shares the kCFURLError* values.
        assertMaps(cf, -1001, to: "timeout", .timeout)
        assertMaps(cf, 1, to: "hostNotFound", .notFound) // kCFHostErrorHostNotFound
    }

    func testProxyConfiguredBlamesTheProxyForConnectionLevelFailures() {
        assertMaps(url, -1004, proxy: true, to: "proxy.unreachable", .proxy)
        assertMaps(url, -1001, proxy: true, to: "proxy.timeout", .proxy)
        assertMaps(url, -1005, proxy: true, to: "proxy.connectionLost", .proxy)
        assertMaps(cf, 302, proxy: true, to: "proxy.connectionLost", .proxy) // kCFErrorHTTPConnectionLost
        // Name resolution: still "not found", but the hint mentions the proxy address.
        assertMaps(url, -1003, proxy: true, to: "hostNotFound.proxy", .notFound, title: "error.hostNotFound.title")
        // Not the proxy's fault: no network at all, or the site/TLS answered.
        assertMaps(url, -1009, proxy: true, to: "offline", .offline)
        assertMaps(url, -1011, proxy: true, to: "badResponse", .website)
        assertMaps(url, -1202, proxy: true, to: "certUntrusted", .security)
    }

    func testCFNetworkProxyAndSOCKSCodes() {
        // Values from CFNetwork/CFNetworkErrors.h.
        let expectations: [(Int, String)] = [
            (306, "proxy.unreachable"), // kCFErrorHTTPProxyConnectionFailure
            (310, "proxy.unreachable"), // kCFErrorHTTPSProxyConnectionFailure
            (307, "proxy.auth"), // kCFErrorHTTPBadProxyCredentials
            (311, "proxy.refused"), // kCFStreamErrorHTTPSProxyFailureUnexpectedResponseToCONNECTMethod
            (100, "proxy.protocol"), // kCFSOCKSErrorUnknownClientVersion
            (101, "proxy.protocol"), // kCFSOCKSErrorUnsupportedServerVersion
            (110, "proxy.refused"), // kCFSOCKS4ErrorRequestFailed
            (113, "proxy.refused"), // kCFSOCKS4ErrorUnknownStatusCode
            (120, "proxy.protocol"), // kCFSOCKS5ErrorBadState
            (122, "proxy.auth"), // kCFSOCKS5ErrorBadCredentials
            (123, "proxy.protocol"), // kCFSOCKS5ErrorUnsupportedNegotiationMethod
            (124, "proxy.auth"), // kCFSOCKS5ErrorNoAcceptableMethod
        ]
        for (code, base) in expectations {
            assertMaps(cf, code, proxy: true, to: base, .proxy)
            assertMaps(url, code, proxy: true, to: base, .proxy) // also seen re-wrapped in NSURLErrorDomain
            // No profile proxy: WebKit used the macOS system proxy.
            assertMaps(cf, code, proxy: false, to: "proxy.system", .proxy)
        }
        assertMaps(cf, 308, proxy: true, to: "proxy.system", .proxy) // kCFErrorPACFileError: profiles never use PAC
    }

    func testPOSIXAndNetworkFrameworkDomains() {
        let posix = UserFacingError.Domain.posix
        let nwPOSIX = UserFacingError.Domain.networkPOSIX
        for domain in [posix, nwPOSIX] {
            assertMaps(domain, Int(ECONNREFUSED), to: "connect", .network)
            assertMaps(domain, Int(ECONNREFUSED), proxy: true, to: "proxy.unreachable", .proxy)
            assertMaps(domain, Int(ETIMEDOUT), to: "timeout", .timeout)
            assertMaps(domain, Int(ETIMEDOUT), proxy: true, to: "proxy.timeout", .proxy)
            assertMaps(domain, Int(EHOSTUNREACH), to: "connect", .network)
            assertMaps(domain, Int(EHOSTUNREACH), proxy: true, to: "proxy.unreachable", .proxy)
            assertMaps(domain, Int(ENETUNREACH), to: "offline", .offline)
            assertMaps(domain, Int(ENETUNREACH), proxy: true, to: "proxy.unreachable", .proxy)
            assertMaps(domain, Int(ECONNRESET), to: "connectionLost", .network)
            assertMaps(domain, Int(ECONNRESET), proxy: true, to: "proxy.connectionLost", .proxy)
            assertMaps(domain, Int(ENETDOWN), proxy: true, to: "offline", .offline)
            assertMaps(domain, Int(ENOSPC), to: "diskFull", .internal)
            assertMaps(domain, Int(EACCES), to: "fileAccess", .security)
        }
        assertMaps(posix, 99_999, to: "generic", .internal)
        assertMaps(nwPOSIX, 99_999, to: "network", .network)
        assertMaps(UserFacingError.Domain.networkDNS, -65554, to: "hostNotFound", .notFound) // kDNSServiceErr_NoSuchRecord
        assertMaps(UserFacingError.Domain.networkDNS, -65554, proxy: true, to: "hostNotFound.proxy", .notFound,
                   title: "error.hostNotFound.title")
        let tls = UserFacingError.Domain.networkTLS
        assertMaps(tls, -9814, to: "certDate", .security) // errSSLCertExpired
        assertMaps(tls, -9813, to: "certUntrusted", .security) // errSSLNoRootCert
        assertMaps(tls, -9843, to: "certUntrusted", .security) // errSSLHostNameMismatch
        assertMaps(tls, -9824, to: "tls", .security) // errSSLPeerHandshakeFail
        assertMaps(UserFacingError.Domain.networkSwift, 0, to: "network", .network)
    }

    func testWebKitCocoaAndUnknownDomains() {
        let webKit = UserFacingError.Domain.webKit
        assertMaps(webKit, 100, to: "unsupportedContent", .website)
        assertMaps(webKit, 101, to: "badURL", .website)
        assertMaps(webKit, 103, to: "portBlocked", .security)
        assertMaps(webKit, 106, to: "blocked", .security)
        assertMaps(webKit, 304, to: "redirectLoop", .website)
        assertMaps(UserFacingError.Domain.wk, 2, to: "pageCrashed", .website)
        let cocoa = UserFacingError.Domain.cocoa
        assertMaps(cocoa, 640, to: "diskFull", .internal)
        assertMaps(cocoa, 513, to: "fileAccess", .security)
        assertMaps(cocoa, 260, to: "fileNotFound", .notFound)
        assertMaps(cocoa, 3840, to: "core.corrupt", .internal)
        assertMaps("com.example.Unknown", 42, to: "generic", .internal)
        assertMaps("com.example.Unknown", 42, proxy: true, to: "generic", .internal)
    }

    func testNotWorthShowing() {
        XCTAssertNil(map(url, -999)) // cancelled
        XCTAssertNil(map(url, -999, proxy: true))
        XCTAssertNil(map(cf, -999))
        XCTAssertNil(map(url, -1012)) // the user dismissed the sign-in sheet
        XCTAssertNil(map(UserFacingError.Domain.webKit, 102)) // frame load interrupted (became a download)
        XCTAssertNil(map(UserFacingError.Domain.webKit, 204)) // plug-in will handle load
        XCTAssertNil(map(UserFacingError.Domain.wk, 3)) // web view invalidated (tab closing)
        XCTAssertNil(map(UserFacingError.Domain.cocoa, 3072)) // NSUserCancelledError
        XCTAssertNil(map(UserFacingError.Domain.posix, Int(ECANCELED)))
        XCTAssertNil(UserFacingError.message(for: CancellationError(), proxyConfigured: false))
        XCTAssertNil(UserFacingError.message(for: nsError(url, -999), proxyConfigured: true))
        // A cancellation on the outside wins over whatever it wraps.
        XCTAssertNil(UserFacingError.message(for: nsError(url, -999, underlying: nsError(cf, 310)), proxyConfigured: true))
    }

    // MARK: Error values

    func testNestedUnderlyingErrorsPickTheMostSpecificCause() throws {
        // -1004 "cannot connect" wrapping CFNetwork 310: the proxy code is the precise statement.
        let proxyFailure = nsError(url, -1004, underlying: nsError(cf, 310))
        let proxyMessage = try XCTUnwrap(UserFacingError.message(for: proxyFailure, proxyConfigured: true))
        XCTAssertEqual(proxyMessage.kind, .proxy)
        XCTAssertEqual(proxyMessage.messageKey, "error.proxy.unreachable.message")
        XCTAssertEqual(proxyMessage.technical, "NSURLErrorDomain -1004 (underlying: kCFErrorDomainCFNetwork 310)")
        // Same error, no profile proxy: a system proxy problem, not "site down".
        XCTAssertEqual(UserFacingError.message(for: proxyFailure, proxyConfigured: false)?.messageKey,
                       "error.proxy.system.message")

        // -1200 "secure connection failed" wrapping an expired certificate.
        let tls = nsError(url, -1200, underlying: nsError(UserFacingError.Domain.networkTLS, -9814))
        XCTAssertEqual(UserFacingError.message(for: tls, proxyConfigured: false)?.messageKey, "error.certDate.message")

        // Three levels: unknown wrapper → -1005 → POSIX ECONNRESET; ties go to the outermost mapped.
        let deep = nsError("com.example.Wrapper", 7,
                           underlying: nsError(url, -1001, underlying: nsError(UserFacingError.Domain.posix, Int(ECONNRESET))))
        let deepMessage = try XCTUnwrap(UserFacingError.message(for: deep, proxyConfigured: false))
        XCTAssertEqual(deepMessage.messageKey, "error.timeout.message")
        XCTAssertEqual(deepMessage.technical,
                       "com.example.Wrapper 7 (underlying: NSURLErrorDomain -1001, NSPOSIXErrorDomain \(ECONNRESET))")

        // An unmapped outer error with an unmapped cause still gets a message.
        let unknown = nsError("com.example.A", 1, underlying: nsError("com.example.B", 2))
        XCTAssertEqual(UserFacingError.message(for: unknown, proxyConfigured: false)?.messageKey, "error.generic.message")

        // The chain walk is bounded.
        var chained: NSError = nsError(url, -1009)
        for index in 0..<50 { chained = nsError("com.example.Layer\(index)", index, underlying: chained) }
        let bounded = try XCTUnwrap(UserFacingError.message(for: chained, proxyConfigured: false))
        XCTAssertEqual(bounded.messageKey, "error.generic.message")
        XCTAssertEqual(bounded.technical.components(separatedBy: ", ").count, UserFacingError.maxChainDepth - 1)
    }

    func testCoreErrors() {
        let cases: [(CoreError, String, Kind)] = [
            (.authenticationFailed, "core.decrypt", .security),
            (.wrongPassword, "core.wrongPassword", .security),
            (.vaultAlreadyExists, "core.vaultExists", .internal),
            (.vaultNotFound, "core.vaultNotFound", .internal),
            (.corruptData("x"), "core.corrupt", .internal),
            (.cryptoFailure("x"), "core.crypto", .internal),
            (.invalidConfiguration("x"), "core.invalidConfiguration", .internal),
            (.profileNotFound(UUID()), "core.profileNotFound", .notFound),
            (.unsupportedFormat("x"), "core.unsupportedFormat", .internal),
            (.unsafeArchivePath("../x"), "core.unsafeArchive", .security),
            (.syncConflict(objectID: "o", remoteRevision: 2), "core.syncConflict", .internal),
            (.syncServer(status: 401, message: ""), "core.syncAuth", .security),
            (.syncServer(status: 403, message: ""), "core.syncAuth", .security),
            (.syncServer(status: 500, message: "boom"), "core.syncServer", .website),
            (.io("mkdir /Users/alice/secret"), "core.io", .internal),
        ]
        for (error, base, kind) in cases {
            let message = UserFacingError.message(for: error, proxyConfigured: true)
            XCTAssertEqual(message?.messageKey, "error.\(base).message", "\(error)")
            XCTAssertEqual(message?.titleKey, "error.\(base).title", "\(error)")
            XCTAssertEqual(message?.kind, kind, "\(error)")
        }
        // `technical` names the case only: no paths or other details.
        XCTAssertEqual(UserFacingError.message(for: CoreError.io("mkdir /Users/alice/secret"), proxyConfigured: false)?.technical,
                       "CoreError.io")
        XCTAssertEqual(UserFacingError.message(for: CoreError.syncServer(status: 500, message: "x"), proxyConfigured: false)?.technical,
                       "CoreError.syncServer 500")

        struct Payload: Decodable { let value: Int }
        let decoding = Result { try JSONDecoder().decode(Payload.self, from: Data("{}".utf8)) }
        if case .failure(let error) = decoding {
            XCTAssertEqual(UserFacingError.message(for: error, proxyConfigured: false)?.messageKey, "error.core.corrupt.message")
        } else {
            XCTFail("decoding should fail")
        }
    }

    func testPlatformErrorValues() throws {
        XCTAssertEqual(UserFacingError.Domain.url, NSURLErrorDomain)
        XCTAssertEqual(UserFacingError.Domain.posix, NSPOSIXErrorDomain)
        XCTAssertEqual(UserFacingError.Domain.cocoa, NSCocoaErrorDomain)
        let timeout = try XCTUnwrap(UserFacingError.message(for: URLError(.timedOut), proxyConfigured: false))
        XCTAssertEqual(timeout.kind, .timeout)
        XCTAssertEqual(timeout.technical, "NSURLErrorDomain -1001")
        let refused = POSIXError(.ECONNREFUSED)
        XCTAssertEqual(UserFacingError.message(for: refused, proxyConfigured: true)?.kind, .proxy)
        let cocoa = CocoaError(.fileWriteOutOfSpace)
        XCTAssertEqual(UserFacingError.message(for: cocoa, proxyConfigured: false)?.messageKey, "error.diskFull.message")
    }

    // MARK: Localization

    /// Parses `"key" = "value";` lines of a `.strings` file.
    private func stringsTable(_ language: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: path, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$"#)
        var table: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let key = Range(match.range(at: 1), in: line), let value = Range(match.range(at: 2), in: line) else { continue }
            XCTAssertNil(table[String(line[key])], "duplicate key \(line[key]) in \(language)")
            table[String(line[key])] = String(line[value])
        }
        XCTAssertGreaterThan(table.count, 100, "\(path.path) did not parse")
        return table
    }

    /// Every key the mapper can produce, found by brute force over all domains and the full
    /// range of codes it knows about, both proxy settings, all `CoreError` cases.
    private func reachableKeys() -> Set<String> {
        var keys = Set<String>()
        func add(_ message: UserFacingMessage?) {
            guard let message else { return }
            keys.insert(message.titleKey)
            keys.insert(message.messageKey)
        }
        typealias D = UserFacingError.Domain
        let domains = [D.url, D.cfNetwork, D.posix, D.cocoa, D.webKit, D.wk, D.networkPOSIX,
                       D.networkDNS, D.networkTLS, D.networkSwift, "com.example.Unknown"]
        let codes = Array(-4_100...5_000) + Array(-9_900 ... -9_800) + [-65_554, -72_000, 99_999]
        for domain in domains {
            for code in codes {
                for proxy in [false, true] { add(UserFacingError.message(domain: domain, code: code, proxyConfigured: proxy)) }
            }
        }
        let coreErrors: [CoreError] = [
            .authenticationFailed, .wrongPassword, .vaultAlreadyExists, .vaultNotFound, .corruptData(""), .cryptoFailure(""),
            .invalidConfiguration(""), .profileNotFound(UUID()), .unsupportedFormat(""), .unsafeArchivePath(""),
            .syncConflict(objectID: "", remoteRevision: 0), .syncServer(status: 401, message: ""),
            .syncServer(status: 500, message: ""), .io(""),
        ]
        coreErrors.forEach { add(UserFacingError.message(for: $0, proxyConfigured: false)) }
        struct Payload: Decodable { let value: Int }
        if case .failure(let error) = Result(catching: { try JSONDecoder().decode(Payload.self, from: Data()) }) {
            add(UserFacingError.message(for: error, proxyConfigured: false))
        }
        return keys
    }

    func testEveryKeyIsLocalizedInRussianAndEnglish() throws {
        let russian = try stringsTable("ru")
        let english = try stringsTable("en")
        let declared = Set(UserFacingError.allKeys)
        let reachable = reachableKeys()

        XCTAssertTrue(reachable.isSubset(of: declared), "undeclared keys: \(reachable.subtracting(declared).sorted())")
        XCTAssertEqual(reachable, declared, "declared but unreachable: \(declared.subtracting(reachable).sorted())")
        for key in declared.sorted() {
            XCTAssertTrue(key.hasPrefix("error."), key)
            XCTAssertFalse(russian[key]?.isEmpty ?? true, "missing ru: \(key)")
            XCTAssertFalse(english[key]?.isEmpty ?? true, "missing en: \(key)")
        }
        // No orphaned error.* strings, and both languages carry the same set.
        let russianErrorKeys = Set(russian.keys.filter { $0.hasPrefix("error.") })
        let englishErrorKeys = Set(english.keys.filter { $0.hasPrefix("error.") })
        XCTAssertEqual(russianErrorKeys, declared, "orphans: \(russianErrorKeys.subtracting(declared).sorted())")
        XCTAssertEqual(englishErrorKeys, declared, "orphans: \(englishErrorKeys.subtracting(declared).sorted())")
        // The Russian table is really Russian (catches copy-paste of the English text).
        for key in declared where key.hasSuffix(".message") {
            XCTAssertNotNil(russian[key]?.range(of: "[а-яА-ЯёЁ]", options: .regularExpression), "not Russian: \(key)")
        }
        XCTAssertEqual(Set(Kind.allCases), Set(UserFacingError.Template.all.map(\.kind)), "every kind is used")
    }
}
