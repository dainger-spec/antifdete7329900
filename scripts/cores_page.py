#!/usr/bin/env python3
"""What a page is told of the processor count (navigator.hardwareConcurrency), everywhere a site can
ask: the page, a dedicated worker made from a blob and one loaded from a URL, a shared worker, a
service worker, a frame of the same origin and one of another origin. Open the address it prints in
any browser (a Lumen profile, Safari); each visit prints one line here. Standard library only; it
listens on this Mac only and writes nothing to disk.

    python3 scripts/cores_page.py [--port 28300]

WebKit answers 4 on a machine with fewer than 8 cores and 8 from 8 cores up (NavigatorBase.cpp); a
real iPhone answers 4. The same JavaScript is served by scripts/selftest_proxy.py at /pb-cores.
"""
import argparse
import json
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# The page's script; REPORT is where it sends its result, CROSS the origin of the other-origin frame.
PAGE_SCRIPT = r"""
(async () => {
  const timeout = (ms) => new Promise((resolve) => setTimeout(() => resolve('timeout'), ms));
  const ask = (start) => Promise.race([new Promise(start), timeout(4000)]);
  const blob = (body) => URL.createObjectURL(new Blob([body], { type: 'text/javascript' }));
  const nativeText = (f) => { try { return Function.prototype.toString.call(f); } catch (e) { return 'error'; } };
  const getter = Object.getOwnPropertyDescriptor(Navigator.prototype, 'hardwareConcurrency').get;
  const r = {
    ua: navigator.userAgent, secure: isSecureContext, page: navigator.hardwareConcurrency,
    // As the engine prints a native accessor, and nothing of the page's own on navigator.
    getterNative: /^function (get )?hardwareConcurrency\(\) \{\s*\[native code\]\s*\}$/.test(nativeText(getter)),
    navigatorOwn: Object.getOwnPropertyNames(navigator).length,
  };
  const workerBody = "postMessage([navigator.hardwareConcurrency, /^function (get )?hardwareConcurrency\\(\\) \\{\\s*\\[native code\\]\\s*\\}$/.test(Function.prototype.toString.call(Object.getOwnPropertyDescriptor(WorkerNavigator.prototype, 'hardwareConcurrency').get))].join(' '))";
  try { r.blobWorker = await ask((ok) => { const w = new Worker(blob(workerBody)); w.onmessage = (e) => ok(e.data); w.onerror = () => ok('error'); }); } catch (e) { r.blobWorker = 'error ' + e; }
  try { r.urlWorker = await ask((ok) => { const w = new Worker('WORKER_URL'); w.onmessage = (e) => ok(e.data); w.onerror = () => ok('error'); }); } catch (e) { r.urlWorker = 'error ' + e; }
  try {
    r.nestedWorker = await ask((ok) => {
      const w = new Worker(blob("const inner = new Worker(URL.createObjectURL(new Blob(['postMessage(navigator.hardwareConcurrency)'], { type: 'text/javascript' }))); inner.onmessage = (e) => postMessage(e.data);"));
      w.onmessage = (e) => ok(e.data); w.onerror = () => ok('error');
    });
  } catch (e) { r.nestedWorker = 'error ' + e; }
  try {
    r.sharedWorker = typeof SharedWorker !== 'function' ? 'none' : await ask((ok) => {
      const s = new SharedWorker(blob('onconnect = (e) => e.ports[0].postMessage(navigator.hardwareConcurrency)'));
      s.port.onmessage = (e) => ok(e.data); s.port.start();
    });
  } catch (e) { r.sharedWorker = 'error ' + e; }
  try {
    r.serviceWorker = !navigator.serviceWorker ? 'none (not a secure context)' : await ask(async (ok) => {
      const registration = await navigator.serviceWorker.register('SW_URL');
      const worker = registration.active || registration.installing || registration.waiting;
      const send = (target) => { const channel = new MessageChannel(); channel.port1.onmessage = (e) => ok(e.data); target.postMessage('cores', [channel.port2]); };
      if (registration.active) send(registration.active);
      else worker.addEventListener('statechange', () => { if (worker.state === 'activated') send(worker); });
    });
  } catch (e) { r.serviceWorker = 'error ' + e; }
  const frame = (src) => ask((ok) => {
    const nonce = Math.random().toString(36).slice(2);
    addEventListener('message', (e) => { if (e.data && e.data.nonce === nonce) ok(e.data.cores); });
    const f = document.createElement('iframe');
    f.src = src + (src.includes('?') ? '&' : '?') + 'nonce=' + nonce;
    f.style.cssText = 'width:1px;height:1px;border:0';
    document.body.appendChild(f);
  });
  try { r.sameOriginFrame = await frame('FRAME_URL'); } catch (e) { r.sameOriginFrame = 'error ' + e; }
  try { r.otherOriginFrame = await frame('CROSS' + 'FRAME_URL'); } catch (e) { r.otherOriginFrame = 'error ' + e; }
  // A frame without a document of its own (about:blank): the page's script reaches into it.
  try { const f = document.createElement('iframe'); document.body.appendChild(f); r.blankFrame = f.contentWindow.navigator.hardwareConcurrency; } catch (e) { r.blankFrame = 'error ' + e; }
  document.getElementById('out').textContent = JSON.stringify(r, null, 1);
  await fetch('REPORT' + encodeURIComponent(JSON.stringify(r)), { cache: 'no-store' });
  document.title = 'cores reported';
})();
"""

