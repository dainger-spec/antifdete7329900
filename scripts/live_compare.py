#!/usr/bin/env python3
"""Measures the same pages in this Mac's Safari (safaridriver) and in PrivacyBrowser profiles, with
the same outer window size, and prints what differs.

    sudo safaridriver --enable                                   # once per machine (CI does it)
    python3 scripts/live_compare.py --app build/unsandboxed/PrivacyBrowser.app --out build/live

Pages: the fingerprint probe and the window geometry (one and two tabs) on a local page; the order
of the request headers a local server receives (navigation, fetch, XHR); and live fingerprinting
sites (scripts/live_sites/*.js: TLS/HTTP2 echo, deviceinfo.me, CreepJS, …). The app side runs
`PrivacyBrowser --capture-sites` (SiteCapture.swift), which needs the unsandboxed build (it reads
the spec and writes results outside the container). Live sites change and fail; this is a report,
not a test: the exit code is 0 unless neither browser could be measured.
"""
import argparse
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from safari_reference import WebDriver, flat, free_port, text, wait_for_port  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SITES = os.path.join(ROOT, "scripts", "live_sites")
PROBE = os.path.join(ROOT, "Resources", "fingerprint_probe.js")
# The local pages' scripts, which the app's "What sites see" runs too (bundled with the app).
SITE_PROBES = os.path.join(ROOT, "Resources", "SiteProbes")


def profiles(zone):
    """A profile as a new user gets it, and one that runs the time-zone and WebRTC wrappers with
    Safari's own zone (whatever a page then notices is the wrapper itself, not a different value)."""
    return [{"name": "default"}, {"name": "shimmed", "timeZone": zone or "host", "webRTC": "relayOnly"}]


class Recorder(http.server.BaseHTTPRequestHandler):
    """Serves the local pages and remembers every request's header lines, in order, per token."""
    requests = {}
    lock = threading.Lock()

    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        token = query.get("token", ["-"])[0]
        with self.lock:
            self.requests.setdefault(token, []).append({"path": url.path, "headers": [[k, v] for k, v in self.headers.items()]})
        if url.path == "/echo":
            with self.lock:
                body = json.dumps(self.requests.get(token, [])).encode()
            self.send("application/json", body)
        elif url.path.endswith(".html"):
            self.send("text/html; charset=utf-8",
                      b"<!doctype html><html><head><meta charset='utf-8'><title>live</title></head><body>live</body></html>")
        else:
            self.send("text/plain", b"ok")

    def send(self, content_type, body):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def pages(base, browser):
    """The page list; `browser` names the run so the header recorder keeps the two apart."""
    token = f"{browser}-{int(time.time() * 1000)}"
    geometry = read(os.path.join(SITE_PROBES, "geometry.js"))
    result = [
        {"name": "probe", "url": f"{base}/probe.html", "script": read(PROBE)},
        {"name": "geometry", "url": f"{base}/geometry.html", "script": geometry},
        {"name": "geometry-2tabs", "url": f"{base}/geometry.html", "script": geometry, "extraTabs": 1, "settleMs": 800},
        {"name": "headers", "url": f"{base}/headers.html?token={token}", "script": read(os.path.join(SITE_PROBES, "headers.js"))},
        {"name": "apis", "url": f"{base}/apis.html", "script": read(os.path.join(SITE_PROBES, "apis.js"))},
    ]
    for name in sorted(os.listdir(SITES)):
        if not name.endswith(".js"):
            continue
        source = read(os.path.join(SITES, name))
        # First line: // url: https://… [settle=ms] [timeout=ms]
        meta = dict(part.split("=", 1) for part in source.splitlines()[0].split()[3:] if "=" in part)
        url = source.splitlines()[0].split("url:", 1)[1].split()[0]
        result.append({"name": name[:-3], "url": url, "script": source,
                       "settleMs": int(meta.get("settle", 0)), "timeoutMs": int(meta.get("timeout", 90000))})
    return result


def run_app(app, spec, out_dir):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(spec, handle)
        spec_path = handle.name
    binary = os.path.join(app, "Contents", "MacOS", "PrivacyBrowser")
    print(f"::group::PrivacyBrowser --capture-sites")
    code = subprocess.call([binary, "--capture-sites", spec_path, out_dir], timeout=1200)
    print("::endgroup::")
    results = {}
    for profile in spec["profiles"]:
        path = os.path.join(out_dir, profile["name"] + ".json")
        if os.path.exists(path):
            results[profile["name"]] = json.load(open(path, encoding="utf-8"))
    print(f"app capture exit code {code}, profiles captured: {sorted(results)}")
    return results


ASYNC_WRAPPER = """const __done = arguments[arguments.length - 1];
(async () => {
%s
})().then((v) => __done(JSON.stringify(v === undefined ? null : v)),
          (e) => __done(JSON.stringify({ error: String(e && e.message || e) })));"""


