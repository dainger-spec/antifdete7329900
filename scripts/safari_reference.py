#!/usr/bin/env python3
"""Runs the fingerprint probe in the Mac's real Safari (via safaridriver) and compares the result
with what the self-test saw in a Lumen profile on the same Mac.

    sudo safaridriver --enable            # once per machine (CI does it)
    python3 scripts/safari_reference.py --compare build/selftest-surface/surface-macos.json \
        --out build/safari-surface.json

Safari and a WKWebView render with the same system WebKit, so for a macOS profile everything a
page can measure should be identical: the User-Agent the profile declares, plugins, canvas and
WebGL output, fonts, feature presence. Keys that legitimately differ (the self-test overrides the
language; window sizes) are reported but do not fail.

A must-match key that differs is read again in a plain Safari window — opened by `open -a Safari`,
no automation, the page posting its result back — so the check says itself whether the profile
differs from Safari as a person meets it, or only from Safari under WebDriver (CI run 718,
f2d9ecf: Safari 27.2's canvas readback threw; measured, a plain Safari 27.0.1 window does the same).

Exit codes, each said in words on the last line:
  0  every must-match key the same
  1  DIVERGES: a must-match key differs, and a plain Safari window says what WebDriver said (or
     could not be read, so nothing excuses it)
  2  NOT DRIVEN: Safari could not be driven here, or its probe came back incomplete — nothing compared
  3  WEBDRIVER ONLY: every differing key reads, in a plain Safari window, as the profile has it — the
     comparison's method, not the profile, differs from Safari
  4  ENGINES DIFFER: Safari runs a WebKit of its own, not the one this Mac gives apps (Safari.app's
     build against the WebKit the self-test ran, from its surface's "_engine"): no profile can be this
     Safari here, nothing is compared, and the profile names the Safari of its own engine (it does
     not: 1)
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
import urllib.error
import urllib.request

PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "fingerprint_probe.js")

# Differ by design between the self-test (which gives WebKit a fixed language, uses a hidden
# window) and a Safari window: reported, never fatal.
INFO_KEYS = {"language", "languages", "intlLocale", "innerSize", "outerSize", "windowOwnCount", "errorStack",
             "orientation", "audio", "cookieEnabled",
             # Date#toString names the zone in the default locale, which the self-test overrides.
             "dateString",
             # The same for the default formats and the browser's own words and labels.
             "localeFormats", "validationMessages", "controlWidths",
             # Safari under safaridriver reports navigator.webdriver = true; a profile reports false.
             "webdriver",
             # The WebRTC policy removes these on purpose in a default profile.
             "features.RTCPeerConnection", "features.webkitRTCPeerConnection", "features.RTCDataChannel",
             "features.window.webkitRTCPeerConnection", "natives.RTCPeerConnection"}
# What a page measures of the engine and the Mac: must be identical.
MUST_MATCH = {"ua", "appVersion", "vendor", "platform", "hardwareConcurrency", "deviceMemory", "maxTouchPoints",
              "pdfViewerEnabled", "plugins", "mimeTypes", "webdriver", "standalone", "doNotTrack", "ownNavigator",
              "ownScreen", "navigatorProtoCount", "screen", "colorDepth", "pointer", "touch", "timeZone", "tzOffset",
              "canvas.colors", "canvas.urlLength", "canvas.url", "canvasText", "fonts", "webkitObject", "safari"}
MUST_MATCH_PREFIXES = ("webgl.", "natives.")


def flat(value):
    result = {}
    for key, item in value.items():
        if isinstance(item, dict):
            for subkey, subitem in flat(item).items():
                result[f"{key}.{subkey}"] = subitem
        else:
            result[key] = item
    return result


class WebDriver:
    def __init__(self, base):
        self.base = base
        self.session = None

    def request(self, method, path, body=None, timeout=60):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method,
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())["value"]

    def start(self):
        value = self.request("POST", "/session", {"capabilities": {"alwaysMatch": {"browserName": "Safari"}}})
        self.session = value["sessionId"]
        return value.get("capabilities", {})

    def navigate(self, url):
        self.request("POST", f"/session/{self.session}/url", {"url": url})

    def execute(self, script):
        return self.request("POST", f"/session/{self.session}/execute/sync", {"script": script, "args": []})

    def quit(self):
        if self.session:
            try:
                self.request("DELETE", f"/session/{self.session}")
            except Exception:
                pass
            self.session = None


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_port(port, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.3)
    return False


def serve_probe_page():
    directory = tempfile.mkdtemp(prefix="pb-probe-")
    with open(os.path.join(directory, "probe.html"), "w") as handle:
        handle.write("<!doctype html><html><head><meta charset='utf-8'><title>probe</title></head><body>probe</body></html>")
    handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(*args, directory=directory, **kwargs)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/probe.html"


def run_in_plain_window(probe_source, seconds=45):
    """The probe in a Safari window opened as a person opens a page (no WebDriver), its result posted
    back to this script's server; None when nothing came."""
    directory = tempfile.mkdtemp(prefix="pb-plain-")
    posted = {}

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            try:
                posted["result"] = json.loads(self.rfile.read(length).decode())
            except ValueError:
                posted["result"] = None
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    with open(os.path.join(directory, "plain.html"), "w", encoding="utf-8") as handle:
        handle.write("<!doctype html><html><head><meta charset='utf-8'><title>probe</title></head><body>probe<script>\n"
                     "let r; try { r = (function(){\n" + probe_source + "\n})(); } catch (e) { r = {_error: String(e)}; }\n"
                     "fetch('/result', {method: 'POST', body: JSON.stringify(r)});\n</script></body></html>")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(["osascript", "-e", 'quit app "Safari"'], capture_output=True, timeout=20)
        time.sleep(2)
        subprocess.run(["open", "-a", "Safari", f"http://127.0.0.1:{server.server_address[1]}/plain.html"], timeout=20)
        deadline = time.time() + seconds
        while "result" not in posted and time.time() < deadline:
            time.sleep(0.5)
        return posted.get("result")
    finally:
        subprocess.run(["osascript", "-e", 'quit app "Safari"'], capture_output=True, timeout=20)
        server.shutdown()


