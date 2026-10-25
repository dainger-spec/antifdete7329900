#!/usr/bin/env python3
"""Tests for the PrivacyBrowser in-VM agent (pbagent.py).

Runs the real HTTP server with the mock Safari backend, so the whole request
path — routing, auth, body handling, validation — is exercised on any platform.

    python3 test_pbagent.py
"""
from __future__ import annotations

import http.client
import json
import os
import threading
import time
import unittest

import pbagent

TOKEN = "test-token-abc123"


class AgentTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.backend = pbagent.MockSafariBackend()
        self.server = pbagent.make_server("127.0.0.1", 0, self.backend, TOKEN)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def request(self, method: str, path: str, *, body: bytes | None = None,
                token: str | None = TOKEN, content_type: str | None = None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers: dict[str, str] = {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if content_type is not None:
            headers["Content-Type"] = content_type
        try:
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.read(), dict(resp.getheaders())
        finally:
            conn.close()

    def post_json(self, path: str, obj, *, token: str | None = TOKEN):
        return self.request("POST", path, body=json.dumps(obj).encode(),
                            token=token, content_type="application/json")


class HealthAndAuthTests(AgentTestCase):
    def test_healthz_needs_no_token(self):
        status, body, _ = self.request("GET", "/healthz", token=None)
        self.assertEqual(status, 200)
        self.assertEqual(body, b"ok\n")

    def test_status_requires_token(self):
        status, _, headers = self.request("GET", "/status", token=None)
        self.assertEqual(status, 401)
        self.assertIn("WWW-Authenticate", headers)

    def test_status_rejects_wrong_token(self):
        status, _, _ = self.request("GET", "/status", token="nope")
        self.assertEqual(status, 401)

    def test_navigate_requires_token(self):
        status, _, _ = self.post_json("/navigate", {"url": "https://example.com"}, token=None)
        self.assertEqual(status, 401)
        # Unauthorized navigate must not touch Safari.
        self.assertFalse(self.backend.running)


class StatusTests(AgentTestCase):
    def test_status_reports_backend_and_state(self):
        status, body, headers = self.request("GET", "/status")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "application/json")
        data = json.loads(body)
        self.assertEqual(data["agent"], "pbagent")
        self.assertEqual(data["backend"], "mock")
        self.assertFalse(data["safari_running"])
        self.assertIsNone(data["current_url"])
        self.assertIn("uptime_seconds", data)

    def test_status_tracks_navigation(self):
        self.post_json("/navigate", {"url": "https://browserleaks.com/"})
        _, body, _ = self.request("GET", "/status")
        data = json.loads(body)
        self.assertTrue(data["safari_running"])
        self.assertEqual(data["current_url"], "https://browserleaks.com/")


class NavigateTests(AgentTestCase):
    def test_navigate_opens_url(self):
        status, body, _ = self.post_json("/navigate", {"url": "https://example.com/path?q=1"})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["navigated_to"], "https://example.com/path?q=1")
        self.assertEqual(self.backend.current_url, "https://example.com/path?q=1")

    def test_navigate_rejects_non_http_scheme(self):
        for bad in ("javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "ftp://h/"):
            status, _, _ = self.post_json("/navigate", {"url": bad})
            self.assertEqual(status, 400, bad)
        self.assertFalse(self.backend.running)

    def test_navigate_rejects_missing_or_bad_url(self):
        self.assertEqual(self.post_json("/navigate", {})[0], 400)
        self.assertEqual(self.post_json("/navigate", {"url": 123})[0], 400)
        self.assertEqual(self.post_json("/navigate", {"url": "https://x\nHost: y"})[0], 400)

    def test_navigate_rejects_invalid_json(self):
        status, _, _ = self.request("POST", "/navigate", body=b"{not json",
                                    content_type="application/json")
        self.assertEqual(status, 400)

    def test_navigate_requires_content_length(self):
        # Chunked body -> 411.
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.putrequest("POST", "/navigate")
            conn.putheader("Authorization", f"Bearer {TOKEN}")
            conn.putheader("Transfer-Encoding", "chunked")
            conn.endheaders()
            conn.send(b"0\r\n\r\n")
            self.assertEqual(conn.getresponse().status, 411)
        finally:
            conn.close()


class ScreenshotTests(AgentTestCase):
    def test_screenshot_returns_png(self):
        status, body, headers = self.request("GET", "/screenshot")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "image/png")
        self.assertTrue(body.startswith(b"\x89PNG\r\n\x1a\n"))


