import Foundation

/// The page a tab shows when a site can't be loaded. Static HTML with no script; every value is
/// HTML-escaped, and the retry link only ever points at the http(s) address that failed.
enum ErrorPage {
    static func html(title: String, message: String, retryURL: URL?, retryLabel: String,
                     details: String, hint: String?) -> String {
        let retry = retryURL.map { "<p><a class=\"button\" href=\"\(escape($0.absoluteString))\">\(escape(retryLabel))</a></p>" } ?? ""
        let hintBlock = hint.map { "<p class=\"hint\">\(escape($0))</p>" } ?? ""
        let address = retryURL.map { "<p class=\"address\">\(escape($0.host ?? $0.absoluteString))</p>" } ?? ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px -apple-system, system-ui, sans-serif; margin: 0; padding: 72px 48px;
                 background: Canvas; color: CanvasText; }
          main { max-width: 560px; margin: 0 auto; }
          h1 { font-size: 24px; font-weight: 600; margin: 0 0 8px; }
          p { line-height: 1.5; margin: 10px 0; }
          .address { color: GrayText; margin-top: 0; }
          .hint { color: GrayText; }
          .details { color: GrayText; font: 12px ui-monospace, Menlo, monospace; margin-top: 28px; }
          .button { display: inline-block; margin-top: 12px; padding: 7px 16px; border-radius: 7px;
                    background: AccentColor; color: AccentColorText; text-decoration: none; }
        </style></head>
        <body><main>
          <h1>\(escape(title))</h1>
          \(address)
          <p>\(escape(message))</p>
          \(hintBlock)
          \(retry)
          <p class="details">\(escape(details))</p>
        </main></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