def run_in_safari(probe_source, port):
    driver_process = subprocess.Popen(["safaridriver", "-p", str(port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        if not wait_for_port(port, 20):
            output = driver_process.stdout.read().decode(errors="replace") if driver_process.poll() is not None else ""
            raise RuntimeError(f"safaridriver did not listen on port {port}: {output.strip()}")
        server, url = serve_probe_page()
        driver = WebDriver(f"http://127.0.0.1:{port}")
        try:
            capabilities = driver.start()
            driver.navigate(url)
            result = driver.execute(probe_source)
            result["_safari"] = {"browserVersion": capabilities.get("browserVersion"), "url": url}
            return result
        finally:
            driver.quit()
            server.shutdown()
    finally:
        driver_process.terminate()
        try:
            driver_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            driver_process.kill()


def text(value):
    """Values as JavaScript prints them (the self-test writes every value as a string)."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def compare(safari, ours):
    safari_flat, ours_flat = flat(safari), flat(ours)
    failures, diffs, same = [], [], 0
    for key in sorted(set(safari_flat) | set(ours_flat)):
        if key.startswith("_"):
            continue
        a, b = text(safari_flat.get(key, "<missing>")), text(ours_flat.get(key, "<missing>"))
        if a == b:
            same += 1
            continue
        line = f"{key}: Safari={json.dumps(a)[:160]}  profile={json.dumps(b)[:160]}"
        must = key in MUST_MATCH or key.startswith(MUST_MATCH_PREFIXES)
        if key in INFO_KEYS or key.split(".")[0] in INFO_KEYS and key.split(".")[0] not in ("features", "natives"):
            diffs.append("INFO " + line)
        elif must:
            failures.append(key)
        else:
            diffs.append("DIFF " + line)
    return failures, diffs, same


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--probe", default=PROBE)
    parser.add_argument("--compare", help="surface JSON written by the self-test (PB_SELFTEST_SURFACE_OUT)")
    parser.add_argument("--out", help="write Safari's probe result here")
    parser.add_argument("--port", type=int, default=0)
    # Saved answers instead of a Safari (scripts/test_safari_reference.sh): Safari's under WebDriver,
    # and a plain window's ("none": no result came).
    parser.add_argument("--safari-json", help=argparse.SUPPRESS)
    parser.add_argument("--plain-json", help=argparse.SUPPRESS)
    args = parser.parse_args()

    with open(args.probe, encoding="utf-8") as handle:
        probe_source = handle.read()
    ours = None
    if args.compare:
        try:
            with open(args.compare, encoding="utf-8") as handle:
                ours = json.load(handle)
        except (OSError, ValueError) as exc:
            print(f"SAFARI-REFERENCE NOT DRIVEN: no surface from the self-test to compare ({exc}) — nothing compared")
            return 2
        # Safari with a WebKit of its own (Safari.app's build is not the WebKit this Mac gives apps;
        # CI run 718): no profile can be this Safari here, so it is not compared with it; what is
        # checked is that the profile names the Safari of the engine it runs, not Safari.app.
        engine = ours.get("_engine") or {}
        if engine.get("sharesEngine") == "false":
            ua, app, declared = str(ours.get("ua", "")), engine.get("safariApp", "?"), engine.get("declared", "?")
            coherent = f"Version/{declared} " in ua and (app == declared or f"Version/{app} " not in ua)
            print(f"SAFARI-REFERENCE ENGINES DIFFER: Safari {app} runs a WebKit of its own (build {engine.get('safariAppBuild')}), "
                  f"this Mac's apps run WebKit {engine.get('webKit')}: a profile cannot be this Safari here and is not compared "
                  f"with it. The Safari of the engine it runs is {declared}; the profile names it: "
                  + ("yes" if coherent else f"NO — its User-Agent is {ua}"))
            return 4 if coherent else 1
    try:
        if args.safari_json:
            with open(args.safari_json, encoding="utf-8") as handle:
                safari = json.load(handle)
        else:
            safari = run_in_safari(probe_source, args.port or free_port())
    except Exception as exc:  # noqa: BLE001 - a runner without a usable Safari verifies nothing
        print(f"SAFARI-REFERENCE NOT DRIVEN: could not drive Safari here: {exc}")
        return 2
    print(f"Safari {safari.get('_safari', {}).get('browserVersion')}: UA {safari.get('ua')}")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(safari, handle, indent=1, sort_keys=True)
    if ours is None:
        return 0
    # The probe sets every one of its keys, an error included; one missing from Safari's answer means
    # the probe did not run to its end there — the driver's failure, not Safari's answer.
    missing = sorted(key for key in ours if not key.startswith("_") and key not in safari)
    if missing:
        print(f"SAFARI-REFERENCE NOT DRIVEN: Safari's probe came back without {len(missing)} of its keys "
              f"({', '.join(missing[:8])}) — nothing compared")
        return 2
    failures, diffs, same = compare(safari, ours)
    for line in diffs:
        print(line)
    if not failures:
        print(f"SAFARI-REFERENCE PASSED: {same} keys identical, {len(diffs)} differ (reported), 0 must-match keys differ")
        return 0
    # Each differing must-match key, read again in a plain Safari window.
    if args.plain_json:
        plain = None
        if args.plain_json != "none":
            with open(args.plain_json, encoding="utf-8") as handle:
                plain = json.load(handle)
    else:
        plain = run_in_plain_window(probe_source)
    plain_flat = flat(plain) if isinstance(plain, dict) else {}
    safari_flat, ours_flat = flat(safari), flat(ours)
    confirmed, webdriver_only = [], []
    for key in failures:
        a, b = text(safari_flat.get(key, "<missing>")), text(ours_flat.get(key, "<missing>"))
        if not plain_flat:
            confirmed.append(key)
            verdict = "a plain window could not be read: unconfirmed, so not excused"
        else:
            c = text(plain_flat.get(key, "<missing>"))
            if c == a:
                confirmed.append(key)
                verdict = "a plain Safari window says the same: the profile differs from Safari"
            elif c == b:
                webdriver_only.append(key)
                verdict = "a plain Safari window says what the profile says: WebDriver's reading only"
            else:
                confirmed.append(key)
                verdict = f"a plain Safari window says {json.dumps(c)[:120]}: differs from both"
        print(f"FAIL {key}: Safari={json.dumps(a)[:160]}  profile={json.dumps(b)[:160]} — {verdict}")
    summary = f"{same} keys identical, {len(diffs)} differ (reported), {len(failures)} must-match keys differ"
    if confirmed:
        print(f"SAFARI-REFERENCE DIVERGES: {summary}; {len(confirmed)} confirmed in a plain Safari window or unconfirmed "
              f"({', '.join(confirmed)}), {len(webdriver_only)} WebDriver's only")
        return 1
    print(f"SAFARI-REFERENCE WEBDRIVER ONLY: {summary}; every one reads in a plain Safari window as the profile has it "
          f"({', '.join(webdriver_only)}) — the comparison's method differs from Safari, not the profile")
    return 3


if __name__ == "__main__":
    sys.exit(main())
