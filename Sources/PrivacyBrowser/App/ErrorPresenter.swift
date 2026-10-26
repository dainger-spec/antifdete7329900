import BrowserCore
import Foundation

/// An error as the user sees it: what happened, in plain words, what to do, and — folded away —
/// the technical code for a bug report.
struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var details: String?

    init(title: String, message: String, details: String? = nil) {
        self.title = title
        self.message = message
        self.details = details
    }
}

/// Turns errors into `AppAlert`s through `UserFacingError` (BrowserCore), which maps network,
/// proxy, TLS and vault errors to localized message keys. Anything it doesn't know becomes a
/// generic message with the technical description as details — never a raw log line as the
/// main text.
enum ErrorPresenter {
    /// `titleKey` names the action that failed ("Could not open the profile"); nil uses the
    /// mapper's own title.
    static func alert(for error: Error, titleKey: String? = nil, proxyConfigured: Bool = false) -> AppAlert? {
        if error is CancellationError { return nil }
        if let message = UserFacingError.message(for: error, proxyConfigured: proxyConfigured) {
            return AppAlert(title: L(titleKey ?? message.titleKey), message: L(message.messageKey),
                            details: message.technical)
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return nil }
        return AppAlert(title: L(titleKey ?? "error.generic.title"), message: L("error.generic.message"),
                        details: Log.describe(error))
    }

    /// For messages the app composes itself (validation in forms).
    static func alert(titleKey: String, messageKey: String, details: String? = nil) -> AppAlert {
        AppAlert(title: L(titleKey), message: L(messageKey), details: details)
    }
}
