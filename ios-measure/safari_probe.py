#!/usr/bin/env python3
"""What Safari with no extension at all (a fresh iOS simulator's) has as `window.browser`.

The owner's Safari has a window property `browser` that the app's web view has not (950 names
against 949 on the iPhone, 8 November). Is it Safari's own, or an installed Safari extension's? A
simulator's Safari has no extension, so: if it has `browser` too, the property is the platform's; if
not, it came with something installed on the owner's iPhone. The page is read as the owner's
reference was: plain http on this Mac's network address, not a secure context.

    python3 ios-measure/safari_probe.py <address> <port> <out-dir>   (serves until killed)
    -> <out-dir>/report-<tag>.json for every page load that reports (?tag=...)
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = """<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width">
<title>browser probe</title></head><body><pre id=s>…</pre><script>
(async () => {
  const r = { ua: navigator.userAgent, secure: window.isSecureContext, href: location.href };
  const names = Object.getOwnPropertyNames(window).sort();
  r.windowOwnCount = names.length;
  r.windowNames = names;
  r.hasBrowser = 'browser' in window;
  r.typeofBrowser = typeof window.browser;
  r.typeofChrome = typeof window.chrome;
  r.typeofSafari = typeof window.safari;
  r.typeofModel = typeof window.HTMLModelElement;
  const d = Object.getOwnPropertyDescriptor(window, 'browser');
  r.browserDescriptor = d ? { value: 'value' in d, get: !!d.get, set: !!d.set, configurable: d.configurable,
                              enumerable: d.enumerable, writable: d.writable,
                              getter: d.get ? String(d.get) : null } : null;
  try {
    const b = window.browser;
    if (b !== undefined && b !== null) {
      r.browserTag = Object.prototype.toString.call(b);
      const chain = []; let o = b;
      while (o && chain.length < 6) { chain.push(Object.getOwnPropertyNames(o).sort()); o = Object.getPrototypeOf(o); }
      r.browserChain = chain;
      if (b.runtime) {
        const rt = []; let p = b.runtime;
        while (p && rt.length < 6) { rt.push(Object.getOwnPropertyNames(p).sort()); p = Object.getPrototypeOf(p); }
        r.runtimeChain = rt;
        try { r.runtimeId = String(b.runtime.id); } catch (e) { r.runtimeId = 'error: ' + e; }
      }
    }
  } catch (e) { r.browserError = String(e); }
  document.getElementById('s').textContent = 'browser: ' + r.typeofBrowser + ', names ' + names.length;
  const tag = new URLSearchParams(location.search).get('tag') || 'x';
  await fetch('/report?tag=' + encodeURIComponent(tag), { method: 'POST', body: JSON.stringify(r) });
  document.getElementById('s').textContent += ' — sent';
})();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length)
        tag = "".join(ch for ch in self.path.split("tag=")[-1] if ch.isalnum() or ch in "-_") or "x"
        with open(os.path.join(OUT, f"report-{tag}.json"), "wb") as f:
            f.write(data)
        print(f"report {tag}: {len(data)} bytes", flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    address, port, OUT = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    os.makedirs(OUT, exist_ok=True)
    ThreadingHTTPServer((address, port), Handler).serve_forever()
