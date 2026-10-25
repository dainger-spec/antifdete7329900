#!/usr/bin/env python3
"""Tests for pbsync_server.py against docs/SYNC_SERVER_API.md.  Run: python3 server/test_pbsync_server.py"""
import http.client
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pbsync_server  # noqa: E402

VAULT = "7c1e2f3a-0b4c-4d5e-8f60-718293a4b5c6"
OTHER = "00000000-1111-4222-8333-444455556666"
OBJ = "a" * 64


class ServerTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        db = os.path.join(self.tmp, "sync.db")
        self.server = pbsync_server.make_server("127.0.0.1", 0, db, base_path="/api", max_blob=1024)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.token = self.server.store.add_token(VAULT, "test")
        self.any_token = self.server.store.add_token("*", "admin")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server.store.close_thread_connection()
        shutil.rmtree(self.tmp)

    def request(self, method, path, body=None, headers=None, token="default"):
        headers = dict(headers or {})
        if token == "default":
            token = self.token
        if token:
            headers["Authorization"] = f"Bearer {token}"
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(method, "/api" + path, body=body, headers=headers)
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def put(self, obj, revision, data, if_match=None, create=False, **kwargs):
        headers = {"Content-Type": "application/octet-stream", "X-PB-Revision": str(revision)}
        if if_match is not None:
            headers["If-Match"] = f'"{if_match}"'
        if create:
            headers["If-None-Match"] = "*"
        return self.request("PUT", f"/v1/vaults/{VAULT}/objects/{obj}", data, headers, **kwargs)


class ApiTests(ServerTestCase):
    def test_health_needs_no_token(self):
        status, _, body = self.request("GET", "/healthz", token=None)
        self.assertEqual((status, body), (200, b"ok\n"))

    def test_auth(self):
        path = f"/v1/vaults/{VAULT}/objects"
        self.assertEqual(self.request("GET", path, token=None)[0], 401)
        self.assertEqual(self.request("GET", path, token="wrong")[0], 401)
        self.assertEqual(self.request("GET", f"/v1/vaults/{OTHER}/objects")[0], 403)
        self.assertEqual(self.request("GET", f"/v1/vaults/{OTHER}/objects", token=self.any_token)[0], 200)
        token_id = self.server.store.list_tokens()[0][0]
        self.server.store.revoke_token(token_id)
        self.assertEqual(self.request("GET", path)[0], 401)

    def test_validation(self):
        self.assertEqual(self.request("GET", f"/v1/vaults/{VAULT.upper()}/objects")[0], 400)
        self.assertEqual(self.request("GET", f"/v1/vaults/{VAULT}/objects/../../x")[0], 404)
        self.assertEqual(self.request("GET", f"/v1/vaults/{VAULT}/objects/{'g' * 64}")[0], 400)
        self.assertEqual(self.request("GET", f"/v1/vaults/{VAULT}/objects/{'a' * 63}")[0], 400)
        self.assertEqual(self.request("GET", f"/v2/vaults/{VAULT}/objects")[0], 404)
        self.assertEqual(self.put(OBJ, 1, b"x")[0], 428)
        self.assertEqual(self.put(OBJ, 0, b"x", create=True)[0], 400)
        self.assertEqual(self.put(OBJ, "abc", b"x", create=True)[0], 400)
        self.assertEqual(self.put(OBJ, 1, b"x" * 1025, create=True)[0], 413)
        self.assertEqual(self.request("DELETE", f"/v1/vaults/{VAULT}/objects/{OBJ}")[0], 405)

    def test_list_fetch_and_compare_and_swap(self):
        status, _, body = self.request("GET", f"/v1/vaults/{VAULT}/objects")
        self.assertEqual((status, json.loads(body)), (200, {"objects": []}))
        self.assertEqual(self.request("GET", f"/v1/vaults/{VAULT}/objects/{OBJ}")[0], 404)

        status, headers, _ = self.put(OBJ, 1, b"one", create=True)
        self.assertEqual((status, headers["ETag"]), (201, '"1"'))
        status, headers, _ = self.put(OBJ, 1, b"again", create=True)
        self.assertEqual((status, headers["ETag"]), (412, '"1"'), "create must fail when the object exists")

        status, headers, body = self.request("GET", f"/v1/vaults/{VAULT}/objects/{OBJ}")
        self.assertEqual((status, headers["ETag"], body), (200, '"1"', b"one"))
        self.assertEqual(headers["Content-Type"], "application/octet-stream")

        self.assertEqual(self.put(OBJ, 3, b"three", if_match=1)[0], 200)
        status, headers, _ = self.put(OBJ, 4, b"lost race", if_match=1)
        self.assertEqual((status, headers["ETag"]), (412, '"3"'))
        self.assertEqual(self.put(OBJ, 3, b"same revision", if_match=3)[0], 400)
        self.assertEqual(self.put("b" * 64, 2, b"x", if_match=1)[0], 412, "If-Match on a missing object")
        self.assertEqual(self.put("vault-header", 1, b"{}", create=True)[0], 201)

        status, _, body = self.request("GET", f"/v1/vaults/{VAULT}/objects")
        self.assertEqual(json.loads(body), {"objects": [{"id": OBJ, "revision": 3},
                                                        {"id": "vault-header", "revision": 1}]})
        # Vaults are separate.
        status, _, body = self.request("GET", f"/v1/vaults/{OTHER}/objects", token=self.any_token)
        self.assertEqual(json.loads(body), {"objects": []})

    def test_concurrent_writers_exactly_one_wins(self):
        self.assertEqual(self.put(OBJ, 1, b"base", create=True)[0], 201)
        results = []
        lock = threading.Lock()

        def writer(n):
            status = self.put(OBJ, 2, f"writer {n}".encode(), if_match=1)[0]
            with lock:
                results.append(status)

        threads = [threading.Thread(target=writer, args=(n,)) for n in range(16)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(sorted(results), [200] + [412] * 15)
        _, headers, body = self.request("GET", f"/v1/vaults/{VAULT}/objects/{OBJ}")
        self.assertEqual(headers["ETag"], '"2"')
        self.assertTrue(body.startswith(b"writer "))

    def test_keep_alive_connection_serves_several_requests(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            for _ in range(3):
                conn.request("GET", f"/api/v1/vaults/{VAULT}/objects", headers={"Authorization": f"Bearer {self.token}"})
                response = conn.getresponse()
                response.read()
                self.assertEqual(response.status, 200)
        finally:
            conn.close()

    def test_tokens_are_stored_hashed(self):
        rows = self.server.store.db.execute("SELECT token_hash FROM tokens").fetchall()
        self.assertNotIn(self.token, [r[0] for r in rows])
        self.assertIn(pbsync_server.Store.hash_token(self.token), [r[0] for r in rows])


if __name__ == "__main__":
    unittest.main(verbosity=2)
