#!/usr/bin/env python3
"""PrivacyBrowser in-VM agent.

A small HTTP service that runs *inside* each macOS VM and lets the host
controller drive the VM's real Safari. See vm/agent/README.md and
docs/VM_ARCHITECTURE.md.

Design mirrors server/pbsync_server.py: Python 3.9+ standard library only,
ThreadingHTTPServer, bearer-token auth (constant-time compare), and careful
request handling. It never logs headers or bodies.

The agent binds to 127.0.0.1 by default. The controller reaches it through an
SSH tunnel to the VM (see vm/controller/tart-prototype.sh), so the control
port is never exposed on the VM's network interface.

Endpoints (all but /healthz require `Authorization: Bearer <token>`):

    GET  /healthz     -> "ok"                 (liveness, no auth)
    GET  /status      -> JSON agent + Safari state
    POST /navigate    {"url": "https://..."}  open/focus Safari at url
    POST /cookies     {"cookies": [ ... ]}     install cookies into Safari
    GET  /screenshot  -> image/png            screen capture
    POST /quit        -> quit Safari

Safari is driven through a pluggable backend so the server logic can be unit
tested off a Mac:

    PB_AGENT_BACKEND=mac    open -a Safari, pgrep, screencapture   (default)
    PB_AGENT_BACKEND=mock   in-memory, for tests / CI on any platform

Run:

    PB_AGENT_TOKEN=... python3 pbagent.py serve --host 127.0.0.1 --port 8777

With no token a fresh one is generated and printed once on startup.
"""
from __future__ import annotations

import argparse
import hmac
import json
import logging
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time

import binarycookies
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AGENT_VERSION = "1"
# Accept only plain http/https URLs with no control characters, so the value
# can be handed to the backend without surprises. On macOS it becomes one argv
# item of `open -a Safari` (no shell, no script text), so it cannot inject
# commands or AppleScript, and the scheme check keeps out file:/javascript:.
URL_RE = re.compile(r"^https?://[^\s\x00-\x1f\x7f]{1,4000}$")
MAX_BODY = 1024 * 1024  # navigate bodies are tiny; /cookies can carry many cookies.

log = logging.getLogger("pbagent")


# ---------------------------------------------------------------------------------------------
# Safari backends
# ---------------------------------------------------------------------------------------------

class SafariError(RuntimeError):
    """A backend command failed."""


class SafariBackend:
    """Interface the HTTP layer depends on."""

    name = "base"

    def navigate(self, url: str) -> None:
        raise NotImplementedError

    def status(self) -> dict:
        """{"running": bool, "current_url": str | None}."""
        raise NotImplementedError

    def screenshot(self) -> bytes:
        """PNG bytes of the current screen."""
        raise NotImplementedError

    def quit(self) -> None:
        raise NotImplementedError

    def apply_cookies(self, cookies: list) -> int:
        """Install `cookies` (normalized dicts) into Safari; returns the count."""
        raise NotImplementedError


class MacSafariBackend(SafariBackend):
    """Drives the real Safari. macOS only.

    Navigation and the "is Safari running" check deliberately avoid Apple
    Events: the first `tell application "Safari"` from a new client pops an
    Automation (TCC) consent dialog inside the VM and blocks until someone
    clicks it, which would hang /navigate and /status in an unattended VM.
    `open -a Safari <url>` goes through LaunchServices and needs no consent;
    the URL is a separate argv item (no shell, no script text). Only /quit
    still uses AppleScript, and /screenshot needs Screen Recording permission.
    """

    name = "mac"

    def __init__(self, timeout: float = 20.0):
        self.timeout = timeout
        self._last_url: str | None = None

    def _run(self, argv: list[str], what: str, **kwargs) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout, **kwargs)
        except FileNotFoundError as exc:  # not on macOS
            raise SafariError(f"{what} not found (agent must run inside a macOS VM)") from exc
        except subprocess.TimeoutExpired as exc:
            raise SafariError(f"{what} timed out") from exc

    def _osascript(self, script: str, *args: str) -> str:
        result = self._run(["osascript", "-", *args], "osascript", input=script)
        if result.returncode != 0:
            raise SafariError(result.stderr.strip() or "osascript failed")
        return result.stdout.strip()

    def navigate(self, url: str) -> None:
        result = self._run(["open", "-a", "Safari", url], "open")
        if result.returncode != 0:
            raise SafariError(result.stderr.strip() or "open failed")
        self._last_url = url

    def status(self) -> dict:
        # current_url is the last URL this agent opened: reading Safari's
        # front document would need Apple Events (see the class docstring).
        running = self._is_running()
        return {"running": running, "current_url": self._last_url if running else None}

    def _is_running(self) -> bool:
        try:
            result = self._run(["pgrep", "-x", "Safari"], "pgrep")
        except SafariError:
            return False
        return result.returncode == 0

    def screenshot(self) -> bytes:
        fd, path = tempfile.mkstemp(suffix=".png")
        os.close(fd)
        try:
            result = self._run(["screencapture", "-x", "-t", "png", path], "screencapture")
            if result.returncode != 0:
                raise SafariError(result.stderr.strip() or "screencapture failed")
            with open(path, "rb") as fh:
                data = fh.read()
            if not data:
                raise SafariError("screencapture produced an empty file")
            return data
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def quit(self) -> None:
        self._osascript('tell application "Safari" to quit')
        self._last_url = None

    # Safari keeps cookies in a sandboxed binary store. Replace it while Safari
    # is not running, then the next launch picks the cookies up. The exact
    # container path and whether the sandbox permits writing it is the one part
    # that needs verifying on a real Mac (see docs/PROFILES.md).
    DEFAULT_COOKIE_PATH = "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"

    def apply_cookies(self, cookies: list) -> int:
        blob = binarycookies.encode(cookies)
        path = os.path.expanduser(os.environ.get("PB_SAFARI_COOKIES") or self.DEFAULT_COOKIE_PATH)
        try:
            self.quit()  # don't fight Safari for the file
        except SafariError:
            pass
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as fh:
                fh.write(blob)
        except OSError as exc:
            raise SafariError(f"cannot write cookie store {path}: {exc}") from exc
        return len(cookies)


