#!/usr/bin/env python3
"""A local R2 for scripts/test_r2_publish.sh: the S3 API a release uploads to, and the public
address it reads back from, both over TLS on 127.0.0.1.

    python3 scripts/r2_local.py --state DIR --cert PEM --key PEM --bucket NAME --key-id ID --secret SECRET

Prints "<API port> <public port>" once both listen, then serves until killed.

- The API (path-style, /<bucket>/<name>, one bucket: the keys are for it alone, as a release's are)
  takes PUT, HEAD and GET signed as R2 takes them, AWS
  Signature Version 4 for the region "auto" and the service "s3": the signature is computed again
  here from the headers the request signed, with the secret, and a request that does not match it
  is refused (403 SignatureDoesNotMatch), as is a request that leaves the host, the date or the
  payload's hash unsigned. A PUT whose body is not the SHA-256 it signed is refused (400
  XAmzContentSHA256Mismatch), as R2 refuses it. What a PUT carries is kept: the body, Content-Type,
  Cache-Control and the x-amz-meta-* headers, which HEAD and GET give back.
- The public side (/<name>) serves the bucket as dl.lumenbrowser.io serves it. If DIR/corrupt names
  an object, its first byte is served changed: a check that reads back must catch that.

Every request is logged in DIR/log.jsonl: method, name, the payload hash signed, the signed headers,
the answer.
"""
import argparse
import datetime
import hashlib
import hmac
import json
import os
import re
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EMPTY = hashlib.sha256(b"").hexdigest()
AUTHORIZATION = re.compile(
    r"AWS4-HMAC-SHA256 Credential=([^/]+)/(\d{8})/([^/]+)/([^/]+)/aws4_request,\s*"
    r"SignedHeaders=([a-z0-9;-]+),\s*Signature=([0-9a-f]{64})$")

objects = {}
lock = threading.Lock()


def log(state, entry):
    with lock, open(os.path.join(state, "log.jsonl"), "a") as handle:
        handle.write(json.dumps(entry) + "\n")


def signing_key(secret, date, region, service):
    key = ("AWS4" + secret).encode()
    for part in (date, region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    return key


class API(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # so that curl's "Expect: 100-continue" is answered at once

    def log_message(self, *_):
        pass

    def answer(self, status, body=b"", headers=None, entry=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        if entry is not None:
            entry["status"] = status
            log(self.server.config.state, entry)

    def error(self, status, code, entry):
        entry["error"] = code
        self.answer(status, f"<Error><Code>{code}</Code></Error>".encode(), {"Content-Type": "application/xml"}, entry)

    def authorized(self, entry):
        """None when the request is signed as R2 wants it, else the error's code."""
        config = self.server.config
        match = AUTHORIZATION.match(self.headers.get("Authorization", ""))
        if not match:
            return "AccessDenied"
        key_id, date, region, service, signed, signature = match.groups()
        signed_names = signed.split(";")
        entry["signed"] = signed_names
        payload = self.headers.get("x-amz-content-sha256", "")
        entry["payload"] = payload
        amz_date = self.headers.get("x-amz-date", "")
        if key_id != config.key_id:
            return "InvalidAccessKeyId"
        if region != "auto" or service != "s3" or not amz_date.startswith(date):
            return "AuthorizationHeaderMalformed"
        if not {"host", "x-amz-date", "x-amz-content-sha256"} <= set(signed_names) or signed_names != sorted(signed_names):
            return "AccessDenied"
        when = datetime.datetime.strptime(amz_date, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc)
        if abs((datetime.datetime.now(datetime.timezone.utc) - when).total_seconds()) > 900:
            return "RequestTimeTooSkewed"
        path, _, query = self.path.partition("?")
        canonical_query = "&".join(sorted(part if "=" in part else part + "=" for part in query.split("&") if part))
        canonical_headers = "".join(f"{name}:{' '.join((self.headers.get(name) or '').split())}\n" for name in signed_names)
        request = "\n".join([self.command, path, canonical_query, canonical_headers, signed, payload])
        to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, f"{date}/{region}/{service}/aws4_request",
                             hashlib.sha256(request.encode()).hexdigest()])
        expected = hmac.new(signing_key(config.secret, date, region, service), to_sign.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            return "SignatureDoesNotMatch"
        return None

    def target(self, entry):
        """The object's name, or None (and the answer sent) if the bucket is not ours."""
        bucket, _, name = self.path.partition("?")[0].lstrip("/").partition("/")
        entry["name"] = name
        if bucket != self.server.config.bucket:
            self.error(403, "AccessDenied", entry)  # the keys are for one bucket
            return None
        if not name:
            self.error(404, "NoSuchKey", entry)
            return None
        return name

    def handle_one(self):
        entry = {"side": "api", "method": self.command}
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)) if self.command == "PUT" else b""
        problem = self.authorized(entry)
        name = self.target(entry)
        if name is None:
            return
        if problem:
            self.error(400 if problem == "AuthorizationHeaderMalformed" else 403, problem, entry)
            return
        if self.command == "PUT":
            payload = entry["payload"]
            if payload != "UNSIGNED-PAYLOAD" and payload != hashlib.sha256(body).hexdigest():
                self.error(400, "XAmzContentSHA256Mismatch", entry)
                return
            kept = {"body": body, "headers": {"Content-Type": self.headers.get("Content-Type", "application/octet-stream"),
                                              "Cache-Control": self.headers.get("Cache-Control", "")}}
            kept["headers"].update({key.lower(): value for key, value in self.headers.items() if key.lower().startswith("x-amz-meta-")})
            with lock:
                objects[name] = kept
            self.answer(200, b"", {"ETag": '"' + hashlib.md5(body).hexdigest() + '"'}, entry)
            return
        with lock:
            kept = objects.get(name)
        if kept is None:
            self.error(404, "NoSuchKey", entry)
            return
        self.answer(200, kept["body"], {**kept["headers"], "ETag": '"' + hashlib.md5(kept["body"]).hexdigest() + '"'}, entry)

    do_PUT = do_HEAD = do_GET = handle_one


class Public(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        name = self.path.partition("?")[0].lstrip("/")
        entry = {"side": "public", "method": "GET", "name": name}
        with lock:
            kept = objects.get(name)
        if kept is None:
            body, status, headers = b"not found", 404, {}
        else:
            body, status, headers = kept["body"], 200, {key: value for key, value in kept["headers"].items()
                                                       if not key.startswith("x-amz-meta-")}
            corrupt = os.path.join(self.server.config.state, "corrupt")
            if os.path.exists(corrupt) and open(corrupt).read().strip() == name and body:
                body = bytes([body[0] ^ 0xFF]) + body[1:]
                entry["corrupted"] = True
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("cf-cache-status", "MISS")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        entry["status"] = status
        log(self.server.config.state, entry)


def serve(handler, config, context):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    server.config = config
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def main():
    parser = argparse.ArgumentParser()
    for option in ("--state", "--cert", "--key", "--bucket", "--key-id", "--secret"):
        parser.add_argument(option, required=True)
    config = parser.parse_args()
    os.makedirs(config.state, exist_ok=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(config.cert, config.key)
    api, public = serve(API, config, context), serve(Public, config, context)
    print(api, public, flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    sys.exit(main())
