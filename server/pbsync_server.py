#!/usr/bin/env python3
"""PrivacyBrowser sync server — implements docs/SYNC_SERVER_API.md (v1).

A dumb, end-to-end-encrypted blob store: every object it receives is already encrypted by the
client (except `vault-header`, which holds only the KDF salt/parameters and the wrapped vault
key). The server needs no crypto and never sees plaintext.

Python 3.9+ standard library only (http.server + sqlite3). One SQLite file holds tokens and
objects; compare-and-swap writes run inside `BEGIN IMMEDIATE` transactions, so the check of the
precondition and the write are atomic even with many threads or processes.

    # create the database and a token for one vault (or "*" for any vault)
    python3 pbsync_server.py add-token --db sync.db --vault 7c1e...-...  --label "MacBook"
    # serve (TLS directly, or plain HTTP on 127.0.0.1 behind a TLS reverse proxy)
    python3 pbsync_server.py serve --db sync.db --host 0.0.0.0 --port 8443 \
        --tls-cert fullchain.pem --tls-key privkey.pem
    # in the app: More → Sync… → Server: https://sync.example.com:8443  + the token

Tokens are stored as SHA-256 hashes; the plaintext is printed once by `add-token`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import secrets
import sqlite3
import ssl
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

API_VERSION = "v1"
VAULT_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
OBJECT_RE = re.compile(r"^(vault-header|[0-9a-f]{64})$")
ETAG_RE = re.compile(r'^\s*(?:W/)?"?(\d+)"?\s*$')
DEFAULT_MAX_BLOB = 16 * 1024 * 1024
MAX_REVISION = 2**62

SCHEMA = """
CREATE TABLE IF NOT EXISTS tokens (
    id          INTEGER PRIMARY KEY,
    token_hash  TEXT NOT NULL UNIQUE,
    vault       TEXT NOT NULL,              -- lowercase vault UUID, or '*' for any vault
    label       TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL,
    revoked     INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS objects (
    vault       TEXT NOT NULL,
    object      TEXT NOT NULL,
    revision    INTEGER NOT NULL,
    data        BLOB NOT NULL,
    updated_at  INTEGER NOT NULL,
    PRIMARY KEY (vault, object)
) WITHOUT ROWID;
"""

log = logging.getLogger("pbsync")


# ---------------------------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------------------------

class Store:
    """SQLite-backed storage. One connection per thread; WAL mode for concurrent readers."""

    def __init__(self, path: str):
        self.path = path
        self._local = threading.local()
        db = self._connect()
        try:
            db.executescript(SCHEMA)
        finally:
            db.close()
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    def _connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=30, isolation_level=None, check_same_thread=False)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=FULL")
        db.execute("PRAGMA busy_timeout=30000")
        return db

    @property
    def db(self) -> sqlite3.Connection:
        db = getattr(self._local, "db", None)
        if db is None:
            db = self._connect()
            self._local.db = db
        return db

    def close_thread_connection(self) -> None:
        db = getattr(self._local, "db", None)
        if db is not None:
            db.close()
            self._local.db = None

    # Tokens

    @staticmethod
    def hash_token(token: str) -> str:
        return hashlib.sha256(token.encode("utf-8")).hexdigest()

    def add_token(self, vault: str, label: str = "") -> str:
        token = secrets.token_urlsafe(32)
        self.db.execute("INSERT INTO tokens (token_hash, vault, label, created_at) VALUES (?, ?, ?, ?)",
                        (self.hash_token(token), vault, label, int(time.time())))
        return token

    def list_tokens(self) -> list[tuple]:
        return self.db.execute(
            "SELECT id, vault, label, created_at, revoked FROM tokens ORDER BY id").fetchall()

    def revoke_token(self, token_id: int) -> bool:
        return self.db.execute("UPDATE tokens SET revoked = 1 WHERE id = ?", (token_id,)).rowcount == 1

    def token_vault(self, token: str) -> str | None:
        row = self.db.execute("SELECT vault FROM tokens WHERE token_hash = ? AND revoked = 0",
                              (self.hash_token(token),)).fetchone()
        return row[0] if row else None

    # Objects

    def list_objects(self, vault: str) -> list[tuple[str, int]]:
        return self.db.execute("SELECT object, revision FROM objects WHERE vault = ? ORDER BY object",
                               (vault,)).fetchall()

    def fetch(self, vault: str, obj: str) -> tuple[int, bytes] | None:
        row = self.db.execute("SELECT revision, data FROM objects WHERE vault = ? AND object = ?",
                              (vault, obj)).fetchone()
        return (row[0], bytes(row[1])) if row else None

    def store(self, vault: str, obj: str, revision: int, data: bytes,
              if_match: int | None, if_none_match: bool) -> tuple[str, int | None]:
        """Compare-and-swap. Returns ("created"|"updated", revision), ("conflict", current)
        or ("stale", current) when the new revision does not increase."""
        db = self.db
        db.execute("BEGIN IMMEDIATE")
        try:
            row = db.execute("SELECT revision FROM objects WHERE vault = ? AND object = ?",
                             (vault, obj)).fetchone()
            current = row[0] if row else None
            if if_none_match and current is not None:
                db.execute("ROLLBACK")
                return "conflict", current
            if if_match is not None and current != if_match:
                db.execute("ROLLBACK")
                return "conflict", current
            if current is not None and revision <= current:
                db.execute("ROLLBACK")
                return "stale", current
            now = int(time.time())
            if current is None:
                db.execute("INSERT INTO objects (vault, object, revision, data, updated_at) VALUES (?, ?, ?, ?, ?)",
                           (vault, obj, revision, sqlite3.Binary(data), now))
                outcome = "created"
            else:
                db.execute("UPDATE objects SET revision = ?, data = ?, updated_at = ? WHERE vault = ? AND object = ?",
                           (revision, sqlite3.Binary(data), now, vault, obj))
                outcome = "updated"
            db.execute("COMMIT")
            return outcome, revision
        except BaseException:
            db.execute("ROLLBACK")
            raise


# ---------------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------------

class SyncHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pbsync/1"
    sys_version = ""

    # Set on the server object.
    @property
    def store(self) -> Store:
        return self.server.store  # type: ignore[attr-defined]

    def handle(self) -> None:
        # One handler thread per client connection: close its database connection with it.
        try:
            super().handle()
        finally:
            self.store.close_thread_connection()

    def log_message(self, format: str, *args) -> None:  # noqa: A002 - BaseHTTPRequestHandler API
        # Never log headers or bodies (tokens, blobs). Path contains only opaque IDs.
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

    def _error(self, status: int, message: str, headers: dict[str, str] | None = None) -> None:
        self._send(status, (message + "\n").encode(), headers=headers)

    def _discard_body(self) -> None:
        length = self.headers.get("Content-Length")
        if length and length.isdigit() and int(length) <= self.server.max_blob:  # type: ignore[attr-defined]
            self.rfile.read(int(length))
        else:
            self.close_connection = True

    # Routing

    def _route(self) -> tuple[str, str | None] | None:
        """Returns (vault, object|None) for an API path, None if the path is not an API path."""
        path = urlsplit(self.path).path
        base = self.server.base_path  # type: ignore[attr-defined]
        if base:
            if not path.startswith(base + "/"):
                return None
            path = path[len(base):]
        parts = [unquote(p) for p in path.split("/")]
        # ['', 'v1', 'vaults', '{vault}', 'objects'(, '{object}')]
        if len(parts) not in (5, 6) or parts[0] != "" or parts[1] != API_VERSION or parts[2] != "vaults" \
                or parts[4] != "objects":
            return None
        return parts[3], (parts[5] if len(parts) == 6 else None)

    def _authorize(self, vault: str) -> bool:
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "bearer" or not token.strip():
            self._error(401, "missing bearer token", {"WWW-Authenticate": 'Bearer realm="pbsync"'})
            return False
        allowed = self.store.token_vault(token.strip())
        if allowed is None:
            self._error(401, "invalid token", {"WWW-Authenticate": 'Bearer realm="pbsync", error="invalid_token"'})
            return False
        if allowed != "*" and allowed != vault:
            self._error(403, "token is not valid for this vault")
            return False
        return True

    def _resolve(self) -> tuple[str, str | None] | None:
        route = self._route()
        if route is None:
            self._error(404, "not found")
            return None
        vault, obj = route
        if not VAULT_RE.match(vault):
            self._error(400, "vault must be a lowercase UUID")
            return None
        if obj is not None and not OBJECT_RE.match(obj):
            self._error(400, "invalid object id")
            return None
        if not self._authorize(vault):
            return None
        return vault, obj

    # Methods

    def do_GET(self) -> None:  # noqa: N802
        if urlsplit(self.path).path in ("/healthz", (self.server.base_path or "") + "/healthz"):  # type: ignore[attr-defined]
            self._send(200, b"ok\n")
            return
        resolved = self._resolve()
        if resolved is None:
            return
        vault, obj = resolved
        if obj is None:
            objects = [{"id": o, "revision": r} for o, r in self.store.list_objects(vault)]
            self._send(200, json.dumps({"objects": objects}, separators=(",", ":")).encode(), "application/json")
            return
        found = self.store.fetch(vault, obj)
        if found is None:
            self._error(404, "object does not exist")
            return
        revision, data = found
        self._send(200, data, "application/octet-stream", {"ETag": f'"{revision}"'})

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_PUT(self) -> None:  # noqa: N802
        resolved = self._resolve()
        if resolved is None:
            self._discard_body()
            return
        vault, obj = resolved
        if obj is None:
            self._discard_body()
            self._error(405, "method not allowed", {"Allow": "GET"})
            return

        length_header = self.headers.get("Content-Length")
        if self.headers.get("Transfer-Encoding") or length_header is None or not length_header.isdigit():
            self.close_connection = True
            self._error(411, "Content-Length required")
            return
        length = int(length_header)
        if length > self.server.max_blob:  # type: ignore[attr-defined]
            self.close_connection = True
            self._error(413, f"blob too large (max {self.server.max_blob} bytes)")  # type: ignore[attr-defined]
            return
        data = self.rfile.read(length)
        if len(data) != length:
            self.close_connection = True
            self._error(400, "truncated body")
            return

        revision_header = self.headers.get("X-PB-Revision", "")
        if not revision_header.isdigit() or not (0 < int(revision_header) < MAX_REVISION):
            self._error(400, "X-PB-Revision must be a positive integer")
            return
        revision = int(revision_header)

        if_match_header = self.headers.get("If-Match")
        if_none_match = self.headers.get("If-None-Match", "").strip() == "*"
        if_match: int | None = None
        if if_match_header is not None:
            match = ETAG_RE.match(if_match_header)
            if not match:
                self._error(400, "If-Match must be a revision ETag")
                return
            if_match = int(match.group(1))
        if if_match is None and not if_none_match:
            self._error(428, "If-Match or If-None-Match: * required")
            return
        if if_match is not None and if_none_match:
            self._error(400, "use either If-Match or If-None-Match")
            return

        outcome, current = self.store.store(vault, obj, revision, data, if_match, if_none_match)
        if outcome == "conflict":
            headers = {"ETag": f'"{current}"'} if current is not None else {}
            self._error(412, "precondition failed", headers)
        elif outcome == "stale":
            self._error(400, f"revision must be greater than {current}", {"ETag": f'"{current}"'})
        else:
            self._send(201 if outcome == "created" else 200, b"", headers={"ETag": f'"{current}"'})

    def do_POST(self) -> None:  # noqa: N802
        self._discard_body()
        self._error(405, "method not allowed", {"Allow": "GET, PUT"})

    do_DELETE = do_POST
    do_PATCH = do_POST


class SyncServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, store: Store, base_path: str = "", max_blob: int = DEFAULT_MAX_BLOB):
        super().__init__(address, SyncHandler)
        self.store = store
        self.base_path = base_path.rstrip("/")
        self.max_blob = max_blob


def make_server(host: str, port: int, db_path: str, base_path: str = "", max_blob: int = DEFAULT_MAX_BLOB,
                tls_cert: str | None = None, tls_key: str | None = None) -> SyncServer:
    server = SyncServer((host, port), Store(db_path), base_path=base_path, max_blob=max_blob)
    if tls_cert:
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(tls_cert, tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    return server


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="PrivacyBrowser sync server (docs/SYNC_SERVER_API.md)")
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve", help="run the server")
    serve.add_argument("--db", required=True, help="SQLite database file (created if missing)")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8443)
    serve.add_argument("--base-path", default="", help='URL prefix, e.g. "/api" when the app uses https://host/api')
    serve.add_argument("--max-blob-mb", type=float, default=DEFAULT_MAX_BLOB / 1024 / 1024)
    serve.add_argument("--tls-cert", help="PEM certificate chain (omit only behind a TLS reverse proxy)")
    serve.add_argument("--tls-key", help="PEM private key")

    add = sub.add_parser("add-token", help="create an access token (printed once)")
    add.add_argument("--db", required=True)
    add.add_argument("--vault", required=True, help='vault UUID (shown in the app under Sync) or "*" for any vault')
    add.add_argument("--label", default="")

    lst = sub.add_parser("list-tokens", help="list tokens (hashes are not shown)")
    lst.add_argument("--db", required=True)

    rev = sub.add_parser("revoke-token", help="revoke a token by its id")
    rev.add_argument("--db", required=True)
    rev.add_argument("id", type=int)

    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if args.command == "add-token":
        vault = args.vault.strip().lower()
        if vault != "*" and not VAULT_RE.match(vault):
            parser.error("--vault must be a UUID or *")
        print(Store(args.db).add_token(vault, args.label))
        return 0
    if args.command == "list-tokens":
        for token_id, vault, label, created, revoked in Store(args.db).list_tokens():
            stamp = time.strftime("%Y-%m-%d %H:%M", time.gmtime(created))
            print(f"{token_id}\t{vault}\t{stamp}Z\t{'revoked' if revoked else 'active'}\t{label}")
        return 0
    if args.command == "revoke-token":
        if not Store(args.db).revoke_token(args.id):
            print(f"no token with id {args.id}", file=sys.stderr)
            return 1
        return 0

    if bool(args.tls_cert) != bool(args.tls_key):
        parser.error("--tls-cert and --tls-key go together")
    if not args.tls_cert and args.host not in ("127.0.0.1", "localhost", "::1"):
        log.warning("serving plain HTTP on %s: the app only accepts https:// — put a TLS reverse proxy in front",
                    args.host)
    server = make_server(args.host, args.port, args.db, args.base_path, int(args.max_blob_mb * 1024 * 1024),
                         args.tls_cert, args.tls_key)
    scheme = "https" if args.tls_cert else "http"
    log.info("pbsync listening on %s://%s:%d%s", scheme, args.host, server.server_address[1], server.base_path)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
