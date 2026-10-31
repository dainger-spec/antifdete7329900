#!/usr/bin/env python3
"""A measurement (never merged): what a page sees in the real Safari and in this app's plain web view.

    page_probe.py --app build/unsandboxed/PrivacyBrowser.app --out build/measure/page \
        --features "TrustedTypesEnabled=on,MutationEventsEnabled=off"

One page, from a server on 127.0.0.1, loaded by each visitor as /probe?who=<visitor>; it posts what it
sees to /report: the window's own properties by name, typeof trustedTypes and MutationEvent, whether a
Trusted Types policy makes a TrustedHTML, whether `new FontFaceSet([])` constructs, and how many
DOMNodeInserted events an insertion fires. The visitors: the real Safari (open -a Safari), then the
app's `--sdk-check --url=` as built, with the features given (`--measure-feature`), and with every
SDK behavior on (`--everything`). Each is compared with the real Safari, and with one another.
"""
import argparse
import http.server
import json
import os
import subprocess
import threading
import time
import urllib.parse

BINARY = "Contents/MacOS/PrivacyBrowser"

PAGE = """<!doctype html><meta charset=utf-8><title>probe</title><p id=p>x</p>
<script>
(async () => {
  const r = {};
  r.who = new URLSearchParams(location.search).get('who');
  r.userAgent = navigator.userAgent;
  r.isSecureContext = isSecureContext;
  r.names = Object.getOwnPropertyNames(window).sort();
  r.trustedTypes = typeof trustedTypes;
  r.MutationEvent = typeof MutationEvent;
  try { new FontFaceSet([]); r.fontFaceSetConstructor = 'constructs'; }
  catch (e) { r.fontFaceSetConstructor = e.name + ': ' + e.message; }
  try {
    const box = document.createElement('div');
    document.body.appendChild(box);
    let fired = 0;
    box.addEventListener('DOMNodeInserted', () => { fired++; });
    box.appendChild(document.createElement('span'));
    r.mutationEventsFired = fired;
  } catch (e) { r.mutationEventsFired = 'error ' + e.name; }
  try {
    const policy = trustedTypes.createPolicy('pb', { createHTML: s => s });
    r.trustedTypesPolicy = Object.prototype.toString.call(policy.createHTML('<b>x</b>'));
  } catch (e) { r.trustedTypesPolicy = e.name; }
  await fetch('/report?who=' + encodeURIComponent(r.who), { method: 'POST', body: JSON.stringify(r) });
  document.title = 'reported';
})();
</script>"""


class Server:
    def __init__(self):
        self.reports = {}
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
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
                who = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("who", ["?"])[0]
                try:
                    outer.reports[who] = json.loads(data)
                except ValueError:
                    outer.reports[who] = {"raw": data[:300].decode(errors="replace")}
                self.send_response(204)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self, who):
        return f"http://127.0.0.1:{self.port}/probe?who={urllib.parse.quote(who)}"

    def wait_for(self, who, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if who in self.reports:
                return self.reports[who]
            time.sleep(0.5)
        return None


def visit_safari(server, out):
    opened = subprocess.run(["open", "-a", "Safari", server.url("safari")], capture_output=True, text=True, timeout=60)
    report = server.wait_for("safari", 90)
    subprocess.run(["killall", "Safari"], capture_output=True)
    with open(os.path.join(out, "safari-open.txt"), "w") as handle:
        handle.write(f"open: {opened.returncode} {opened.stdout} {opened.stderr}\n")
    return report


def visit_app(server, app, who, extra, out):
    command = [os.path.join(app, BINARY), "--sdk-check", f"--url={server.url(who)}", *extra]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        output = result.stdout + result.stderr
    except subprocess.TimeoutExpired as expired:
        output = str(expired.stdout or "") + "\n(timed out)"
    with open(os.path.join(out, f"app-{who}.txt"), "w") as handle:
        handle.write(" ".join(command) + "\n" + output)
    for line in output.splitlines():
        if line.startswith(("SDK-CHECK built", "SDK-CHECK _set", "INFO measure")):
            print(f"PAGE-PROBE {who}: {line}", flush=True)
    return server.wait_for(who, 10)


def describe(who, report):
    if not report:
        print(f"PAGE-PROBE {who}: no report", flush=True)
        return
    if "names" not in report:
        print(f"PAGE-PROBE {who}: {report}", flush=True)
        return
    fields = {key: report.get(key) for key in ("isSecureContext", "trustedTypes", "MutationEvent", "trustedTypesPolicy",
                                               "fontFaceSetConstructor", "mutationEventsFired")}
    print(f"PAGE-PROBE {who}: {len(report['names'])} window names; {json.dumps(fields)}", flush=True)
    print(f"PAGE-PROBE {who}: user agent {report.get('userAgent')}", flush=True)


def compare(name_a, a, name_b, b):
    if not (a and b and "names" in a and "names" in b):
        print(f"PAGE-PROBE {name_a} against {name_b}: cannot compare", flush=True)
        return
    only_a = sorted(set(a["names"]) - set(b["names"]))
    only_b = sorted(set(b["names"]) - set(a["names"]))
    print(f"PAGE-PROBE {name_a} against {name_b}: {len(only_a)} names only in {name_a} {only_a[:80]}; "
          f"{len(only_b)} only in {name_b} {only_b[:80]}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--features", required=True, help="Key=on|off, comma-separated")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    out = os.path.abspath(args.out)
    features = [f"--measure-feature={value.strip()}" for value in args.features.split(",") if value.strip()]
    server = Server()

    reports = {"safari": visit_safari(server, out)}
    reports["as-built"] = visit_app(server, args.app, "as-built", [], out)
    reports["features"] = visit_app(server, args.app, "features", features, out)
    reports["everything"] = visit_app(server, args.app, "everything", ["--everything"], out)
    with open(os.path.join(out, "reports.json"), "w") as handle:
        json.dump(reports, handle, indent=1)

    for who, report in reports.items():
        describe(who, report)
    for who in ("as-built", "features", "everything"):
        compare(who, reports[who], "safari", reports["safari"])
    compare("features", reports["features"], "everything", reports["everything"])
    compare("as-built", reports["as-built"], "features", reports["features"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
