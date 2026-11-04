#!/usr/bin/env python3
"""Measurement (claude/measure-safari-worlds, never merged): the fingerprint probe in this Mac's
real Safari, three ways — WebDriver's execute/sync (what scripts/safari_reference.py compares), a
<script> element in the page's own world under the same WebDriver session, and a plain Safari
window opened by `open -a Safari` (no automation), which posts its result back.

Why: CI run 718 (f2d9ecf), a macos-26 runner on image 20261102 (macOS 26.7.2, Safari 27.2):
the comparison said window.safari is undefined in Safari and canvas readback throws "The object is
in an invalid state.", where Safari 26.6.2 had both. Is that Safari 27.2 as a person meets it, or
how WebDriver's scripts run in it?
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import safari_reference as ref  # noqa: E402

KEYS = ["canvas", "canvasText", "safari", "safariShape", "features.safari", "windowOwnCount", "webdriver",
        "ua", "errorStack", "features.ApplePaySession", "features.PushManager"]


def flat(value):
    return ref.flat(value) if isinstance(value, dict) else {"_": value}


def main():
    with open(ref.PROBE, encoding="utf-8") as handle:
        probe = handle.read()
    wrapped = "(function(){\n" + probe + "\n})()"
    print("MEASURE", subprocess.run(["sw_vers"], capture_output=True, text=True).stdout.replace("\n", " "))
    print("MEASURE Safari", subprocess.run(["defaults", "read", "/Applications/Safari.app/Contents/Info.plist",
                                            "CFBundleShortVersionString"], capture_output=True, text=True).stdout.strip())

    directory = tempfile.mkdtemp(prefix="pb-worlds-")
    posted = {}

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            posted["normal"] = json.loads(self.rfile.read(length).decode())
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    with open(os.path.join(directory, "probe.html"), "w") as handle:
        handle.write("<!doctype html><html><head><meta charset='utf-8'><title>probe</title></head><body>probe</body></html>")
    with open(os.path.join(directory, "pageprobe.js"), "w") as handle:
        handle.write("document.documentElement.setAttribute('data-probe', JSON.stringify(" + wrapped + "));\n")
    with open(os.path.join(directory, "normal.html"), "w") as handle:
        handle.write("<!doctype html><html><head><meta charset='utf-8'><title>normal</title></head><body>normal<script>\n"
                     "let r; try { r = " + wrapped + "; } catch (e) { r = {error: String(e)}; }\n"
                     "fetch('/result', {method: 'POST', body: JSON.stringify(r)});\n</script></body></html>")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"

    results = {}
    port = ref.free_port()
    driver_process = subprocess.Popen(["safaridriver", "-p", str(port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        if not ref.wait_for_port(port, 20):
            print("MEASURE safaridriver did not listen")
        else:
            driver = ref.WebDriver(f"http://127.0.0.1:{port}")
            try:
                caps = driver.start()
                print("MEASURE WebDriver Safari", caps.get("browserVersion"))
                driver.navigate(base + "/probe.html")
                results["execute"] = driver.execute(probe)
                # The page's own world: a <script> element, its result left on the document.
                driver.execute("const s = document.createElement('script'); s.src = '/pageprobe.js';"
                               " document.head.appendChild(s); return true;")
                raw = None
                for _ in range(40):
                    raw = driver.execute("return document.documentElement.getAttribute('data-probe');")
                    if raw:
                        break
                    time.sleep(0.25)
                results["page world"] = json.loads(raw) if raw else {"error": "no result in the page's world"}
                results["execute again"] = driver.execute(
                    "return [typeof window.safari, (() => { try { const c = document.createElement('canvas'); c.width = 6; c.height = 6;"
                    " c.getContext('2d').fillRect(0, 0, 3, 3); return c.toDataURL().length; } catch (e) { return 'error: ' + e.message; } })()];")
            finally:
                driver.quit()
    finally:
        driver_process.terminate()

    # A plain window, as a person opens a page.
    subprocess.run(["osascript", "-e", 'quit app "Safari"'], capture_output=True)
    time.sleep(3)
    subprocess.run(["open", "-a", "Safari", base + "/normal.html"])
    deadline = time.time() + 45
    while "normal" not in posted and time.time() < deadline:
        time.sleep(0.5)
    results["plain window"] = posted.get("normal", {"error": "no result posted in 45 s"})
    subprocess.run(["osascript", "-e", 'quit app "Safari"'], capture_output=True)
    server.shutdown()

    for way, value in results.items():
        values = flat(value) if isinstance(value, dict) else {"value": value}
        print(f"MEASURE == {way}")
        if isinstance(value, list):
            print("MEASURE   ", value)
            continue
        for key in KEYS:
            print(f"MEASURE   {key} = {json.dumps(values.get(key, '<missing>'))[:300]}")
    # Every key where the ways disagree.
    a, b, c = (flat(results.get(w, {})) for w in ("execute", "page world", "plain window"))
    for key in sorted(set(a) | set(b) | set(c)):
        va, vb, vc = a.get(key, "<missing>"), b.get(key, "<missing>"), c.get(key, "<missing>")
        if not (va == vb == vc):
            print(f"MEASURE DIFFER {key}: execute={json.dumps(va)[:120]} page={json.dumps(vb)[:120]} plain={json.dumps(vc)[:120]}")
    out = os.environ.get("MEASURE_OUT")
    if out:
        with open(out, "w") as handle:
            json.dump(results, handle, indent=1, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