FRAME_SCRIPT = "parent.postMessage({ nonce: new URLSearchParams(location.search).get('nonce'), cores: navigator.hardwareConcurrency }, '*');"
SW_SCRIPT = ("self.addEventListener('install', () => self.skipWaiting());"
             "self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));"
             "self.addEventListener('message', (e) => e.ports[0].postMessage(navigator.hardwareConcurrency));")
URL_WORKER_SCRIPT = (r"postMessage([navigator.hardwareConcurrency, /^function (get )?hardwareConcurrency\(\) \{\s*\[native code\]\s*\}$/"
                     r".test(Function.prototype.toString.call(Object.getOwnPropertyDescriptor(WorkerNavigator.prototype, 'hardwareConcurrency').get))].join(' '))")


def page_html(report: str, cross_origin: str, base: str) -> str:
    script = (PAGE_SCRIPT.replace("WORKER_URL", base + "/worker.js").replace("SW_URL", base + "/sw.js")
              .replace("FRAME_URL", base + "/frame").replace("CROSS", cross_origin).replace("REPORT", report))
    return ("<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width'>"
            "<title>cores</title></head><body><p>hardwareConcurrency, everywhere a site can ask:</p>"
            "<pre id=out>measuring…</pre><script>" + script + "</script></body></html>")


def summary(r: dict) -> str:
    ua = r.get("ua", "")
    kind = "iPhone" if "iPhone" in ua else "iPad" if "iPad" in ua else "Mac" if "Macintosh" in ua else "?"
    keys = ["page", "blobWorker", "urlWorker", "nestedWorker", "sharedWorker", "serviceWorker",
            "sameOriginFrame", "otherOriginFrame", "blankFrame"]
    return (f"{kind:6} " + "  ".join(f"{k}={r.get(k)}" for k in keys)
            + f"  getterNative={r.get('getterNative')} navigatorOwn={r.get('navigatorOwn')} secure={r.get('secure')}"
            + f"\n       UA: {ua}")


class Handler(BaseHTTPRequestHandler):
    port = 28300

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
        if url.path == "/":
            html = page_html("/report?data=", f"http://localhost:{self.port}", "")
            self.send(html.encode(), "text/html; charset=utf-8")
        elif url.path == "/worker.js":
            self.send(URL_WORKER_SCRIPT.encode(), "text/javascript")
        elif url.path == "/sw.js":
            self.send(SW_SCRIPT.encode(), "text/javascript")
        elif url.path == "/frame":
            self.send(("<!doctype html><script>" + FRAME_SCRIPT + "</script>").encode(), "text/html; charset=utf-8")
        elif url.path == "/report":
            try:
                report = json.loads(parse_qs(url.query).get("data", ["{}"])[0])
                print(summary(report), flush=True)
            except ValueError:
                print("an unreadable report", flush=True)
            self.send(b"ok", "text/plain")
        else:
            self.send_error(404)


class DualStackServer(ThreadingHTTPServer):
    # "localhost" (the other-origin frame) may be ::1 first.
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=28300)
    arguments = parser.parse_args()
    Handler.port = arguments.port
    try:
        server = DualStackServer(("::", arguments.port), Handler)
    except OSError:  # no IPv6 here: IPv4 loopback only
        server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    # Loopback only: refuse anyone else.
    server.verify_request = lambda request, address: address[0] in ("::1", "::ffff:127.0.0.1", "127.0.0.1")
    print(f"Open http://127.0.0.1:{arguments.port}/ in each browser to compare (Ctrl-C to stop).", flush=True)
    print(f"This Mac: {__import__('os').cpu_count()} cores.", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
