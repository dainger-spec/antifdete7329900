#!/usr/bin/env python3
"""What a page sees of the device it runs on, for a phone and for the browsers that say they are one:
the platform, touch, the pointer, the screen and its density, and what follows from them (the window's
sizes, visualViewport, orientation, media queries, safe areas, sensors, and what only a Mac or only an
iPhone has); and what one tap on the page brings it, event by event. Open the address it prints on the
iPhone (the same Wi-Fi as this Mac), in Safari on this Mac, and in a Lumen mobile view; each visit
prints a report here. Standard library only; it writes nothing to disk.

    python3 scripts/phone_page.py [--port 28310] [--lan]

Without --lan it listens on this Mac only (127.0.0.1). With --lan it listens on the local network so
that the iPhone can reach it, and answers only addresses that carry the random key it prints; the
page asks for nothing personal (no location, no camera, no permission prompt) and sends only what is
listed in its script.
"""
import argparse
import json
import secrets
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PAGE_SCRIPT = r"""
(() => {
  const r = {};
  const mq = (q) => { try { return matchMedia(q).matches; } catch (e) { return 'error'; } };
  const has = (o, n) => { try { return n in o; } catch (e) { return 'error'; } };
  const type = (n) => typeof window[n];
  const nativeText = (f) => { try { return /\{\s*\[native code\]\s*\}$/.test(Function.prototype.toString.call(f)); } catch (e) { return 'error'; } };
  const getterNative = (proto, name) => {
    let o = proto;
    while (o && !Object.prototype.hasOwnProperty.call(o, name)) o = Object.getPrototypeOf(o);
    if (!o) return 'absent';
    const d = Object.getOwnPropertyDescriptor(o, name);
    return d.get ? nativeText(d.get) : 'value';
  };
  const n = navigator, s = screen;
  r.ua = n.userAgent;
  r.navigator = { platform: n.platform, maxTouchPoints: n.maxTouchPoints, hardwareConcurrency: n.hardwareConcurrency,
    vendor: n.vendor, standalone: has(n, 'standalone') ? n.standalone : 'absent', webdriver: n.webdriver,
    pdfViewerEnabled: n.pdfViewerEnabled, plugins: n.plugins ? n.plugins.length : 'absent', mimeTypes: n.mimeTypes ? n.mimeTypes.length : 'absent',
    userAgentData: has(n, 'userAgentData'), vibrate: typeof n.vibrate, share: typeof n.share, getBattery: typeof n.getBattery,
    ownProperties: Object.getOwnPropertyNames(n).length };
  r.touch = { ontouchstartWindow: has(window, 'ontouchstart'), ontouchstartDocument: has(document, 'ontouchstart'),
    ontouchstartElement: has(HTMLElement.prototype, 'ontouchstart'), ontouchend: has(window, 'ontouchend'),
    ontouchmove: has(window, 'ontouchmove'), ontouchcancel: has(window, 'ontouchcancel'),
    TouchEvent: type('TouchEvent'), Touch: type('Touch'), TouchList: type('TouchList'),
    createTouchEvent: (() => { try { document.createEvent('TouchEvent'); return 'ok'; } catch (e) { return e.name; } })(),
    ongesturestart: has(window, 'ongesturestart'), ongesturechange: has(window, 'ongesturechange'), GestureEvent: type('GestureEvent'),
    PointerEvent: type('PointerEvent'), onpointerdown: has(window, 'onpointerdown') };
  r.media = {};
  for (const q of ['(pointer: coarse)', '(pointer: fine)', '(pointer: none)', '(any-pointer: coarse)', '(any-pointer: fine)',
                   '(hover: hover)', '(hover: none)', '(any-hover: hover)', '(any-hover: none)',
                   '(orientation: portrait)', '(orientation: landscape)', '(display-mode: browser)', '(display-mode: standalone)',
                   '(prefers-color-scheme: dark)', '(color-gamut: p3)', '(dynamic-range: high)', '(update: fast)',
                   '(prefers-reduced-motion: reduce)', '(inverted-colors: inverted)', '(prefers-contrast: more)',
                   '(-webkit-min-device-pixel-ratio: 2)', '(-webkit-min-device-pixel-ratio: 3)', '(resolution: 2dppx)', '(resolution: 3dppx)',
                   '(-webkit-touch-callout: default)', '(-webkit-touch-callout: none)', '(scripting: enabled)', '(forced-colors: active)'])
    r.media[q] = mq(q);
  // CSS device-width as the page's media queries see it, by search.
  const deviceWidth = (() => { for (let w = 200; w <= 4000; w++) if (mq('(device-width: ' + w + 'px)')) return w; return 'none'; })();
  const deviceHeight = (() => { for (let h = 200; h <= 4000; h++) if (mq('(device-height: ' + h + 'px)')) return h; return 'none'; })();
  r.screen = { width: s.width, height: s.height, availWidth: s.availWidth, availHeight: s.availHeight,
    availLeft: s.availLeft, availTop: s.availTop, colorDepth: s.colorDepth, pixelDepth: s.pixelDepth,
    devicePixelRatio: window.devicePixelRatio, cssDeviceWidth: deviceWidth, cssDeviceHeight: deviceHeight,
    orientation: s.orientation ? { type: s.orientation.type, angle: s.orientation.angle, lock: typeof s.orientation.lock } : 'absent',
    windowOrientation: has(window, 'orientation') ? window.orientation : 'absent', onorientationchange: has(window, 'onorientationchange') };
  const de = document.documentElement, vv = window.visualViewport;
  r.window = { innerWidth, innerHeight, outerWidth, outerHeight, screenX, screenY, screenLeft: window.screenLeft, screenTop: window.screenTop,
    clientWidth: de.clientWidth, clientHeight: de.clientHeight, scrollbarWidth: innerWidth - de.clientWidth,
    visualViewport: vv ? { width: vv.width, height: vv.height, scale: vv.scale, offsetLeft: vv.offsetLeft, offsetTop: vv.offsetTop,
                           pageLeft: vv.pageLeft, pageTop: vv.pageTop } : 'absent' };
  const probe = document.createElement('div');
  probe.style.cssText = 'position:fixed;top:0;left:0;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom);padding-left:env(safe-area-inset-left);padding-right:env(safe-area-inset-right)';
  document.body.appendChild(probe);
  const cs = getComputedStyle(probe);
  r.safeArea = { top: cs.paddingTop, bottom: cs.paddingBottom, left: cs.paddingLeft, right: cs.paddingRight };
  probe.remove();
  r.platformOnly = {
    // iOS only
    DeviceMotionRequestPermission: typeof (window.DeviceMotionEvent && DeviceMotionEvent.requestPermission),
    DeviceOrientationRequestPermission: typeof (window.DeviceOrientationEvent && DeviceOrientationEvent.requestPermission),
    ondevicemotion: has(window, 'ondevicemotion'), ondeviceorientation: has(window, 'ondeviceorientation'),
    // the Mac only, or not on an iPhone's Safari
    onwebkitmouseforcedown: has(window, 'onwebkitmouseforcedown'), WebKitMouseForceEvent: type('WebKitMouseForceEvent'),
    MouseEventForceAtMouseDown: has(window, 'MouseEvent') && has(MouseEvent, 'WEBKIT_FORCE_AT_MOUSE_DOWN'),
    safari: type('safari'), Notification: type('Notification'), PushManager: type('PushManager'),
    fullscreenEnabled: document.fullscreenEnabled, webkitFullscreenEnabled: document.webkitFullscreenEnabled,
    requestFullscreen: typeof Element.prototype.requestFullscreen, ApplePaySession: type('ApplePaySession'),
    showOpenFilePicker: type('showOpenFilePicker'), EyeDropper: type('EyeDropper'),
    speechVoices: (window.speechSynthesis ? speechSynthesis.getVoices().length : 'absent'),
    MediaSource: type('MediaSource'), ManagedMediaSource: type('ManagedMediaSource'),
    webkitConvertPointFromNodeToPage: type('webkitConvertPointFromNodeToPage'),
    onselectstart: has(document, 'onselectstart'), onwebkitplaybacktargetavailabilitychanged: has(HTMLVideoElement.prototype, 'onwebkitplaybacktargetavailabilitychanged'),
    pictureInPictureEnabled: document.pictureInPictureEnabled };
  // Do the accessors a page reads look as the engine makes them?
  r.natives = {};
  for (const [label, proto, name] of [['Navigator.platform', Navigator.prototype, 'platform'], ['Navigator.maxTouchPoints', Navigator.prototype, 'maxTouchPoints'],
      ['Navigator.hardwareConcurrency', Navigator.prototype, 'hardwareConcurrency'], ['Navigator.standalone', Navigator.prototype, 'standalone'],
      ['Screen.width', Screen.prototype, 'width'], ['Screen.height', Screen.prototype, 'height'], ['Screen.availHeight', Screen.prototype, 'availHeight'],
      ['window.devicePixelRatio', window, 'devicePixelRatio'], ['window.outerWidth', window, 'outerWidth'], ['window.orientation', window, 'orientation'],
      ['window.ontouchstart', window, 'ontouchstart']])
    r.natives[label] = getterNative(proto, name);
  r.natives.matchMedia = nativeText(window.matchMedia);
  r.natives.windowOwnProperties = Object.getOwnPropertyNames(window).length;
  window.__pbStatic = r;
  document.getElementById('static').textContent = JSON.stringify(r, null, 1);

  // One tap on the pad: every event it brings, in order, with what a page reads of each.
  const events = [];
  const t0 = performance.now();
  const pad = document.getElementById('pad');
  const kinds = ['touchstart', 'touchmove', 'touchend', 'touchcancel', 'pointerover', 'pointerenter', 'pointerdown', 'pointermove', 'pointerup',
                 'pointercancel', 'pointerout', 'pointerleave', 'gotpointercapture', 'lostpointercapture', 'mouseover', 'mouseenter', 'mousemove',
                 'mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'gesturestart', 'gesturechange', 'gestureend',
                 'webkitmouseforcewillbegin', 'webkitmouseforcedown', 'webkitmouseforceup', 'webkitmouseforcechanged', 'wheel', 'focus', 'selectstart'];
  for (const k of kinds) pad.addEventListener(k, (e) => {
    const x = { type: e.type, ms: Math.round(performance.now() - t0), trusted: e.isTrusted, cancelable: e.cancelable, detail: e.detail };
    if ('pointerType' in e) Object.assign(x, { pointerType: e.pointerType, isPrimary: e.isPrimary, w: e.width, h: e.height, pressure: e.pressure,
                                               tiltX: e.tiltX, twist: e.twist, pointerId: e.pointerId });
    if (e.touches) { const t = e.changedTouches && e.changedTouches[0];
      Object.assign(x, { touches: e.touches.length, radiusX: t && t.radiusX, radiusY: t && t.radiusY, force: t && t.force, touchType: t && t.touchType }); }
    if ('button' in e) Object.assign(x, { button: e.button, buttons: e.buttons });
    if ('webkitForce' in e && e.type.startsWith('mouse')) x.webkitForce = e.webkitForce;
    if ('scale' in e && e.type.startsWith('gesture')) x.scale = e.scale;
    events.push(x);
  }, { passive: true });
  document.getElementById('send').addEventListener('click', async () => {
    const report = Object.assign({}, window.__pbStatic, { tap: events.slice() });
    await fetch('REPORT' + encodeURIComponent(JSON.stringify(report)), { cache: 'no-store' });
    document.getElementById('sent').textContent = 'sent: ' + events.length + ' events';
  });
  fetch('REPORT' + encodeURIComponent(JSON.stringify(r)), { cache: 'no-store' });
})();
"""