def _make_1x1_png() -> bytes:
    """A valid 1x1 transparent PNG, built from scratch so the mock backend
    returns something that is actually a decodable image."""
    import struct
    import zlib

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)  # 1x1, 8-bit RGBA
    idat = zlib.compress(b"\x00\x00\x00\x00\x00")         # one filtered scanline
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


# A valid 1x1 transparent PNG, so the mock backend returns a real image.
_MOCK_PNG = _make_1x1_png()


class MockSafariBackend(SafariBackend):
    """In-memory backend for tests and for running the agent off a Mac."""

    name = "mock"

    def __init__(self):
        self.running = False
        self.current_url: str | None = None
        self.cookies: list = []

    def navigate(self, url: str) -> None:
        self.running = True
        self.current_url = url

    def status(self) -> dict:
        return {"running": self.running, "current_url": self.current_url}

    def screenshot(self) -> bytes:
        return _MOCK_PNG

    def quit(self) -> None:
        self.running = False
        self.current_url = None

    def apply_cookies(self, cookies: list) -> int:
        self.cookies = list(cookies)
        return len(self.cookies)


def make_backend(name: str) -> SafariBackend:
    if name == "mac":
        return MacSafariBackend()
    if name == "mock":
        return MockSafariBackend()
    raise ValueError(f"unknown backend {name!r} (use 'mac' or 'mock')")


# ---------------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------------

class AgentHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pbagent/1"
    sys_version = ""

    @property
    def backend(self) -> SafariBackend:
        return self.server.backend  # type: ignore[attr-defined]

    def log_message(self, format: str, *args) -> None:  # noqa: A002 - BaseHTTPRequestHandler API
        # Never log headers or bodies (token, navigated URLs).
        log.info("%s %s", self.address_string(), format % args)

    # Responses

    def _send(self, status: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8",
              headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        if body or status not in (204, 304):
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload: dict) -> None:
        self._send(status, json.dumps(payload, separators=(",", ":")).encode(), "application/json")

    def _error(self, status: int, message: str, headers: dict[str, str] | None = None) -> None:
        self._send(status, (message + "\n").encode(), headers=headers)

    def _discard_body(self) -> None:
        length = self.headers.get("Content-Length")
        if length and length.isdigit() and int(length) <= MAX_BODY:
            self.rfile.read(int(length))
        else:
            self.close_connection = True

    def _read_json_body(self) -> dict | None:
        length_header = self.headers.get("Content-Length")
        if self.headers.get("Transfer-Encoding") or length_header is None or not length_header.isdigit():
            self.close_connection = True
            self._error(411, "Content-Length required")
            return None
        length = int(length_header)
        if length > MAX_BODY:
            self.close_connection = True
            self._error(413, "body too large")
            return None
        data = self.rfile.read(length)
        if len(data) != length:
            self.close_connection = True
            self._error(400, "truncated body")
            return None
        if not data:
            return {}
        try:
            payload = json.loads(data)
        except ValueError:
            self._error(400, "body is not valid JSON")
            return None
        if not isinstance(payload, dict):
            self._error(400, "body must be a JSON object")
            return None
        return payload

    # Auth

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "bearer" or not token.strip():
            self._error(401, "missing bearer token", {"WWW-Authenticate": 'Bearer realm="pbagent"'})
            return False
        expected = self.server.token  # type: ignore[attr-defined]
        if not hmac.compare_digest(token.strip(), expected):
            self._error(401, "invalid token",
                        {"WWW-Authenticate": 'Bearer realm="pbagent", error="invalid_token"'})
            return False
        return True

    def _path(self) -> str:
        return self.path.split("?", 1)[0].rstrip("/") or "/"

    # Methods

    def do_GET(self) -> None:  # noqa: N802
        path = self._path()
        if path == "/healthz":
            self._send(200, b"ok\n")
            return
        if not self._authorized():
            return
        if path == "/status":
            self._status()
        elif path == "/screenshot":
            self._screenshot()
        else:
            self._error(404, "not found")

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802
        path = self._path()
        # Read/validate auth before the body, but always drain the body so the
        # keep-alive connection stays usable.
        if path not in ("/navigate", "/quit", "/cookies"):
            self._discard_body()
            if path in ("/status", "/screenshot", "/healthz"):
                self._error(405, "method not allowed", {"Allow": "GET"})
            else:
                self._error(404, "not found")
            return
        if not self._authorized():
            self._discard_body()
            return
        if path == "/navigate":
            self._navigate()
        elif path == "/cookies":
            self._cookies()
        else:
            self._discard_body()
            self._quit()

    def do_PUT(self) -> None:  # noqa: N802
        self._discard_body()
        self._error(405, "method not allowed", {"Allow": "GET, POST"})

    do_DELETE = do_PUT
    do_PATCH = do_PUT

    # Handlers

    def _status(self) -> None:
        server = self.server  # type: ignore[attr-defined]
        try:
            state = self.backend.status()
        except SafariError as exc:
            self._error(502, f"backend error: {exc}")
            return
        self._json(200, {
            "agent": "pbagent",
            "version": AGENT_VERSION,
            "backend": self.backend.name,
            "started_at": server.started_at,
            "uptime_seconds": round(time.time() - server.started_at, 1),
            "safari_running": state["running"],
            "current_url": state["current_url"],
        })

    def _navigate(self) -> None:
        payload = self._read_json_body()
        if payload is None:
            return
        url = payload.get("url")
        if not isinstance(url, str) or not URL_RE.match(url):
            self._error(400, "url must be an http(s) URL")
            return
        try:
            self.backend.navigate(url)
        except SafariError as exc:
            self._error(502, f"backend error: {exc}")
            return
        self._json(200, {"navigated_to": url})

    def _cookies(self) -> None:
        payload = self._read_json_body()
        if payload is None:
            return
        cookies = payload.get("cookies")
        if not isinstance(cookies, list) or not all(isinstance(c, dict) for c in cookies):
            self._error(400, 'body must be {"cookies": [{domain,name,value,...}, ...]}')
            return
        for c in cookies:
            if not (isinstance(c.get("domain"), str) and isinstance(c.get("name"), str)
                    and isinstance(c.get("value"), str)):
                self._error(400, "each cookie needs string domain, name and value")
                return
        try:
            applied = self.backend.apply_cookies(cookies)
        except SafariError as exc:
            self._error(502, f"backend error: {exc}")
            return
        self._json(200, {"applied": applied})

    def _screenshot(self) -> None:
        try:
            data = self.backend.screenshot()
        except SafariError as exc:
            self._error(502, f"backend error: {exc}")
            return
        self._send(200, data, "image/png")

    def _quit(self) -> None:
        try:
            self.backend.quit()
        except SafariError as exc:
            self._error(502, f"backend error: {exc}")
            return
        self._json(200, {"quit": True})


class AgentServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, backend: SafariBackend, token: str):
        super().__init__(address, AgentHandler)
        self.backend = backend
        self.token = token
        self.started_at = time.time()


def make_server(host: str, port: int, backend: SafariBackend, token: str) -> AgentServer:
    return AgentServer((host, port), backend, token)


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="PrivacyBrowser in-VM agent")
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve", help="run the agent")
    serve.add_argument("--host", default="127.0.0.1",
                       help="bind address (default 127.0.0.1; reach it via an SSH tunnel)")
    serve.add_argument("--port", type=int, default=8777)
    serve.add_argument("--backend", default=os.environ.get("PB_AGENT_BACKEND", "mac"),
                       choices=["mac", "mock"], help="Safari backend (default mac)")
    serve.add_argument("--token", default=os.environ.get("PB_AGENT_TOKEN"),
                       help="bearer token (default: $PB_AGENT_TOKEN, else a generated one printed once)")

    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if args.command != "serve":
        parser.error("unknown command")

    token = (args.token or "").strip()
    generated = False
    if not token:
        token = secrets.token_urlsafe(32)
        generated = True

    try:
        backend = make_backend(args.backend)
    except ValueError as exc:
        parser.error(str(exc))

    server = make_server(args.host, args.port, backend, token)
    log.info("pbagent listening on http://%s:%d (backend=%s)",
             args.host, server.server_address[1], backend.name)
    if generated:
        # Printed once, like pbsync_server's add-token. The controller passes it
        # back via Authorization: Bearer.
        print(f"PB_AGENT_TOKEN={token}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
