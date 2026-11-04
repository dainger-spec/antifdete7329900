// Measurement (claude/measure-safari-worlds, never merged): which page policy makes a web view's
// canvas behave as Safari 27's does — getImageData throwing "The object is in an invalid state."
// and toDataURL() giving "data:," (measured in Safari 27.0.1, a plain window, macOS 27.0.1).
// A WKWebView of this process, its WKWebpagePreferences' advanced privacy protections set one
// option at a time (and all of them), the same canvas read each time.
//
//   swiftc -O scripts/canvas_policy_probe.swift -o build/canvas_policy_probe && build/canvas_policy_probe
import AppKit
import WebKit

let canvasScript = """
(() => {
  const out = [];
  try {
    const c = document.createElement('canvas'); c.width = 6; c.height = 6;
    const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 3, 3); x.fillStyle = '#069'; x.fillRect(3, 3, 3, 3);
    out.push('toDataURL ' + c.toDataURL().length);
    try { out.push('getImageData ' + x.getImageData(0, 0, 6, 6).data.slice(0, 4).join(',')); } catch (e) { out.push('getImageData error: ' + e.message); }
  } catch (e) { out.push('error: ' + e.message); }
  out.push('safari ' + typeof window.safari);
  return out.join(' | ');
})()
"""

final class Probe: NSObject, WKNavigationDelegate {
    var done: ((String) -> Void)?
    let view: WKWebView
    init(configuration: WKWebViewConfiguration) {
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(canvasScript) { result, error in
            self.done?((result as? String) ?? "error: \(String(describing: error))")
        }
    }
}

func setProtections(_ preferences: WKWebpagePreferences, _ value: UInt) -> Bool {
    let selector = NSSelectorFromString("_setAdvancedPrivacyProtections:")
    guard preferences.responds(to: selector), let method = class_getInstanceMethod(type(of: preferences), selector) else { return false }
    typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
    unsafeBitCast(method_getImplementation(method), to: Setter.self)(preferences, selector, value)
    return true
}

func protections(_ preferences: WKWebpagePreferences) -> String {
    let selector = NSSelectorFromString("_advancedPrivacyProtections")
    guard preferences.responds(to: selector), let method = class_getInstanceMethod(type(of: preferences), selector) else { return "n/a" }
    typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
    return String(unsafeBitCast(method_getImplementation(method), to: Getter.self)(preferences, selector))
}

@MainActor
func run(_ label: String, bits: UInt?) async -> String {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    var applied = "default"
    if let bits {
        applied = setProtections(configuration.defaultWebpagePreferences, bits) ? "set \(bits) → \(protections(configuration.defaultWebpagePreferences))" : "no setter"
    }
    let probe = Probe(configuration: configuration)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = probe.view
    window.orderFront(nil)
    let result: String = await withCheckedContinuation { continuation in
        var finished = false
        probe.done = { value in if !finished { finished = true; continuation.resume(returning: value) } }
        probe.view.loadHTMLString("<!doctype html><title>p</title><body>p</body>", baseURL: URL(string: "http://127.0.0.1:9/"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if !finished { finished = true; continuation.resume(returning: "timeout") } }
    }
    window.orderOut(nil)
    return "CANVAS-POLICY \(label) [\(applied)]: \(result)"
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    print("CANVAS-POLICY WebKit \(Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] ?? "?")")
    print(await run("none", bits: nil))
    print(await run("zero", bits: 0))
    for bit in 0..<20 { print(await run("bit \(bit)", bits: UInt(1) << UInt(bit))) }
    print(await run("all", bits: UInt(0xFFFFF)))
    exit(0)
}
app.run()