class CookieTests(AgentTestCase):
    SAMPLE = [
        {"domain": ".example.com", "path": "/", "name": "sid", "value": "abc",
         "secure": True, "httpOnly": True, "expires": 2000000000},
        {"domain": "x.com", "path": "/", "name": "t", "value": "v"},
    ]

    def test_cookies_applied_to_backend(self):
        status, body, _ = self.post_json("/cookies", {"cookies": self.SAMPLE})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["applied"], 2)
        self.assertEqual(self.backend.cookies, self.SAMPLE)

    def test_cookies_requires_token(self):
        status, _, _ = self.post_json("/cookies", {"cookies": self.SAMPLE}, token=None)
        self.assertEqual(status, 401)
        self.assertEqual(self.backend.cookies, [])

    def test_cookies_rejects_bad_shape(self):
        self.assertEqual(self.post_json("/cookies", {"cookies": "nope"})[0], 400)
        self.assertEqual(self.post_json("/cookies", {"cookies": [{"name": "x"}]})[0], 400, "missing domain/value")
        self.assertEqual(self.post_json("/cookies", {})[0], 400)
        self.assertEqual(self.backend.cookies, [])

    def test_empty_cookie_list_is_ok(self):
        status, body, _ = self.post_json("/cookies", {"cookies": []})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["applied"], 0)


class BinaryCookieEncoderTests(unittest.TestCase):
    def test_round_trip(self):
        import binarycookies
        cookies = [
            {"domain": ".example.com", "path": "/", "name": "sid", "value": "abc",
             "secure": True, "httpOnly": True, "expires": 2000000000},
            {"domain": "x.com", "path": "/app", "name": "t", "value": "v",
             "secure": False, "httpOnly": False, "expires": None},
        ]
        blob = binarycookies.encode(cookies, now=1700000000)
        self.assertEqual(blob[:4], b"cook")
        decoded = binarycookies.decode(blob)
        for original, got in zip(cookies, decoded):
            for key in ("domain", "path", "name", "value", "secure", "httpOnly"):
                self.assertEqual(original[key], got[key], key)
        self.assertEqual(decoded[0]["expires"], 2000000000)
        # No expiry: 0 would mean 2001-01-01 (expired); a session cookie lives on.
        self.assertEqual(decoded[1]["expires"], 1700000000 + binarycookies.SESSION_LIFETIME)

    def test_raw_flags_survive_a_round_trip(self):
        import binarycookies
        blob = binarycookies.encode([{"domain": "a.com", "name": "n", "value": "v", "_flags": 0x2D}])
        again = binarycookies.encode(binarycookies.decode(blob))
        self.assertEqual(binarycookies.decode(again)[0]["_flags"], 0x2D)

    def test_merge_keeps_in_vm_cookies(self):
        import binarycookies
        existing = [{"domain": "a.com", "name": "sid", "path": "/", "value": "logged-in-in-vm"},
                    {"domain": "b.com", "name": "sid", "path": "/", "value": "old"}]
        incoming = [{"domain": "b.com", "name": "sid", "path": "/", "value": "imported"}]
        merged = binarycookies.merge(existing, incoming)
        self.assertEqual({(c["domain"], c["value"]) for c in merged},
                         {("a.com", "logged-in-in-vm"), ("b.com", "imported")})

    def test_try_decode_rejects_garbage(self):
        import binarycookies
        self.assertIsNone(binarycookies.try_decode(b"not a store"))
        self.assertEqual(binarycookies.try_decode(b""), [])

    def test_empty(self):
        import binarycookies
        self.assertEqual(binarycookies.decode(binarycookies.encode([])), [])


