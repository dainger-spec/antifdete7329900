import BrowserCore
import Foundation

/// Why sync through the Lumen account cannot go now (`AppModel.syncTransport`): this Mac holds no
/// device token — never signed in, signed out, or unlinked by the server (§9.4) — or no renewal of
/// this run has reached the server yet (CONTRACT §16.1). Nothing on this Mac is changed.
struct AccountSyncUnavailable: LocalizedError, Equatable {
    enum Reason: Equatable {
        case notSignedIn
        case notChecked
    }

    let reason: Reason

    var errorDescription: String? {
        switch reason {
        case .notSignedIn: return String(format: L("sync.account.signedOut"), L("settings.section.account"))
        case .notChecked: return L("sync.account.notChecked")
        }
    }
}

/// What the person is told of sync through the Lumen account (`AccountSync`), in the interface's
/// language: the server's refusals are states with words of their own (CONTRACT §16.1), and each says
/// that nothing on this Mac changed.
enum AccountSyncText {
    /// The account server's sync requests go as its other requests do (`AccountHTTP`): no cookies,
    /// no cache. One session for the app's life.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// `403 sync_on_hold`: when sync opens on this device, and why it waits.
    static func onHold(_ date: Date?) -> String {
        guard let date else { return L("sync.account.onHold.later") }
        return String(format: L("sync.account.onHold"), date.shown(date: .long, time: .shortened))
    }

    /// A failed run through the account (`AccountSync.outcome`). `signedIn`: this Mac still holds a
    /// device token (a `401` renewed the license, which may have signed it out).
    static func text(_ outcome: AccountSync.Outcome, error: Error, signedIn: Bool) -> String {
        switch outcome {
        case .unauthorized:
            guard signedIn else { return AccountSyncUnavailable(reason: .notSignedIn).errorDescription ?? errorText(error) }
            return String(format: L("sync.account.unauthorized"), L("settings.section.account"))
        case .anotherAccount: return L("sync.account.anotherAccount")
        case .tooManyVaults: return L("sync.account.tooManyVaults")
        case .accountDisabled: return L("sync.account.disabled")
        case .onHold(let until): return onHold(until)
        case .notInPlan: return L("sync.account.notInPlan")
        case .rateLimited: return L("sync.account.rateLimited")
        case .overQuota: return L("sync.account.overQuota")
        case .tooLarge: return L("sync.account.tooLarge")
        case .generationChanged, .other: return errorText(error)
        }
    }
}