def page_html(report: str) -> str:
    return ("<!doctype html><html><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width, initial-scale=1, viewport-fit=cover'>"
            "<title>phone</title><style>body{font:14px -apple-system,sans-serif;margin:12px}"
            "#pad{height:160px;border-radius:16px;background:#2b6;color:#fff;display:flex;align-items:center;justify-content:center;"
            "font-size:20px;user-select:none;-webkit-user-select:none}#send{margin:12px 0;font-size:18px;padding:10px 16px}"
            "pre{white-space:pre-wrap;font-size:11px}</style></head><body>"
            "<p>1. Tap the green area once (one finger, or one click). 2. Press Send.</p>"
            "<div id=pad>tap here once</div><button id=send>Send</button> <span id=sent></span>"
            "<pre id=static>measuring…</pre><script>" + PAGE_SCRIPT.replace("REPORT", report) + "</script></body></html>")


def summary(r: dict) -> str:
    ua = r.get("ua", "")
    kind = "iPhone" if "iPhone" in ua else "iPad" if "iPad" in ua else "Mac" if "Macintosh" in ua else "?"
    lines = [f"===== {kind} — {'with the tap' if 'tap' in r else 'static'}", f"UA: {ua}"]
    for key in ("navigator", "touch", "screen", "window", "safeArea", "platformOnly", "natives"):
        lines.append(f"{key}: {json.dumps(r.get(key), sort_keys=True)}")
    lines.append("media: " + ", ".join(q for q, v in (r.get("media") or {}).items() if v is True))
    for event in r.get("tap", []):
        lines.append("tap: " + json.dumps(event, sort_keys=True))
    return "\n".join(lines)


