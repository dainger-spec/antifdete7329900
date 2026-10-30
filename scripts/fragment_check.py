#!/usr/bin/env python3
"""Does a jump to a fragment of the page shown stay in the same document — in this Mac's Safari
and in a profile?

    python3 scripts/fragment_check.py --app build/unsandboxed/PrivacyBrowser.app

On macOS 27.0.1 (WebKit 22625) the self-test found its web views making a new document of a
jump to `#fragment` — an anchor clicked, `location.hash` set, the app loading `page#fragment` —
where macOS 26 keeps the page (CI runs 432 and 433). This asks the same of the real Safari and of
a profile as it ships, in this app's window and in Safari's window (`PrivacyBrowser
--payments-check`, the variants `shipped` and `shipped-safari-window`).

One page, on 127.0.0.1 over HTTP. Its own script, as soon as it loads: a mark on the document
(a global) and in the tab's session storage, then `location.hash = 'jump'`. If its `hashchange`
comes in the same document (the global is still there), it reports `same document`; if a new
document loads instead (the session storage remembers the jump, the global is gone), that one
reports `new document`. Nothing is evaluated into the page from outside.

Prints one FRAGMENT line per side. Exit 0 when every side reported, 1 otherwise; the answers
themselves are a measurement, not a verdict.
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VARIANTS = ["shipped", "shipped-safari-window"]

PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8"><title>Fragment jump</title></head>
<body><p id="state">Measuring…</p>
<script>
(function () {
  const side = new URLSearchParams(location.search).get('side') || '?';
  const key = 'pbFragmentJump:' + side;
  const report = (result) => {
    fetch('/report?side=' + encodeURIComponent(side), { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ side: side, result: result, href: location.href, historyLength: history.length }) });
    document.getElementById('state').textContent = 'Done: ' + result + '. This page can be closed.';
  };
  let stage = null;
  try { stage = sessionStorage.getItem(key); } catch (e) {}
  if (stage === 'jumped') {
    try { sessionStorage.removeItem(key); } catch (e) {}
    report('new document');
    return;
  }
  window.__pbFragmentMark = 'here';
  try { sessionStorage.setItem(key, 'jumped'); } catch (e) {}
  addEventListener('hashchange', () => {
    try { sessionStorage.removeItem(key); } catch (e) {}
    report(window.__pbFragmentMark === 'here' ? 'same document' : 'hashchange in another document');
  });
  setTimeout(() => { location.hash = 'jump'; }, 300);
})();
</script></body></html>
"""


def log(message):
    print(message, flush=True)


class Pages:
    def __init__(self):
        self.reports = {}
        self.lock = threading.Lock()
        pages = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send(self, status, body, content_type="text/plain; charset=utf-8"):
                data = body.encode()
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def allowed(self):
                return self.headers.get("Host", "") in (f"127.0.0.1:{pages.port}", f"localhost:{pages.port}")

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                if not self.allowed():
                    return self.send(404, "")
                if url.path == "/page":
                    return self.send(200, PAGE, "text/html; charset=utf-8")
                if url.path == "/reported":
                    side = urllib.parse.parse_qs(url.query).get("side", [""])[0]
                    with pages.lock:
                        return self.send(200, "yes" if side in pages.reports else "no")
                return self.send(404, "")

            def do_POST(self):
                url = urllib.parse.urlparse(self.path)
                side = urllib.parse.parse_qs(url.query).get("side", [""])[0]
                body = self.rfile.read(min(int(self.headers.get("Content-Length", "0") or 0), 65536))
                if not self.allowed() or url.path != "/report" or not side:
                    return self.send(404, "")
                try:
                    report = json.loads(body)
                except ValueError:
                    return self.send(400, "")
                with pages.lock:
                    pages.reports.setdefault(side, report)
                return self.send(200, "ok")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def url(self, side):
        return f"http://127.0.0.1:{self.port}/page?side={urllib.parse.quote(side)}"

    def wait(self, side, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if side in self.reports:
                    return self.reports[side]
            time.sleep(0.3)
        return None


def describe(report):
    if not report:
        return "no report"
    return f"{report.get('result')} (at {report.get('href')}, history length {report.get('historyLength')})"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0].replace("\n", " "))
    parser.add_argument("--app", required=True, help="PrivacyBrowser.app, the build without the App Sandbox")
    parser.add_argument("--no-safari", action="store_true")
    options = parser.parse_args()
    executable = os.path.join(options.app, "Contents", "MacOS", "PrivacyBrowser")
    pages = Pages()
    missing = []
    if not options.no_safari:
        subprocess.run(["open", "-b", "com.apple.Safari", pages.url("safari")])
        log("FRAGMENT safari: " + describe(pages.wait("safari", 60)))
        if "safari" not in pages.reports:
            missing.append("safari")
    for variant in VARIANTS:
        try:
            result = subprocess.run([executable, "--payments-check", "--url", pages.url(variant), "--variant", variant],
                                    capture_output=True, text=True, timeout=300)
            for line in result.stdout.splitlines():
                if line.startswith("PAYMENTS-CHECK") and "reported" not in line:
                    log(line)
        except subprocess.TimeoutExpired:
            log(f"FRAGMENT {variant}: the app did not finish within 300 s")
        log(f"FRAGMENT {variant}: " + describe(pages.wait(variant, 1)))
        if variant not in pages.reports:
            missing.append(variant)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
