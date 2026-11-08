#!/usr/bin/env python3
"""Measurement (never merged): serves a canary page on this Mac's network address, runs
build/share-probe against it, and says which request came while which step ran — the picker
shown, or a service performed. Standard library only.

    python3 scripts/share_check.py
"""
import http.server
import socket
import subprocess
import threading
import time

hits = []


def lan_address():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]
    finally:
        probe.close()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits.append((time.time(), self.path, self.headers.get("User-Agent", "")))
        body = b"<!doctype html><html><head><title>Canary page</title><meta property='og:title' content='Canary'></head><body>canary</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, *args):
        pass


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://{lan_address()}:{server.server_address[1]}/"
    steps = []
    probe = subprocess.Popen(["build/share-probe", base], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in probe.stdout:
        line = line.rstrip()
        steps.append((time.time(), line))
        print(line.replace(base, "<canary>/"), flush=True)
    probe.wait()
    time.sleep(5)
    print(f"SHARE requests to the canary: {len(hits)}")
    for at, path, agent in hits:
        during = [text for when, text in steps if when <= at]
        print(f"SHARE request {path} — user agent {agent!r} — after: {during[-1].replace(base, '<canary>/') if during else 'nothing'}")
    for app in ["Mail", "Messages", "Notes", "Reminders", "Freeform"]:
        subprocess.run(["osascript", "-e", f'quit app "{app}"'], capture_output=True, timeout=20)


if __name__ == "__main__":
    main()
