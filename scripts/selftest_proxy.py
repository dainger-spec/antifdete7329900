#!/usr/bin/env python3
"""Minimal HTTP-CONNECT and SOCKS5 proxy used by `PrivacyBrowser --self-test`.

It never connects anywhere: after the proxy handshake it answers the tunnelled HTTP request
itself with a page that reports how the request arrived, e.g.

    PB-PROXY-OK via=connect target=proxied.selftest.invalid:80 path=/one
    PB-PROXY-OK via=socks5 atyp=3 target=proxied.selftest.invalid:80 path=/

`atyp=3` means the browser sent the *hostname* to the proxy (remote DNS resolution); an
`.invalid` hostname can only load at all if it was not resolved locally.

    python3 scripts/selftest_proxy.py --http 18080 --socks 18081 --http-auth 18082

`--http-auth` is an HTTP CONNECT proxy that answers 407 until the request carries
`Proxy-Authorization: Basic pb-user:pb-pass`, then reports `via=connect-auth`.
"""
import argparse
import base64
import socket
import struct
import threading


def read_until_blank_line(conn: socket.socket) -> bytes:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > 65536:
            break
    return data


def respond_with_page(conn: socket.socket, via: str) -> None:
    request = read_until_blank_line(conn).decode("latin-1", "replace")
    request_line = request.split("\r\n", 1)[0]
    parts = request_line.split(" ")
    path = parts[1] if len(parts) > 1 else "?"
    body = (
        f"<html><head><title>PB proxied {path}</title></head>"
        f"<body>PB-PROXY-OK {via} path={path}</body></html>"
    ).encode()
    conn.sendall(
        b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
        + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
        + body
    )
    print(f"[selftest-proxy] served {via} path={path}", flush=True)


def handle_http(conn: socket.socket) -> None:
    with conn:
        head = read_until_blank_line(conn).decode("latin-1", "replace")
        first = head.split("\r\n", 1)[0]
        method, _, rest = first.partition(" ")
        target = rest.split(" ", 1)[0]
        if method.upper() == "CONNECT":
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            respond_with_page(conn, f"via=connect target={target}")
        else:
            # Absolute-form request (plain forward proxy); answer directly.
            path = "/" + target.split("://", 1)[-1].split("/", 1)[-1] if "/" in target.split("://", 1)[-1] else "/"
            body = (
                f"<html><head><title>PB proxied {path}</title></head>"
                f"<body>PB-PROXY-OK via=forward target={target} path={path}</body></html>"
            ).encode()
            conn.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
                + body
            )
            print(f"[selftest-proxy] served via=forward target={target}", flush=True)


AUTH_EXPECTED = "Basic " + base64.b64encode(b"pb-user:pb-pass").decode()


def handle_http_auth(conn: socket.socket) -> None:
    with conn:
        head = read_until_blank_line(conn).decode("latin-1", "replace")
        lines = head.split("\r\n")
        method, _, rest = lines[0].partition(" ")
        target = rest.split(" ", 1)[0]
        credentials = next((line.split(":", 1)[1].strip() for line in lines[1:]
                            if line.lower().startswith("proxy-authorization:")), None)
        if method.upper() != "CONNECT" or credentials != AUTH_EXPECTED:
            conn.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                         b"Proxy-Authenticate: Basic realm=\"pb-selftest\"\r\n"
                         b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            print(f"[selftest-proxy] 407 for {target} (credentials={'wrong' if credentials else 'none'})", flush=True)
            return
        conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        respond_with_page(conn, f"via=connect-auth target={target}")


def recv_exact(conn: socket.socket, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise ConnectionError("short read")
        data += chunk
    return data


def handle_socks(conn: socket.socket) -> None:
    with conn:
        version, nmethods = recv_exact(conn, 2)
        recv_exact(conn, nmethods)
        if version != 5:
            return
        conn.sendall(b"\x05\x00")  # no authentication
        _, cmd, _, atyp = recv_exact(conn, 4)
        if atyp == 1:
            host = socket.inet_ntoa(recv_exact(conn, 4))
        elif atyp == 3:
            host = recv_exact(conn, recv_exact(conn, 1)[0]).decode()
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, recv_exact(conn, 16))
        else:
            return
        (port,) = struct.unpack("!H", recv_exact(conn, 2))
        if cmd != 1:
            conn.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        respond_with_page(conn, f"via=socks5 atyp={atyp} target={host}:{port}")


def serve(port: int, handler) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(16)
    print(f"[selftest-proxy] {handler.__name__} listening on 127.0.0.1:{port}", flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=lambda c=conn: _safe(handler, c), daemon=True).start()


def _safe(handler, conn) -> None:
    try:
        handler(conn)
    except Exception as exc:  # noqa: BLE001 - test helper, keep serving
        print(f"[selftest-proxy] {handler.__name__} error: {exc}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--http", type=int, default=18080)
    parser.add_argument("--socks", type=int, default=18081)
    parser.add_argument("--http-auth", type=int, default=None)
    args = parser.parse_args()
    threading.Thread(target=serve, args=(args.http, handle_http), daemon=True).start()
    if args.http_auth:
        threading.Thread(target=serve, args=(args.http_auth, handle_http_auth), daemon=True).start()
    serve(args.socks, handle_socks)


if __name__ == "__main__":
    main()
