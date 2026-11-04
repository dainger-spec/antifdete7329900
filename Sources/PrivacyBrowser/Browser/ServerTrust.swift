import Foundation
import os
import Security
import WebKit

/// The certificate of a site loaded in a profile with a proxy is checked on this Mac — without this
/// Mac going to the network for it.
///
/// A page's connection goes through the profile's proxy, but its certificate is checked here, by
/// the system's trust service (trustd). Asked the system's default way, trustd completes a chain
/// the server sent without its intermediate by downloading the missing certificate from the
/// address the certificate itself names (Authority Information Access), and asks some
/// certificates' revocation status of their authority (OCSP) — over its own connection, as this
/// Mac, outside every proxy. A page can make it do so at will: an image from a server of its own
/// that sends a leaf certificate alone, naming a download address of its own, is a request from
/// this Mac's real address to the page's author, whatever the proxy.
///
/// So in a profile with a proxy the browser answers the server-trust question itself, never with
/// the system's default handling: the same evaluation — the system's roots, the site's name, the
/// revocation data this Mac already has and what the server stapled — with network fetches off.
/// A chain that cannot be completed from what the server sent and what this Mac already holds is
/// refused like any untrusted certificate: the load fails, and nothing goes around the proxy.
/// (Firefox, which never fetches missing intermediates either, refuses the same sites.)
///
/// Where the question reaches the browser: our own tabs and their downloads (`BrowserTab`), the
/// profile's data store for loads no page is behind — a service worker's — (`StoreChallenges`),
/// and, in a profile's own process, whatever delegate Safari's chrome gives its web views, its
/// downloads and its URL sessions (`ProfileNetworkGuard`).
enum ServerTrust {
    typealias Answer = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ServerTrust")

    /// Evaluations made in this process, and of those the ones refused (the network report).
    static let tally = Tally()

    /// Answers the server-trust `challenge`: evaluated without network fetches on a queue of its
    /// own (the evaluation waits for trustd, which the main thread must not), and `answer` called
    /// on the main thread — the trust as the credential when the chain holds, cancelled when not.
    static func answerWithoutFetching(_ challenge: URLAuthenticationChallenge, _ answer: @escaping Answer) {
        let space = challenge.protectionSpace
        guard let trust = space.serverTrust else {
            answer(.cancelAuthenticationChallenge, nil)
            return
        }
        let host = space.host
        let box = TrustBox(trust)
        DispatchQueue.global(qos: .userInitiated).async {
            let trusted = evaluate(box.trust, host: host)
            tally.count(refused: !trusted)
            if !trusted {
                log.notice("The certificate of \(host, privacy: .private) does not hold without fetching from the network: refused")
            }
            DispatchQueue.main.async {
                answer(trusted ? .useCredential : .cancelAuthenticationChallenge, trusted ? URLCredential(trust: box.trust) : nil)
            }
        }
    }

    /// The evaluation itself: the system's SSL policy for `host`, network fetches off.
    static func evaluate(_ trust: SecTrust, host: String) -> Bool {
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// A trust object handed to the evaluating queue, which is then the only one touching it.
    private final class TrustBox: @unchecked Sendable {
        let trust: SecTrust
        init(_ trust: SecTrust) { self.trust = trust }
    }

    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var evaluated = 0
        private var refused = 0
        func count(refused wasRefused: Bool) {
            lock.withLock {
                evaluated += 1
                if wasRefused { refused += 1 }
            }
        }
        var counts: (evaluated: Int, refused: Int) { lock.withLock { (evaluated, refused) } }
    }
}

/// A delegate that answers the challenges of a profile's loads itself, so that the profile's
/// process does not answer them a second time in front of it (`ProfileNetworkGuard`).
@objc protocol AnswersProfileChallenges {}

/// What a profile answers to a challenge of one of its loads, when the answer is the profile's to
/// give: the profile proxy's own request for credentials — with the profile's credentials, never
/// by asking the user (Safari would, and keep what was typed in the user's own keychain) — and,
/// with a proxy, every server-trust question (`ServerTrust`). Everything else (a site's own
/// sign-in, client certificates) is left to whoever gets the challenge.
struct ProfileChallengePolicy {
    var hasProxy: Bool
    var proxyCredential: URLCredential?

    /// True when `challenge` was answered (or will be, through `answer`).
    func answer(_ challenge: URLAuthenticationChallenge, _ answer: @escaping ServerTrust.Answer) -> Bool {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard hasProxy else { return false }
            ServerTrust.answerWithoutFetching(challenge, answer)
            return true
        }
        if space.isProxy(), space.authenticationMethod != NSURLAuthenticationMethodClientCertificate {
            if challenge.previousFailureCount == 0, let proxyCredential {
                answer(.useCredential, proxyCredential)
            } else {
                answer(.cancelAuthenticationChallenge, nil)
            }
            return true
        }
        return false
    }
}

/// The delegate of a profile's data store (`_WKWebsiteDataStoreDelegate`), and of the URL sessions
/// of a profile's process that have none: the challenges of loads no page is behind — a service
/// worker's fetch, a framework's request — come here, and would otherwise get the system's
/// default handling.
final class StoreChallenges: NSObject, AnswersProfileChallenges, URLSessionDelegate, @unchecked Sendable {
    let policy: ProfileChallengePolicy

    init(policy: ProfileChallengePolicy) {
        self.policy = policy
    }

    @objc(didReceiveAuthenticationChallenge:completionHandler:)
    func didReceive(_ challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !policy.answer(challenge, completionHandler) {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !policy.answer(challenge, completionHandler) {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// The navigation delegate of a web view of a profile's process that has none of its own: WebKit
/// answers a challenge with the system's default handling when no delegate is there to ask.
final class WebViewChallenges: NSObject, WKNavigationDelegate, AnswersProfileChallenges {
    let policy: ProfileChallengePolicy

    init(policy: ProfileChallengePolicy) {
        self.policy = policy
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !policy.answer(challenge, completionHandler) {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
