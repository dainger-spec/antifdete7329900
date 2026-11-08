#!/usr/bin/env python3
"""A stand-in for the harness's control channel, for device-tools.yml: does the driver get through?

    python3 ios-measure/control_stub.py <port> <seconds>   -> prints "hello: yes|no", calls by path

Answers /hello and /next with nothing to do, so the driver keeps calling; stops after <seconds>.
"""
import http.server
import json
import sys
import threading

calls = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        calls[self.path] = calls.get(self.path, 0) + 1
        self.send_response(200 if self.path == "/hello" else 204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Handler)
threading.Timer(float(sys.argv[2]), server.shutdown).start()
server.serve_forever()
print("hello:", "yes" if calls.get("/hello") else "no")
print("calls:", json.dumps(calls))
