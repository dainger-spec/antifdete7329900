// Measurement (claude/measure-canvas-browser, never merged). In WKWebViews of this Mac's WebKit:
//  - CANVAS: the page probe (canvas_probe.js) with no shim, with the iOS app's shim as it is, and
//    with the proposed noise (ios-measure/canvas-alpha/proposed.js), several seeds each;
//  - BROWSER: window.browser (browser_probe.js) in a plain web view, with a WKWebExtensionController,
//    and with one holding a loaded extension (with and without externally_connectable).
// Each result is one line: "<KIND> <label> <json>".
//
//     swiftc -o build/cb-probe measure/canvas_browser/probe.swift
//     build/cb-probe <dir with canvas_probe.js, browser_probe.js, shim-old.js, shim-new.js> <extension dir>
import AppKit
import WebKit

setvbuf(stdout, nil, _IOLBF, 0)
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let extensionsDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
func read(_ name: String) -> String { (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "" }
let canvasProbe = read("canvas_probe.js"), browserProbe = read("browser_probe.js")
let shims = ["old": read("shim-old.js"), "new": read("shim-new.js")]
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

final class Loader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { print("LOAD failed \(error)"); done?.resume(); done = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { print("LOAD failed \(error)"); done?.resume(); done = nil }
}

@MainActor func run(_ configuration: WKWebViewConfiguration, _ body: String, arguments: [String: Any] = [:]) async -> String {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    let loader = Loader()
    view.navigationDelegate = loader
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        loader.done = c
        view.loadHTMLString("<!doctype html><meta charset=utf-8><title>probe</title><body>probe</body>", baseURL: URL(string: "http://127.0.0.1/")!)
    }
    defer { window.orderOut(nil) }
    do {
        let value = try await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        return (value as? String) ?? "{\"error\":\"not a string\"}"
    } catch {
        return "{\"error\":\(String(reflecting: String(describing: error)))}"
    }
}

func shimScript(_ shim: String, seed: String) -> WKUserScript {
    let config = "{\"timeZone\":null,\"geolocation\":{\"mode\":\"deny\"},\"webRTC\":\"unrestricted\",\"safariObject\":false,\"storageQuota\":null,"
        + "\"fingerprint\":{\"seed\":\"\(seed)\",\"canvas\":\"noise\",\"webgl\":\"real\",\"audio\":\"real\",\"language\":null,\"unstable\":false,\"naive\":false}}"
    return WKUserScript(source: "(function install(CONFIG) {\n" + shim + "\n})(" + config + ");", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
}

Task { @MainActor in
    print("MACHINE macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    // Canvas: N (no shim) with the engine's put/get table; old and new noise, three seeds each.
    let plain = WKWebViewConfiguration()
    plain.websiteDataStore = .nonPersistent()
    print("CANVAS N \(await run(plain, "const CFG = {table: true};\n" + canvasProbe))")
    for variant in ["old", "new"] {
        for seed in ["s1", "s2", "s3"] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.addUserScript(shimScript(shims[variant] ?? "", seed: seed))
            print("CANVAS \(variant)/\(seed) \(await run(configuration, "const CFG = {table: false};\n" + canvasProbe))")
        }
    }
    // window.browser.
    let bare = WKWebViewConfiguration()
    bare.websiteDataStore = .nonPersistent()
    print("BROWSER plain \(await run(bare, browserProbe))")
    if #available(macOS 15.4, *) {
        let empty = WKWebViewConfiguration()
        empty.websiteDataStore = .nonPersistent()
        empty.webExtensionController = WKWebExtensionController(configuration: .nonPersistent())
        print("BROWSER controller-no-extension \(await run(empty, browserProbe))")
        for name in ["plain-extension", "externally-connectable"] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let controller = WKWebExtensionController(configuration: .nonPersistent())
            configuration.webExtensionController = controller
            do {
                let webExtension = try await WKWebExtension(resourceBaseURL: extensionsDirectory.appendingPathComponent(name, isDirectory: true))
                let context = WKWebExtensionContext(for: webExtension)
                try controller.load(context)
                print("BROWSER-NOTE \(name): loaded, errors \(webExtension.errors.map { String(describing: $0) }), contexts \(controller.extensionContexts.count)")
            } catch {
                print("BROWSER-NOTE \(name): not loaded: \(error)")
            }
            print("BROWSER controller-\(name) \(await run(configuration, browserProbe))")
        }
    } else {
        print("BROWSER-NOTE WKWebExtensionController needs macOS 15.4")
    }
    print("DONE")
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 900) { print("TIMEOUT"); exit(1) }
application.run()