def run_safari(spec, port):
    driver_process = subprocess.Popen(["safaridriver", "-p", str(port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    results = {}
    try:
        if not wait_for_port(port, 20):
            raise RuntimeError("safaridriver did not start")
        driver = WebDriver(f"http://127.0.0.1:{port}")
        capabilities = driver.start()
        print(f"Safari {capabilities.get('browserVersion')}")
        try:
            driver.request("POST", f"/session/{driver.session}/timeouts", {"script": 150000, "pageLoad": 120000})
            driver.request("POST", f"/session/{driver.session}/window/rect",
                           {"x": 60, "y": 60, "width": spec["window"]["width"], "height": spec["window"]["height"]})
            main = driver.request("GET", f"/session/{driver.session}/window")
            for page in spec["pages"]:
                print(f"INFO [safari] {page['name']}: {page['url']}")
                try:
                    driver.navigate(page["url"])
                    extra = []
                    for _ in range(page.get("extraTabs", 0)):
                        created = driver.request("POST", f"/session/{driver.session}/window/new", {"type": "tab"})
                        extra.append(created["handle"])
                    if extra:
                        driver.request("POST", f"/session/{driver.session}/window", {"handle": main})
                    if page.get("settleMs"):
                        time.sleep(page["settleMs"] / 1000)
                    value = driver.request("POST", f"/session/{driver.session}/execute/async",
                                           {"script": ASYNC_WRAPPER % page["script"], "args": []},
                                           timeout=page.get("timeoutMs", 90000) / 1000 + 30)
                    results[page["name"]] = json.loads(value) if isinstance(value, str) else value
                    for handle in extra:
                        driver.request("POST", f"/session/{driver.session}/window", {"handle": handle})
                        driver.request("DELETE", f"/session/{driver.session}/window")
                    if extra:
                        driver.request("POST", f"/session/{driver.session}/window", {"handle": main})
                except Exception as exc:  # noqa: BLE001 - one site failing must not stop the others
                    print(f"INFO [safari] {page['name']} failed: {exc}")
                    results[page["name"]] = {"error": str(exc)}
        finally:
            driver.quit()
    finally:
        driver_process.terminate()
        try:
            driver_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            driver_process.kill()
    return results


def as_dict(value):
    return value if isinstance(value, dict) else {"value": value}


def compare(safari, profile):
    a, b = flat(as_dict(safari)), flat(as_dict(profile))
    same, diffs = 0, []
    for key in sorted(set(a) | set(b)):
        x, y = text(a.get(key, "<missing>")), text(b.get(key, "<missing>"))
        if x == y:
            same += 1
        else:
            diffs.append((key, x, y))
    return same, diffs


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the unsandboxed PrivacyBrowser.app")
    parser.add_argument("--out", required=True)
    # Small enough for the CI runner's screen: AppKit shrinks a window that does not fit, Safari not.
    parser.add_argument("--width", type=int, default=1000)
    parser.add_argument("--height", type=int, default=600)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    window = {"width": args.width, "height": args.height}

    safari = run_safari({"window": window, "pages": pages(base, "safari")}, free_port())
    zone = (safari.get("probe") or {}).get("timeZone") if isinstance(safari.get("probe"), dict) else None
    app_spec = {"window": window, "profiles": profiles(zone), "pages": pages(base, "profile")}
    profiles_measured = run_app(os.path.abspath(args.app), app_spec, os.path.abspath(os.path.join(args.out, "profiles")))
    server.shutdown()

    with open(os.path.join(args.out, "safari.json"), "w", encoding="utf-8") as handle:
        json.dump(safari, handle, indent=1, sort_keys=True)
    if not safari and not profiles_measured:
        print("LIVE-COMPARE: nothing measured")
        return 2

    report = {}
    for name, results in profiles_measured.items():
        report[name] = {}
        for page in sorted(set(safari) | set(results)):
            same, diffs = compare(safari.get(page), results.get(page))
            report[name][page] = {"same": same, "diffs": [{"key": k, "safari": x, "profile": y} for k, x, y in diffs]}
            print(f"::group::[{name}] {page}: {same} same, {len(diffs)} differ")
            for key, x, y in diffs:
                print(f"DIFF [{name}] {page}.{key}: Safari={json.dumps(x)[:300]}  profile={json.dumps(y)[:300]}")
            print("::endgroup::")
    with open(os.path.join(args.out, "report.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=1, sort_keys=True)
    for name, pages_report in report.items():
        summary = ", ".join(f"{page} {r['same']}/{r['same'] + len(r['diffs'])}" for page, r in sorted(pages_report.items()))
        print(f"LIVE-COMPARE [{name}] identical keys per page: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
