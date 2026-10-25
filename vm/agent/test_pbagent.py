#!/usr/bin/env python3
"""Tests for the PrivacyBrowser in-VM agent (pbagent.py).

Runs the real HTTP server with the mock Safari backend, so the whole request
path — routing, auth, body handling, validation — is exercised on any platform.

    python3 test_pbagent.py
"""
from __future__ import annotations

import http.client
import json
import threading
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
            for key in ("domain", "path", "name", "value", "secure", "httpOnly", "expires"):
                self.assertEqual(original[key], got[key], key)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
