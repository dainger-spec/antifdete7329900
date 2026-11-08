// Measurement (never merged): which of an iPhone's values the Mac's WebKit gives a page natively,
// set through WebKit's own settings rather than a script — navigator.platform through
// WKWebpagePreferences._customNavigatorPlatform, devicePixelRatio through
// WKWebView._overrideDeviceScaleFactor — and what stays the Mac's whatever is set (touch events,
// the pointer and hover media queries, the screen, CSS device-width). For each setting alone and
// together, a plain web view in a 390×844 window loads one page and prints what its page, a worker
// and the stylesheet's own @media rules say, and whether the accessors still read as native.
//
//     swiftc -o build/native-probe scripts/native_spoof_probe.swift && build/native-probe
import AppKit
import WebKit

let page = #"""
<!doctype html><html><head><meta name=viewport content='width=device-width'>
<style>
#coarse{display:none}@media (pointer: coarse){#coarse{display:block}}
#nohover{display:none}@media (hover: none){#nohover{display:block}}
#dpr3{display:none}@media (resolution: 3dppx){#dpr3{display:block}}
#narrow{display:none}@media (device-width: 390px){#narrow{display:block}}
</style></head><body><div id=coarse></div><div id=nohover></div><div id=dpr3></div><div id=narrow></div></body></html>
"""#

let probe = #"""
const shown = (id) => getComputedStyle(document.getElementById(id)).display === 'block';
const native = (o, n) => { let p = o; while (p && !Object.prototype.hasOwnProperty.call(p, n)) p = Object.getPrototypeOf(p);
  if (!p) return 'absent'; const d = Object.getOwnPropertyDescriptor(p, n); return d.get ? /\[native code\]/.test(Function.prototype.toString.call(d.get)) : 'value'; };
const worker = await new Promise((ok) => {
  const w = new Worker(URL.createObjectURL(new Blob(['postMessage(navigator.platform)'], { type: 'text/javascript' })));
  w.onmessage = (e) => ok(e.data); w.onerror = () => ok('error'); setTimeout(() => ok('timeout'), 3000); });
const frame = document.createElement('iframe'); document.body.appendChild(frame);
return JSON.stringify({
  platform: navigator.platform, workerPlatform: worker, blankFramePlatform: frame.contentWindow.navigator.platform,
  platformGetterNative: native(Navigator.prototype, 'platform'),
  devicePixelRatio: devicePixelRatio, dprGetterNative: native(window, 'devicePixelRatio'),
  resolution3dppxCSS: shown('dpr3'), resolution3dppxJS: matchMedia('(resolution: 3dppx)').matches,
  maxTouchPoints: navigator.maxTouchPoints, ontouchstart: 'ontouchstart' in window, TouchEvent: typeof TouchEvent,
  pointerCoarseCSS: shown('coarse'), hoverNoneCSS: shown('nohover'),
  screen: [screen.width, screen.height], deviceWidth390CSS: shown('narrow'), inner: [innerWidth, innerHeight],
  orientation: 'orientation' in window ? window.orientation : 'absent', screenOrientation: screen.orientation ? screen.orientation.type : 'absent'
});
"""#

final class Run: NSObject, WKNavigationDelegate {
    var done: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?() }
}

@MainActor
func measure(_ name: String, platform: String?, scale: CGFloat?) async {
    let configuration = WKWebViewConfiguration()
    let preferences = WKWebpagePreferences()
    var said: [String] = []
    if let platform {
        let setter = NSSelectorFromString("_setCustomNavigatorPlatform:")
        if preferences.responds(to: setter) { preferences.perform(setter, with: platform); said.append("_customNavigatorPlatform=\(platform)") }
        else { said.append("_setCustomNavigatorPlatform: NOT ANSWERED") }
    }
    configuration.defaultWebpagePreferences = preferences
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 390, height: 844), styleMask: [.titled], backing: .buffered, defer: false)
    let view = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
    window.contentView = view
    window.orderFrontRegardless()
    if let scale {
        if view.responds(to: NSSelectorFromString("_setOverrideDeviceScaleFactor:")) {
            view.setValue(scale, forKey: "_overrideDeviceScaleFactor")
            said.append("_overrideDeviceScaleFactor=\(scale) (reads back \(view.value(forKey: "_overrideDeviceScaleFactor") ?? "nil"))")
        } else { said.append("_setOverrideDeviceScaleFactor: NOT ANSWERED") }
    }
    print("NATIVE \(name): loading")
    let run = Run()
    view.navigationDelegate = run
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
        run.done = { finished.resume() }
        view.loadHTMLString(page, baseURL: URL(string: "https://probe.invalid/"))
    }
    print("NATIVE \(name): loaded")
    do {
        let result = try await view.callAsyncJavaScript(probe, contentWorld: .page)
        print("NATIVE \(name) [\(said.joined(separator: ", "))] \(result ?? "nil")")
    } catch {
        print("NATIVE \(name) [\(said.joined(separator: ", "))] error \(error)")
    }
    window.orderOut(nil)
}

setvbuf(stdout, nil, _IOLBF, 0)
print("NATIVE start")
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), screen \(NSScreen.main?.frame.size ?? .zero) at \(NSScreen.main?.backingScaleFactor ?? 0)x")
    await measure("plain", platform: nil, scale: nil)
    await measure("platform", platform: "iPhone", scale: nil)
    await measure("scale", platform: nil, scale: 3)
    await measure("both", platform: "iPhone", scale: 3)
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("NATIVE timeout"); exit(1) }
application.run()