class QuitAndMethodTests(AgentTestCase):
    def test_quit_stops_safari(self):
        self.post_json("/navigate", {"url": "https://example.com"})
        self.assertTrue(self.backend.running)
        status, body, _ = self.request("POST", "/quit")
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["quit"])
        self.assertFalse(self.backend.running)

    def test_unknown_path_is_404(self):
        self.assertEqual(self.request("GET", "/nope")[0], 404)

    def test_wrong_method_is_405(self):
        status, _, headers = self.request("PUT", "/status")
        self.assertEqual(status, 405)
        self.assertIn("Allow", headers)
        # GET-only endpoint via POST.
        status, _, headers = self.request("POST", "/status")
        self.assertEqual(status, 405)
        self.assertEqual(headers.get("Allow"), "GET")

    def test_keep_alive_serves_several_requests(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            for _ in range(3):
                conn.request("GET", "/healthz")
                resp = conn.getresponse()
                self.assertEqual(resp.status, 200)
                resp.read()
        finally:
            conn.close()


class KioskTests(AgentTestCase):
    def test_kiosk_toggles_fill_screen(self):
        status, body, _ = self.post_json("/kiosk", {"fill_screen": True})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"fill_screen": True})
        self.assertTrue(self.backend.fill_screen)
        status, body, _ = self.request("GET", "/status", token=TOKEN)
        self.assertTrue(json.loads(body)["fill_screen"])
        self.post_json("/kiosk", {"fill_screen": False})
        self.assertFalse(self.backend.fill_screen)

    def test_kiosk_needs_auth_and_a_bool(self):
        self.assertEqual(self.post_json("/kiosk", {"fill_screen": True}, token=None)[0], 401)
        self.assertEqual(self.post_json("/kiosk", {"fill_screen": "yes"})[0], 400)
        self.assertEqual(self.post_json("/kiosk", {})[0], 400)
        self.assertFalse(self.backend.fill_screen)


class MacBackendCommandTests(unittest.TestCase):
    """The mac backend's command lines, with subprocess.run replaced: what runs
    in the VM must never put the URL into a shell or into script text."""

    def setUp(self) -> None:
        self.calls: list[tuple[list[str], dict]] = []
        self.returncode = 0
        self.original_run = pbagent.subprocess.run

        def fake_run(argv, **kwargs):
            self.calls.append((list(argv), kwargs))
            return pbagent.subprocess.CompletedProcess(argv, self.returncode, stdout="", stderr="boom")

        pbagent.subprocess.run = fake_run
        self.backend = pbagent.MacSafariBackend()

    def tearDown(self) -> None:
        pbagent.subprocess.run = self.original_run

    def test_navigate_uses_open_with_url_as_one_argument(self):
        url = 'https://example.com/a"b\'c;$(touch /tmp/x)'
        self.backend.navigate(url)
        argv, kwargs = self.calls[-1]
        self.assertEqual(argv, ["open", "-a", "Safari", url])
        self.assertNotIn("shell", kwargs)
        self.assertNotIn("input", kwargs)  # no script text at all

    def test_navigate_needs_no_apple_events(self):
        self.backend.navigate("https://example.com")
        self.backend.status()
        self.assertFalse(any(argv[0] == "osascript" for argv, _ in self.calls))

    def test_status_reports_last_opened_url_while_running(self):
        self.backend.navigate("https://example.com/")
        self.assertEqual(self.backend.status(), {"running": True, "current_url": "https://example.com/"})
        self.assertEqual(self.calls[-1][0], ["pgrep", "-x", "Safari"])
        self.returncode = 1  # pgrep: no Safari process
        self.assertEqual(self.backend.status(), {"running": False, "current_url": None})

    def test_failed_open_is_a_backend_error(self):
        self.returncode = 1
        with self.assertRaises(pbagent.SafariError):
            self.backend.navigate("https://example.com")

    def test_missing_tool_is_a_backend_error(self):
        def missing(argv, **kwargs):
            raise FileNotFoundError(argv[0])

        pbagent.subprocess.run = missing
        with self.assertRaises(pbagent.SafariError):
            self.backend.navigate("https://example.com")
        self.assertEqual(self.backend.status()["running"], False)


