#!/usr/bin/env python3
"""Measurement: does this Mac's real Safari give a page `window.safari`, and does that depend on the
page's address? The owner, 8 November: a plain Safari window on his Mac, a page over http on the
local network — no window.safari; our profiles always had one (PrivacyScripts' patchSafariObject).
A plain Safari window (no WebDriver) opens the same page at http://127.0.0.1 (a secure context) and
at http://<this Mac's network address> (not one), and so does Safari under WebDriver; each says
typeof window.safari, isSecureContext and what the object holds. Standard library only.

    python3 scripts/window_safari_check.py
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import safari_reference as ref  # noqa: E402

PROBE = ("const s = window.safari; return {typeofSafari: typeof s, secure: isSecureContext, "
         "keys: s ? Object.keys(s) : null, push: s && s.pushNotification ? Object.prototype.toString.call(s.pushNotification) : null, "
         "own: Object.getOwnPropertyNames(window).includes('safari'), ua: navigator.userAgent, href: location.href};")


def lan_address():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]
    finally:
        probe.close()


def plain_window(host):
    posted = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ("<!doctype html><meta charset=utf-8><title>probe</title>probe<script>let r; try { r = (function(){"
                    + PROBE + "})(); } catch (e) { r = {error: String(e)}; } fetch('/result', {method: 'POST', body: JSON.stringify(r)});</script>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            posted["result"] = json.loads(self.rfile.read(length).decode() or "null")
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://{host}:{server.server_address[1]}/"
    try:
        subprocess.run(["osascript", "-e", 'quit app "Safari"'], capture_output=True, timeout=20)
        time.sleep(2)
        subprocess.run(["open", "-a", "Safari", url], timeout=20)
        deadline = time.time() + 45
        while "result" not in posted and time.time() < deadline:
            time.sleep(0.5)
        return posted.get("result")
    finally:
        subprocess.run(["osascript", "-e", 'quit app "Safari"'], capture_output=True, timeout=20)
        server.shutdown()


def webdriver(host):
    port = ref.free_port()
    driver_process = subprocess.Popen(["safaridriver", "-p", str(port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"<!doctype html><title>probe</title>probe"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        if not ref.wait_for_port(port, 20):
            return {"error": "safaridriver did not listen"}
        driver = ref.WebDriver(f"http://127.0.0.1:{port}")
        try:
            driver.start()
            driver.navigate(f"http://{host}:{server.server_address[1]}/")
            return driver.execute(PROBE)
        finally:
            driver.quit()
    except Exception as error:  # noqa: BLE001 — a measurement says what failed
        return {"error": str(error)}
    finally:
        server.shutdown()
        driver_process.terminate()


def main():
    version = subprocess.run(["defaults", "read", "/Applications/Safari.app/Contents/Info.plist", "CFBundleShortVersionString"],
                             capture_output=True, text=True).stdout.strip()
    lan = lan_address()
    print(f"window.safari: Safari {version}, this Mac's network address is {'loopback' if lan.startswith('127.') else 'not loopback'}")
    for kind, run in (("plain window", plain_window), ("WebDriver", webdriver)):
        for label, host in (("http://127.0.0.1 (secure context)", "127.0.0.1"), ("http://<network address> (not secure)", lan)):
            result = run(host)
            if isinstance(result, dict):
                result.pop("href", None)
                result.pop("ua", None)
            print(f"window.safari: {kind}, {label}: {json.dumps(result, sort_keys=True)}", flush=True)


if __name__ == "__main__":
    main()