class Handler(BaseHTTPRequestHandler):
    key = ""

    def log_message(self, *args):
        pass

    def send(self, body: bytes, kind: str):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        base = f"/{self.key}"
        if url.path in (base, base + "/"):
            self.send(page_html(base + "/report?data=").encode(), "text/html; charset=utf-8")
        elif url.path == base + "/report":
            try:
                print(summary(json.loads(parse_qs(url.query).get("data", ["{}"])[0])), flush=True)
            except ValueError:
                print("an unreadable report", flush=True)
            self.send(b"ok", "text/plain")
        else:
            self.send_error(404)


def lan_address() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))  # no packet is sent: this only picks the interface
        return probe.getsockname()[0]
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=28310)
    parser.add_argument("--lan", action="store_true")
    parser.add_argument("--key", help="the path's key (default: a random one)")
    arguments = parser.parse_args()
    Handler.key = arguments.key or secrets.token_urlsafe(9)
    host = "0.0.0.0" if arguments.lan else "127.0.0.1"
    server = ThreadingHTTPServer((host, arguments.port), Handler)
    where = lan_address() if arguments.lan else "127.0.0.1"
    print(f"Open http://{where}:{arguments.port}/{Handler.key} — on the iPhone (same Wi-Fi), in Safari here and in a Lumen mobile view."
          " Tap the green area once, then Send. Ctrl-C to stop.", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