class MacApplyCookiesTests(unittest.TestCase):
    """apply_cookies against a real file: merges, never wipes in-VM cookies."""

    def setUp(self) -> None:
        import tempfile as _tempfile
        self.dir = _tempfile.mkdtemp()
        self.store = os.path.join(self.dir, "Cookies", "Cookies.binarycookies")
        self.env = os.environ.get("PB_SAFARI_COOKIES")
        os.environ["PB_SAFARI_COOKIES"] = self.store
        self.safari = ["running"]
        self.calls: list[list[str]] = []
        self.original_run = pbagent.subprocess.run

        def fake_run(argv, **kwargs):
            self.calls.append(list(argv))
            if argv[0] == "pgrep":
                return pbagent.subprocess.CompletedProcess(argv, 0 if self.safari else 1, "", "")
            if argv[0] == "pkill":
                self.safari.clear()
            return pbagent.subprocess.CompletedProcess(argv, 0, "", "")

        pbagent.subprocess.run = fake_run
        self.backend = pbagent.MacSafariBackend()

    def tearDown(self) -> None:
        import shutil
        pbagent.subprocess.run = self.original_run
        if self.env is None:
            os.environ.pop("PB_SAFARI_COOKIES", None)
        else:
            os.environ["PB_SAFARI_COOKIES"] = self.env
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_merges_and_quits_safari_without_apple_events(self):
        import binarycookies
        os.makedirs(os.path.dirname(self.store))
        with open(self.store, "wb") as fh:
            fh.write(binarycookies.encode([{"domain": "mail.com", "name": "sid", "value": "made-in-vm"}]))
        applied = self.backend.apply_cookies([{"domain": "shop.com", "name": "sid", "value": "imported"}])
        self.assertEqual(applied, 1)
        with open(self.store, "rb") as fh:
            values = {c["domain"]: c["value"] for c in binarycookies.decode(fh.read())}
        self.assertEqual(values, {"mail.com": "made-in-vm", "shop.com": "imported"})
        self.assertIn(["pkill", "-x", "Safari"], self.calls)
        self.assertFalse(any(argv[0] == "osascript" for argv in self.calls))
        self.assertEqual(os.listdir(os.path.dirname(self.store)), ["Cookies.binarycookies"], "no temp left")

    def test_unreadable_store_is_kept_aside(self):
        os.makedirs(os.path.dirname(self.store))
        with open(self.store, "wb") as fh:
            fh.write(b"garbage")
        self.backend.apply_cookies([{"domain": "a.com", "name": "n", "value": "v"}])
        names = os.listdir(os.path.dirname(self.store))
        self.assertTrue(any(n.startswith("Cookies.binarycookies.unreadable-") for n in names))


class MacFillScreenTests(unittest.TestCase):
    """The fill loop with subprocess.run replaced: AppleScript via stdin, only
    while Safari runs, and it stops when switched off."""

    def setUp(self) -> None:
        self.calls: list[list[str]] = []
        self.safari_running = True
        self.original_run = pbagent.subprocess.run

        def fake_run(argv, **kwargs):
            self.calls.append(list(argv))
            if argv[0] == "pgrep":
                return pbagent.subprocess.CompletedProcess(argv, 0 if self.safari_running else 1, "", "")
            self.scripts.append(kwargs.get("input", ""))
            return pbagent.subprocess.CompletedProcess(argv, 0, "1280x800\n", "")

        self.scripts: list[str] = []
        pbagent.subprocess.run = fake_run
        self.backend = pbagent.MacSafariBackend()
        self.backend.FILL_INTERVAL = 0.01

    def tearDown(self) -> None:
        self.backend.set_fill_screen(False)
        pbagent.subprocess.run = self.original_run

    def _wait_for(self, predicate, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return True
            time.sleep(0.01)
        return False

    def test_fills_while_safari_runs_and_stops_when_off(self):
        self.assertTrue(self.backend.set_fill_screen(True))
        self.assertTrue(self._wait_for(lambda: len(self.scripts) >= 2))
        self.assertIn('tell application "Safari"', self.scripts[0])
        self.assertIn("NSScreen's mainScreen()", self.scripts[0])
        self.assertTrue(all(argv[:2] == ["osascript", "-"] for argv in self.calls if argv[0] == "osascript"),
                        "script text goes over stdin, nothing in argv")
        self.backend.set_fill_screen(False)
        time.sleep(0.1)
        settled = len(self.scripts)
        time.sleep(0.1)
        self.assertEqual(len(self.scripts), settled, "no more passes once off")

    def test_no_apple_events_while_safari_is_not_running(self):
        self.safari_running = False
        self.backend.set_fill_screen(True)
        self.assertTrue(self._wait_for(lambda: len(self.calls) >= 3))
        self.assertEqual(self.scripts, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
