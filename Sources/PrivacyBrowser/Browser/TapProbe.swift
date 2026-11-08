import AppKit
import WebKit

/// What a page hears of a press with the mouse in a profile's window (`WindowProbeAction.tap`),
/// for the self-test: an iPhone view's full disguise must turn it into a phone's tap — touchstart
/// and touchend at the place pressed, then the click, and a field pressed takes the focus — and a
/// page that cancels touchstart must get no mouse events, no click and no focus from it, as on a
/// phone. Sent by the self-test only, never by the app.
@MainActor
enum TapProbe {
    /// Laid over the page, fixed, so a scrolled page does not move them: a field, a button whose
    /// touchstart the page cancels, a second field whose touchstart it cancels.
    private static let setUp = """
    for (const id of ['pb-tap-field', 'pb-tap-cancel', 'pb-tap-guarded']) document.getElementById(id)?.remove();
    const make = (tag, id, top) => { const e = document.createElement(tag); e.id = id;
      e.style.cssText = 'position:fixed;left:20px;width:240px;height:56px;z-index:2147483647;top:' + top + 'px';
      if (tag === 'button') e.textContent = id; document.documentElement.appendChild(e); return e; };
    const field = make('input', 'pb-tap-field', 80), cancel = make('button', 'pb-tap-cancel', 160), guarded = make('input', 'pb-tap-guarded', 240);
    for (const e of [cancel, guarded]) e.addEventListener('touchstart', (event) => event.preventDefault());
    window.__pbTaps = [];
    for (const type of ['pointerdown', 'touchstart', 'mousedown', 'focus', 'pointerup', 'touchend', 'mouseup', 'click'])
      for (const e of [field, cancel, guarded]) e.addEventListener(type, (event) => {
        const t = event.changedTouches && event.changedTouches[0];
        window.__pbTaps.push({ on: e.id, type: type, pointerType: event.pointerType || null,
                               touches: event.touches ? event.touches.length : null,
                               at: t ? [Math.round(t.clientX), Math.round(t.clientY)] : null,
                               cancelable: event.cancelable });
      }, true);
    document.activeElement && document.activeElement.blur && document.activeElement.blur();
    const box = (e) => { const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; };
    return { field: box(field), cancel: box(cancel), guarded: box(guarded) };
    """

    static func run(_ webView: WKWebView, in window: NSWindow) async -> String {
        guard let places = try? await webView.callAsyncJavaScript(setUp, contentWorld: .page) as? [String: [Double]] else {
            return #"{"error":"the page did not take the fields"}"#
        }
        var result: [String: Any] = [:]
        for name in ["field", "cancel", "guarded"] {
            guard let place = places[name], place.count == 2 else { continue }
            _ = try? await webView.callAsyncJavaScript("window.__pbTaps = []", contentWorld: .page)
            let scale = webView.pageZoom * webView.magnification
            let inView = NSPoint(x: place[0] * scale, y: webView.isFlipped ? place[1] * scale : webView.bounds.height - place[1] * scale)
            let location = webView.convert(inView, to: nil)
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    switch type {
                    case .leftMouseDown: webView.mouseDown(with: event)
                    case .leftMouseUp: webView.mouseUp(with: event)
                    default: webView.mouseMoved(with: event)
                    }
                }
                try? await Task.sleep(nanoseconds: type == .leftMouseDown ? 90_000_000 : 40_000_000)
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            let heard = try? await webView.callAsyncJavaScript(
                "return { taps: window.__pbTaps, focused: document.activeElement ? document.activeElement.id : '' }", contentWorld: .page)
            result[name] = ["pressed": [Int(place[0].rounded()), Int(place[1].rounded())], "heard": heard ?? NSNull()]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
