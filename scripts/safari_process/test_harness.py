#!/usr/bin/env python3
"""Tests for harness.py that run anywhere (Linux CI too): JA4 against the examples of the FoxIO
specification, ClientHello and HTTP/2 capture with curl as the client, and the report server's
bookkeeping. `python3 scripts/safari_process/test_harness.py`"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402


class JA4Spec(unittest.TestCase):
    # technical_details/JA4.md, "Example": t13d1516h2_8daaf6152771_e5627efa2ab1
    CIPHERS = [0x1301, 0x1302, 0x1303, 0xC02B, 0xC02F, 0xC02C, 0xC030, 0xCCA9, 0xCCA8, 0xC013, 0xC014, 0x009C,
               0x009D, 0x002F, 0x0035]
    EXTENSIONS = [0x001B, 0x0000, 0x0033, 0x0010, 0x4469, 0x0017, 0x002D, 0x000D, 0x0005, 0x0023, 0x0012, 0x002B,
                  0xFF01, 0x000B, 0x000A, 0x0015]
    SIGS = [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601]

    def test_example(self):
        value, raw = harness.ja4_parts(self.CIPHERS + [0x0A0A], self.EXTENSIONS + [0x1A1A], True, [0x0304, 0x0303],
                                       0x0303, b"h2", self.SIGS)
        self.assertEqual(value, "t13d1516h2_8daaf6152771_e5627efa2ab1")
        self.assertTrue(raw.startswith("t13d1516h2_002f,0035,009c"))

    def test_no_signature_algorithms(self):
        value, _ = harness.ja4_parts(self.CIPHERS, self.EXTENSIONS, True, [0x0304], 0x0303, b"h2", [])
        self.assertTrue(value.endswith("_6d807ffa2a79"), value)

    def test_alpn_rules(self):
        self.assertEqual(harness._alpn_chars(b"http/1.1"), "h1")
        self.assertEqual(harness._alpn_chars(b""), "00")
        self.assertEqual(harness._alpn_chars(b"\xab\xcd"), "ad")
        self.assertEqual(harness._alpn_chars(b"\x30\xab\xcd\x31"), "01")

    def test_grease(self):
        self.assertTrue(all(harness.is_grease(v) for v in range(0x0A0A, 0x10000, 0x1010)))
        self.assertFalse(harness.is_grease(0x0A1A))


def make_certificate(directory, names):
    ext = os.path.join(directory, "ext.cnf")
    with open(ext, "w") as handle:
        handle.write("subjectAltName=" + ",".join(f"DNS:{n}" for n in names) + "\n"
                     "extendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n")
    key, cert = os.path.join(directory, "leaf.key"), os.path.join(directory, "leaf.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                    "-days", "2", "-subj", f"/CN={names[0]}", "-extensions", "v3", "-config", "/dev/stdin"],
                   input=("[req]\ndistinguished_name=dn\n[dn]\n[v3]\nsubjectAltName=" +
                          ",".join(f"DNS:{n}" for n in names) + "\n").encode(),
                   check=True, capture_output=True)
    return cert, key


@unittest.skipUnless(shutil.which("curl") and shutil.which("openssl"), "needs curl and openssl")
class Capture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp()
        self.cert, self.key = make_certificate(self.directory, ["a.sp-tls.test"])

    def curl(self, server, *flags):
        return subprocess.run(["curl", "-sS", "--max-time", "10", "-k", "--noproxy", "*", *flags,
                               "--resolve", f"a.sp-tls.test:{server.port}:127.0.0.1",
                               f"https://a.sp-tls.test:{server.port}/x"], capture_output=True, text=True)

    def wait_records(self, server, count=1):
        import time
        for _ in range(100):
            records = server.for_host("a.sp-tls.test")
            if len(records) >= count and all("time" in r for r in records):
                return records
            time.sleep(0.05)
        return server.for_host("a.sp-tls.test")

    def test_client_hello_and_http2(self):
        server = harness.TLSServer(cert=self.cert, key=self.key)
        try:
            result = self.curl(server, "--http2")
            records = self.wait_records(server)
        finally:
            server.close()
        self.assertEqual(result.stdout, "ok", result.stderr)
        record = records[0]
        self.assertEqual(record["sni"], "a.sp-tls.test")
        self.assertRegex(record["ja4"], r"^t13d\d{4}h2_[0-9a-f]{12}_[0-9a-f]{12}$")
        self.assertEqual(record["negotiated"]["alpn"], "h2")
        http2 = record["http2"]
        # SETTINGS|WINDOW_UPDATE|PRIORITY|pseudo-header order, the last as the HEADERS frame lists them
        self.assertRegex(http2["akamai"], r"^(\d+:\d+;?)+\|\d+\|[^|]+\|[msap](,[msap]){3}$")
        pseudo = [n[1] for n in http2["header_order"] if n.startswith(":")]
        self.assertEqual(http2["akamai"].split("|")[3], ",".join(pseudo))
        self.assertEqual(sorted(pseudo), ["a", "m", "p", "s"])
        self.assertIn("SETTINGS[", http2["frames"])
        self.assertIn("user-agent", http2["header_order"])
        self.assertNotIn("sni", record["stable"])
        self.assertIn("alpn", record["stable"])

    def test_client_hello_without_certificate(self):
        server = harness.TLSServer()
        try:
            self.curl(server, "--http2")
            records = self.wait_records(server)
        finally:
            server.close()
        self.assertTrue(records and records[0]["ja4"].startswith("t13d"), records)
        self.assertNotIn("http2", records[0])

    def test_http1(self):
        server = harness.TLSServer(cert=self.cert, key=self.key)
        try:
            result = self.curl(server, "--http1.1", "-H", "X-Test: 1")
            records = self.wait_records(server)
        finally:
            server.close()
        self.assertEqual(result.stdout, "ok", result.stderr)
        self.assertEqual(records[0]["negotiated"]["alpn"], "http/1.1")
        self.assertIn("X-Test", records[0]["http1"]["header_order"])


@unittest.skipUnless(shutil.which("curl") and shutil.which("openssl"), "needs curl and openssl")
class Proxy(unittest.TestCase):
    def test_connect_is_forwarded_and_logged(self):
        directory = tempfile.mkdtemp()
        cert, key = make_certificate(directory, ["localhost"])
        server, proxy = harness.TLSServer(cert=cert, key=key), harness.ConnectProxy()
        try:
            result = subprocess.run(["curl", "-sS", "--max-time", "10", "-k", "--proxy",
                                     f"http://127.0.0.1:{proxy.port}", f"https://localhost:{server.port}/p"],
                                    capture_output=True, text=True, env=dict(os.environ, NO_PROXY="", no_proxy=""))
        finally:
            server.close()
            proxy.close()
        self.assertEqual(result.stdout, "ok", result.stderr)
        self.assertIn(f"CONNECT localhost:{server.port} HTTP/1.1", proxy.hosts())


class Reports(unittest.TestCase):
    def test_tags_and_events(self):
        server = harness.ReportServer()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            page = opener.open(server.url("/run?inst=A&seed=1")).read().decode()
            self.assertIn("sp-run", page)
            body = json.dumps({"inst": "A", "run": "1", "phase": "seeded", "documentCookie": "sp_js_A=A; other=1",
                               "localStorage": ["sp_A"], "indexedDB": ["sp_A", "sp_B"]}).encode()
            request = urllib.request.Request(server.url("/report"), data=body, method="POST",
                                             headers={"Cookie": "sp_http_A=A; sp_js_A=A", "Content-Type": "application/json"})
            opener.open(request).read()
            seeded = server.wait("A", "seeded", timeout=2)
            self.assertEqual(seeded["tags"], {"httpOnlyCookie": ["A"], "scriptCookie": ["A"], "documentCookie": ["A"],
                                              "localStorage": ["A"], "indexedDB": ["A", "B"]})
            self.assertEqual(opener.open(server.url("/await?event=A:seeded&timeout=1")).status, 200)
            with self.assertRaises(urllib.error.HTTPError):
                opener.open(server.url("/await?event=B:seeded&timeout=0.2"))
        finally:
            server.close()

    def test_app_start_page_follows_the_plan(self):
        server = harness.ReportServer()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            self.assertIn("<title>SPWA-A</title>", opener.open(server.url("/app?name=A")).read().decode())
            server.set_plan("A", server.url("/run?inst=wa&run=1"))
            self.assertIn("sp-run", opener.open(server.url("/app?name=A")).read().decode())
            server.set_plan("A", None)
            self.assertIn("SPWA-A", opener.open(server.url("/app?name=A")).read().decode())
        finally:
            server.close()


class HPACKFallback(unittest.TestCase):
    def test_static_and_literal_names(self):
        # :method GET (0x82), :scheme https (0x87), :path / (0x84), :authority literal with indexing
        # (0x41, plain "a.test"), user-agent literal without indexing name index 58 (0x0f 0x2b), plain value
        block = bytes([0x82, 0x87, 0x84, 0x41, 6]) + b"a.test" + bytes([0x0F, 0x2B, 1]) + b"x"
        names = harness.header_names(block)
        self.assertEqual(names, [":method", ":scheme", ":path", ":authority", "user-agent"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
