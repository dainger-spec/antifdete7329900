#!/usr/bin/env python3
"""Runs the fingerprint probe in the Mac's real Safari (via safaridriver) and compares the result
with what the self-test saw in a PrivacyBrowser profile on the same Mac.

    sudo safaridriver --enable            # once per machine (CI does it)
    python3 scripts/safari_reference.py --compare build/selftest-surface/surface-macos.json \
        --out build/safari-surface.json

Safari and a WKWebView render with the same system WebKit, so for a macOS profile everything a
page can measure should be identical: the User-Agent the profile declares, plugins, canvas and
WebGL output, fonts, feature presence. Keys that legitimately differ (the self-test overrides the
language; window sizes) are reported but do not fail. Exit code 2 when Safari could not be
driven on this machine (nothing verified), 1 when a must-match key differs, 0 otherwise.
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
# The media stack, the touch interfaces and the fonts a page finds (a macOS profile has no font allowlist).
MUST_MATCH_PREFIXES = ("webgl.", "natives.", "codecs.", "touchShape.", "fontFamilies.")


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


def describe(key, a, b):
    """One line per difference; for lists (globals, WebGL extensions, codecs) the items one side lacks."""
    left, right = a.split(","), b.split(",")
    if min(len(left), len(right)) >= 4:
        only_safari, only_profile = [x for x in left if x not in right], [x for x in right if x not in left]
        if not only_safari and not only_profile:
            return f"{key}: the same items, in another order"
        return f"{key}: only in Safari: {','.join(only_safari) or '-'}; only in the profile: {','.join(only_profile) or '-'}"
    return f"{key}: Safari={json.dumps(a)[:160]}  profile={json.dumps(b)[:160]}"


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
        line = describe(key, a, b)
        must = key in MUST_MATCH or key.startswith(MUST_MATCH_PREFIXES)
        if key in INFO_KEYS or key.split(".")[0] in INFO_KEYS and key.split(".")[0] not in ("features", "natives"):
            diffs.append("INFO " + line)
        elif must:
            failures.append("FAIL " + line)
        else:
            diffs.append("DIFF " + line)
    return failures, diffs, same


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--probe", default=PROBE)
    parser.add_argument("--compare", help="surface JSON written by the self-test (PB_SELFTEST_SURFACE_OUT)")
    parser.add_argument("--out", help="write Safari's probe result here")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    with open(args.probe, encoding="utf-8") as handle:
        probe_source = handle.read()
    try:
        safari = run_in_safari(probe_source, args.port or free_port())
    except Exception as exc:  # noqa: BLE001 - a runner without a usable Safari verifies nothing
        print(f"SAFARI-REFERENCE SKIPPED: could not drive Safari here: {exc}")
        return 2
    print(f"Safari {safari['_safari']['browserVersion']}: UA {safari.get('ua')}")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(safari, handle, indent=1, sort_keys=True)
    if not args.compare:
        return 0
    with open(args.compare, encoding="utf-8") as handle:
        ours = json.load(handle)
    failures, diffs, same = compare(safari, ours)
    for line in diffs + failures:
        print(line)
    print(f"SAFARI-REFERENCE {'FAILED' if failures else 'PASSED'}: {same} keys identical, "
          f"{len(diffs)} differ (reported), {len(failures)} must-match keys differ")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
