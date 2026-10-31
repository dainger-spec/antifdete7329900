import Foundation

extension Error {
    /// What an error is, for the system log in clear: its type, domain and code — never its text,
    /// which can carry a path (with the user's name in it), a host or an address. The text goes
    /// next to it as `privacy: .private` (scripts/check_log_privacy.py).
    var logKind: String {
        let error = self as NSError
        return "\(type(of: self)) \(error.domain) \(error.code)"
    }
}
