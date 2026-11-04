// Measurement (claude/measure-safari-engines, never merged): which WebKit an ordinary app's web view
// runs on this Mac — the framework it loaded, the build, and two features WebKit 27 has and WebKit
// 21624 (Safari 26.6.2's) has not. Run plain, and with DYLD_VERSIONED_FRAMEWORK_PATH pointing at a
// copy of WebKit Safari carries for itself, to see whether the engine is chosen per process.
//
//   swiftc -O scripts/engine_probe.swift -o build/engine_probe && build/engine_probe <label>
import AppKit
import WebKit

let script = """
(() => [
  'ua ' + navigator.userAgent,
  'ReadableStream.prototype.values ' + typeof ReadableStream.prototype.values,
  'HTMLSelectedContentElement ' + typeof window.HTMLSelectedContentElement,
  'safari ' + typeof window.safari,
].join(' | '))()
"""

final class Probe: NSObject, WKNavigationDelegate {
    var done: ((String) -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(script) { result, error in
            self.done?((result as? String) ?? "error: \(String(describing: error))")
        }
    }
}

let label = CommandLine.arguments.dropFirst().first ?? "plain"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bundle = Bundle(for: WKWebView.self)
print("ENGINE-APP \(label) framework \(bundle.bundlePath) build \(bundle.infoDictionary?["CFBundleVersion"] ?? "?")")
print("ENGINE-APP \(label) DYLD_VERSIONED_FRAMEWORK_PATH=\(ProcessInfo.processInfo.environment["DYLD_VERSIONED_FRAMEWORK_PATH"] ?? "-")")
var loaded: [String] = []
for index in 0..<_dyld_image_count() {
    let name = String(cString: _dyld_get_image_name(index))
    if name.contains("WebKit.framework/") || name.contains("WebCore.framework/") || name.hasSuffix("JavaScriptCore") { loaded.append(name) }
}
for name in loaded.prefix(6) { print("ENGINE-APP \(label) loaded \(name)") }

let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
let probe = Probe()
view.navigationDelegate = probe
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = view
window.orderFront(nil)
probe.done = { value in
    print("ENGINE-APP \(label) page: \(value)")
    exit(0)
}
view.loadHTMLString("<!doctype html><title>e</title><body>e</body>", baseURL: URL(string: "http://127.0.0.1:9/"))
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("ENGINE-APP \(label) page: timeout"); exit(0) }
app.run()
