import BrowserCore
import Foundation
import WebKit

/// Explicit password fill / capture for the main frame of a tab.
///
/// LIMITATION: WKWebView exposes no autofill hooks (no form-submission callback, no access to
/// Safari AutoFill or the system credential provider). Filling and saving are therefore
/// user-initiated. Both scripts run in the isolated `.defaultClient` content world, so page
/// scripts cannot intercept the function or the DOM prototypes it uses. Main frame only.
@MainActor
enum PasswordAutofill {
    static let fillScript = """
    if (location.origin !== expectedOrigin) return false;
    const visible = (e) => !e.disabled && !e.readOnly && e.getClientRects().length > 0;
    const passwords = Array.from(document.querySelectorAll('input[type=password]')).filter(visible);
    const pw = passwords[0];
    if (!pw) return false;
    const scope = pw.form || document;
    const users = Array.from(scope.querySelectorAll('input[type=email], input[type=text], input[type=tel], input:not([type])'))
      .filter(visible)
      .filter((e) => e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING);
    const setValue = (el, value) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const user = users[users.length - 1];
    if (user && username) setValue(user, username);
    setValue(pw, password);
    return true;
    """

    static let captureScript = """
    const pw = Array.from(document.querySelectorAll('input[type=password]')).find((e) => e.value);
    if (!pw) return null;
    const scope = pw.form || document;
    const users = Array.from(scope.querySelectorAll('input[type=email], input[type=text], input[type=tel], input:not([type])'))
      .filter((e) => e.value && (e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING));
    return { username: users.length ? users[users.length - 1].value : '', password: pw.value, origin: location.origin };
    """

    struct Captured {
        var origin: String
        var username: String
        var password: String
    }

    /// Fills `entry` into the page if the page's origin still equals `origin` (it may have
    /// navigated since the entry was chosen).
    static func fill(_ entry: PasswordEntry, origin: String, in webView: WKWebView,
                     completion: @escaping (Bool) -> Void) {
        webView.callAsyncJavaScript(fillScript,
                                    arguments: ["username": entry.username, "password": entry.password, "expectedOrigin": origin],
                                    in: nil, in: .defaultClient) { result in
            if case .success(let value) = result, (value as? Bool) == true {
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    /// Reads the typed credentials from the page. nil if there is no filled-in password field
    /// or the page origin is not `origin`.
    static func capture(origin: String, in webView: WKWebView, completion: @escaping (Captured?) -> Void) {
        webView.callAsyncJavaScript(captureScript, arguments: [:], in: nil, in: .defaultClient) { result in
            guard case .success(let value) = result, let fields = value as? [String: Any],
                  let password = fields["password"] as? String, !password.isEmpty,
                  fields["origin"] as? String == origin else {
                completion(nil)
                return
            }
            completion(Captured(origin: origin, username: fields["username"] as? String ?? "", password: password))
        }
    }
}
