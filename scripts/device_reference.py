#!/usr/bin/env python3
"""Measures Safari on a real iPhone or iPad, for a mobile generation to be set from the device.

    python3 scripts/device_reference.py --name iphone-ios26
    # On the device (same network): open the printed https://<this Mac>:<port>/ in Safari, accept
    # the certificate warning once, and keep the page in view until it reads "sent".

The page runs Resources/fingerprint_probe.js, as safari_reference.py does in the Mac's Safari, and
adds what only the device can tell:
- the viewport Safari leaves a page: inner sizes at load, and again after scrolling, once Safari's
  bars have settled;
- the outer sizes and screen position;
- the pixel ratio and the media queries that follow it;
- orientation, pointer and hover, and device-width;
- the navigator a worker sees.

The script writes the result to scripts/reference/<name>.json. It prints the values a mobile
generation declares (PrivacyScripts: the device's screen, pixel ratio and deviceViewportSize) next
to the device's, so the estimates there can be replaced with what the device measured.

HTTPS with a certificate made for this run (openssl): APIs Safari exposes only in a secure context
then read as they do on a real site.
"""
import argparse
import http.server
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PROBE = os.path.join(ROOT, "Resources", "fingerprint_probe.js")
REFERENCE_DIR = os.path.join(ROOT, "scripts", "reference")

# What PrivacyScripts declares for each mobile generation (keep in step with shimConfiguration and
# deviceViewportSize; the self-test checks the profile against these).
DECLARED = {
    "iphone": {"screen": "390x844", "pixelRatio": 3, "viewport": "390x739"},
    "ipad": {"screen": "820x1180", "pixelRatio": 2, "viewport": "820x1106"},
}

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>PB device reference</title></head>
<body style="font: 17px -apple-system, sans-serif; margin: 16px">
<p id="status">Measuring… keep this page in view.</p>
<div style="height: 3000px"></div>
<script>
const probe = function () {
__PROBE__
};
const sizes = () => ({
  inner: innerWidth + 'x' + innerHeight,
  outer: outerWidth + 'x' + outerHeight,
  screenPosition: screenX + ',' + screenY,
  visualViewport: window.visualViewport ? Math.round(visualViewport.width) + 'x' + Math.round(visualViewport.height) : 'none',
  documentClient: document.documentElement.clientWidth + 'x' + document.documentElement.clientHeight,
});
(async () => {
  const out = { atLoad: sizes() };
  try { out.probe = probe(); } catch (e) { out.probe = { error: String(e) }; }
  const media = (query) => matchMedia(query).matches;
  out.media = {
    resolution: [1, 2, 3].filter((r) => media('(resolution: ' + r + 'dppx)')),
    pointerCoarse: media('(pointer: coarse)'), pointerFine: media('(pointer: fine)'),
    hoverNone: media('(hover: none)'), portrait: media('(orientation: portrait)'),
    deviceWidth: [320, 375, 390, 393, 402, 414, 428, 430, 440, 744, 768, 810, 820, 834, 1024]
      .filter((w) => media('(device-width: ' + w + 'px)')),
  };
  out.worker = await new Promise((resolve) => {
    const code = "postMessage([navigator.platform, navigator.hardwareConcurrency, navigator.userAgent].join('|'))";
    const worker = new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
    worker.onmessage = (e) => resolve(String(e.data));
    worker.onerror = () => resolve('error');
    setTimeout(() => resolve('timeout'), 3000);
  });
  window.scrollTo(0, 400);
  await new Promise((resolve) => setTimeout(resolve, 2000));
  out.afterScroll = sizes();
  const response = await fetch('result?name=' + encodeURIComponent(__NAME__), { method: 'POST', body: JSON.stringify(out) });
  document.getElementById('status').textContent = response.ok ? 'sent' : 'not sent: ' + response.status;
})();
</script></body></html>
"""


def lan_address():
    """This Mac's address on the network the device reaches it over (no packet is sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.connect(("192.0.2.1", 9))
            return sock.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def certificate(directory, host):
    key, cert = os.path.join(directory, "key.pem"), os.path.join(directory, "cert.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=pb-device-reference", "-addext", f"subjectAltName=IP:{host}",
                    "-keyout", key, "-out", cert], check=True, capture_output=True)
    return cert, key


def summary(name, result):
    kind = "ipad" if "ipad" in name.lower() else "iphone"
    declared = DECLARED[kind]
    probe = result.get("probe", {})
    screen = str(probe.get("screen", "?")).split("x")
    print(f"DEVICE-REFERENCE [{name}] UA {probe.get('ua')}")
    print(f"  screen {'x'.join(screen[:2])} (declared {declared['screen']}), pixel ratio "
          f"{screen[4] if len(screen) > 4 else '?'} (declared {declared['pixelRatio']})")
    print(f"  viewport at load {result.get('atLoad', {}).get('inner')}, after scrolling "
          f"{result.get('afterScroll', {}).get('inner')} (declared {declared['viewport']})")
    print(f"  outer {result.get('atLoad', {}).get('outer')}, screen position {result.get('atLoad', {}).get('screenPosition')}")
    print(f"  media {json.dumps(result.get('media'))}")
    print(f"  worker {result.get('worker')}")
    features = probe.get("features", {})
    for key in ["MediaSource", "ManagedMediaSource", "Notification", "document.fullscreenEnabled",
                "Element.prototype.webkitRequestFullscreen", "PushManager", "ApplePaySession", "window.ontouchstart"]:
        print(f"  features.{key} = {features.get(key)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", required=True, help="reference name, e.g. iphone-ios26 or ipad-ipados26")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--probe", default=PROBE)
    args = parser.parse_args()
    if not all(c.isalnum() or c in "-_." for c in args.name):
        parser.error("--name: letters, digits, '-', '_' and '.' only")

    with open(args.probe, encoding="utf-8") as handle:
        page = PAGE.replace("__PROBE__", handle.read()).replace("__NAME__", json.dumps(args.name)).encode()
    os.makedirs(REFERENCE_DIR, exist_ok=True)
    done = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(page)

        def do_POST(self):
            length = min(int(self.headers.get("Content-Length") or 0), 4 * 1024 * 1024)
            body = self.rfile.read(length)
            try:
                result = json.loads(body)
            except ValueError:
                self.send_response(400)
                self.end_headers()
                return
            path = os.path.join(REFERENCE_DIR, args.name + ".json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(result, handle, indent=1, sort_keys=True)
            self.send_response(204)
            self.end_headers()
            summary(args.name, result)
            print(f"DEVICE-REFERENCE written: {os.path.relpath(path, ROOT)}")
            done.set()

        def log_message(self, *_):
            pass

    host = lan_address()
    with tempfile.TemporaryDirectory(prefix="pb-device-reference-") as directory:
        cert, key = certificate(directory, host)
        server = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f"Open https://{host}:{args.port}/ in Safari on the device (accept the certificate warning once).")
        try:
            done.wait()
        except KeyboardInterrupt:
            return 1
        finally:
            server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
