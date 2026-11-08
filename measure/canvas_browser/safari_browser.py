#!/usr/bin/env python3
"""Measurement: does this Mac's Safari give a page window.browser, with no extension installed?
A plain Safari window (no WebDriver) opens the probe page (browser_probe.js) over http at 127.0.0.1
and at this Mac's network address; the page posts what it sees. Safari's version is said with it.
Standard library only.

    python3 measure/canvas_browser/safari_browser.py
"""
import http.server
import json
import os
import plistlib
import socket
import subprocess
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = open(os.path.join(HERE, "browser_probe.js"), encoding="utf-8").read()


def lan_address():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]
    finally:
        probe.close()


def plain_window(host, tag):
    posted = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ("<!doctype html><meta charset=utf-8><title>probe</title>probe<script>(async () => {" + PROBE
                    + "})().then((r) => fetch('/result', {method: 'POST', body: r}), (e) => fetch('/result', {method: 'POST', body: JSON.stringify({error: String(e)})}));</script>").encode()
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
    url = f"http://{host}:{server.server_address[1]}/?tag={tag}"
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


def main():
    info = plistlib.load(open("/Applications/Safari.app/Contents/Info.plist", "rb"))
    print(f"SAFARI {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})")
    extensions = os.path.expanduser("~/Library/Containers/com.apple.Safari/Data/Library/Safari/AppExtensions")
    print(f"SAFARI extensions folder: {'present' if os.path.isdir(extensions) else 'absent'}")
    for tag, host in (("loopback", "127.0.0.1"), ("lan", lan_address())):
        result = plain_window(host, tag)
        print(f"SAFARI-BROWSER {tag} {json.dumps(result)}")


if __name__ == "__main__":
    main()
