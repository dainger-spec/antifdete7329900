#!/usr/bin/env python3
"""Lumen iOS, stage 1 — the host side of the measurements (branch claude/ios-app-measure, never merged).

Runs on the Mac next to the iOS Simulator (or next to a real iPhone on the same Wi-Fi) and drives the
measurement app (ios-measure/app) over plain HTTP: the app asks for a command, runs it in its web
views, sends the result back. Everything the web views load goes to servers of this script, so
every request can be attributed:

  * proxy A — HTTP proxy (CONNECT and absolute-URI), Basic auth  ua:pa, port 28381
  * proxy B — SOCKS5 proxy, username/password auth (RFC 1929)  ub:pb, port 28382
  * proxy F — HTTP proxy without auth that the scenario kills mid-session, port 28384
  * nothing listens on port 28389: a dead proxy
  * the "site" — HTTP 28380, HTTPS 28443 (self-signed, *.lumentest), WebSocket on both
  * STUN on UDP 3478, for WebRTC

Names under .lumentest resolve nowhere: only the proxies answer them (they map them to this Mac).
A page under such a name can load only through a proxy that resolved the name itself. Every request
the site gets is matched to the proxy that carried it by its source address and port (each proxy
records the local end of every connection it opens upstream); a request no proxy opened is direct.
In the simulator each proxy also opens its upstream connections from an address of its own
(127.0.0.2 for A, 127.0.0.3 for B, if lo0 has those aliases), which is what the site sees.

Every check prints PASS, FAIL, LEAK, INFO or INCONCLUSIVE. The exit code is 0 only when every core
check passed. --break makes the app misconfigure on purpose, to show the checks can fail:
  noproxy — sessions A and B get no proxy at all;  swap — A gets B's proxy and B gets A's;
  sharestore — A and B share one data store (the isolation check must fail).
"""
import argparse
import asyncio
import base64
import hashlib
import json
import os
import random
import re
import shutil
import socket
import ssl
import string
import struct
import subprocess
import sys
import time
import urllib.parse
import uuid

EVENTS = []          # everything the servers saw, in order
UPSTREAM = {}        # (local ip, local port) of a proxy's upstream connection -> proxy name
CHECKS = []          # results of the scenario
ARGS = None
KILLED = set()       # proxies the scenario stopped


def event(kind, **fields):
    fields["kind"] = kind
    fields["t"] = round(time.time(), 3)
    EVENTS.append(fields)
    if ARGS and ARGS.verbose:
        print("  ev", json.dumps(fields)[:300], flush=True)
    return fields


def check(name, status, detail="", core=False):
    CHECKS.append({"name": name, "status": status, "detail": detail, "core": core})
    print(f"{status:<12} {name}: {detail}", flush=True)


# ---------------------------------------------------------------- HTTP helpers

async def read_head(reader, limit=65536):
    data = await reader.readuntil(b"\r\n\r\n")
    if len(data) > limit:
        raise ValueError("head too long")
    text = data.decode("latin-1")
    lines = text.split("\r\n")
    parts = lines[0].split(" ", 2)
    if len(parts) < 3:
        raise ValueError("bad request line %r" % lines[0])
    headers = []
    for line in lines[1:]:
        if not line:
            continue
        key, _, value = line.partition(":")
        headers.append((key.strip(), value.strip()))
    return parts[0], parts[1], parts[2], headers, data


def header(headers, name):
    for key, value in headers:
        if key.lower() == name.lower():
            return value
    return None


def response(status, body=b"", content_type="application/json", extra=()):
    if isinstance(body, str):
        body = body.encode()
    head = [f"HTTP/1.1 {status}", f"Content-Type: {content_type}", f"Content-Length: {len(body)}",
            "Access-Control-Allow-Origin: *", "Cache-Control: no-store", "Connection: close"]
    head += list(extra)
    return ("\r\n".join(head) + "\r\n\r\n").encode() + body


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


# ---------------------------------------------------------------- the site

def page_html(sid, run, host):
    s = sid.lower()
    p = ARGS.http_port
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>Lumen measure {sid}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="dns-prefetch" href="//pf-{s}-{run}.lumentest">
<link rel="preconnect" href="http://pc-{s}-{run}.lumentest:{p}">
</head><body style="font: 16px -apple-system; background:#fff">
<h3>session {sid} · {host}</h3>
<img src="/px?sid={sid}&k=img" width="1" height="1">
<iframe src="http://fr-{s}-{run}.lumentest:{p}/fr?sid={sid}&k=iframe" width="10" height="10"></iframe>
<a href="http://an-{s}-{run}.lumentest:{p}/never">link</a>
</body></html>"""


async def ws_serve(reader, writer, headers, peer):
    key = header(headers, "Sec-WebSocket-Key") or ""
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    payload = json.dumps({"peer": peer[0], "peerPort": peer[1], "via": attribute(peer)}).encode()
    frame = bytes([0x81])
    if len(payload) < 126:
        frame += bytes([len(payload)])
    else:
        frame += bytes([126]) + struct.pack(">H", len(payload))
    writer.write(frame + payload)
    await writer.drain()
    try:
        await asyncio.wait_for(reader.read(1024), timeout=5)
    except Exception:
        pass
    writer.write(bytes([0x88, 0x00]))
    await writer.drain()


def attribute(peer):
    return UPSTREAM.get((peer[0], peer[1]), "direct")


async def site_handler(reader, writer, scheme):
    peer = writer.get_extra_info("peername")[:2]
    try:
        method, target, _, headers, _ = await read_head(reader)
        length = int(header(headers, "Content-Length") or 0)
        body = await reader.readexactly(length) if length else b""
        url = urllib.parse.urlsplit(target)
        query = dict(urllib.parse.parse_qsl(url.query))
        host = header(headers, "Host") or ""
        ev = event("site", scheme=scheme, method=method, host=host, path=url.path, query=query,
                   peer=peer[0], peerPort=peer[1], via=attribute(peer), cookie=header(headers, "Cookie"),
                   ua=header(headers, "User-Agent"), lang=header(headers, "Accept-Language"),
                   headerOrder=[k for k, _ in headers])
        if url.path == "/ws" and (header(headers, "Upgrade") or "").lower() == "websocket":
            await ws_serve(reader, writer, headers, peer)
            return
        if url.path in ("/whoami", "/lo", "/fo", "/fo2"):
            out = {"peer": peer[0], "peerPort": peer[1], "via": ev["via"], "host": host, "path": url.path,
                   "scheme": scheme, "cookie": ev["cookie"], "query": query}
            writer.write(response("200 OK", json.dumps(out)))
        elif url.path == "/page":
            sid = query.get("sid", "?")
            writer.write(response("200 OK", page_html(sid, ARGS.run, host), "text/html; charset=utf-8"))
        elif url.path == "/fr":
            writer.write(response("200 OK", "<!doctype html><title>frame</title><p>frame", "text/html"))
        elif url.path == "/px":
            gif = base64.b64decode("R0lGODlhAQABAAAAACw=")
            writer.write(response("200 OK", gif, "image/gif"))
        elif url.path == "/cookie-set":
            value = query.get("v", "x")
            writer.write(response("200 OK", json.dumps({"set": value}), extra=[
                f"Set-Cookie: lumen_srv={value}; Path=/; Max-Age=3600"]))
        elif url.path == "/blank":
            writer.write(response("200 OK", "<!doctype html><meta charset=utf-8><title>blank</title><body></body>", "text/html; charset=utf-8"))
        elif url.path.startswith("/static/") and ARGS.static_dir:
            name = os.path.basename(url.path)
            path = os.path.join(ARGS.static_dir, name)
            if os.path.isfile(path):
                kind = "text/html; charset=utf-8" if name.endswith(".html") else "text/javascript"
                writer.write(response("200 OK", open(path, "rb").read(), kind))
            else:
                writer.write(response("404 Not Found", "{}"))
        else:
            writer.write(response("200 OK", json.dumps({"ok": True, "path": url.path})))
        await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, ValueError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


# ---------------------------------------------------------------- proxies

PROXY_WRITERS = {}   # name -> set of client writers (to kill a proxy with its connections)


TESTNET = "192.0.2.1"   # TEST-NET-1: routed nowhere; the proxies take it for the site


def resolve_name(host):
    """Names under .lumentest exist only here: they are this Mac's site. So is 192.0.2.1 — but only
    through a proxy: a direct attempt to it goes nowhere, and the capture sees its packets."""
    if host.endswith(".lumentest") or host == "lumentest":
        return "127.0.0.1", "test-name"
    if host == TESTNET:
        return "127.0.0.1", "test-ip"
    return host, "passthrough"


async def open_upstream(name, host, port, bind):
    target, how = resolve_name(host)
    local_bind = None
    if bind and (target.startswith("127.") or target == ARGS.lan_ip):
        local_bind = (bind, 0)
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(target, port, local_addr=local_bind), 15)
    except OSError:
        if not local_bind:
            raise
        reader, writer = await asyncio.wait_for(asyncio.open_connection(target, port), 15)
    local = writer.get_extra_info("sockname")[:2]
    UPSTREAM[(local[0], local[1])] = name
    return reader, writer, local, how


def http_proxy(name, auth, bind):
    async def handler(reader, writer):
        if name in KILLED:
            writer.close()
            return
        PROXY_WRITERS.setdefault(name, set()).add(writer)
        client = writer.get_extra_info("peername")[:2]
        try:
            method, target, version, headers, raw = await read_head(reader)
            given = header(headers, "Proxy-Authorization")
            status = "none-required"
            if auth:
                expected = "Basic " + base64.b64encode(auth.encode()).decode()
                status = "ok" if given == expected else ("missing" if not given else "bad")
            if method == "CONNECT":
                host, _, port = target.rpartition(":")
                port = int(port)
            else:
                url = urllib.parse.urlsplit(target)
                host, port = url.hostname or "", url.port or 80
            host = host.strip("[]")
            if auth and status != "ok":
                event("proxy", proxy=name, method=method, host=host, port=port, auth=status, client=client[0])
                writer.write(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"lumen\"\r\n"
                             b"Content-Length: 0\r\nConnection: close\r\n\r\n")
                await writer.drain()
                return
            try:
                up_reader, up_writer, local, how = await open_upstream(name, host, port, bind)
            except Exception as error:
                event("proxy", proxy=name, method=method, host=host, port=port, auth=status, client=client[0],
                      error=str(error))
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                await writer.drain()
                return
            event("proxy", proxy=name, method=method, host=host, port=port, auth=status, client=client[0],
                  upstream=f"{local[0]}:{local[1]}", resolved=how)
            if method == "CONNECT":
                writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                await writer.drain()
                await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
            else:
                url = urllib.parse.urlsplit(target)
                path = (url.path or "/") + ("?" + url.query if url.query else "")
                kept = [(k, v) for k, v in headers if k.lower() not in ("proxy-authorization", "proxy-connection", "connection")]
                head = f"{method} {path} {version}\r\n" + "".join(f"{k}: {v}\r\n" for k, v in kept) + "Connection: close\r\n\r\n"
                up_writer.write(head.encode("latin-1"))
                length = int(header(headers, "Content-Length") or 0)
                if length:
                    up_writer.write(await reader.readexactly(length))
                await up_writer.drain()
                await pipe(up_reader, writer)
        except (asyncio.IncompleteReadError, ConnectionError, ValueError):
            pass
        finally:
            PROXY_WRITERS.get(name, set()).discard(writer)
            try:
                writer.close()
            except Exception:
                pass
    return handler


def socks_proxy(name, auth, bind):
    async def handler(reader, writer):
        if name in KILLED:
            writer.close()
            return
        PROXY_WRITERS.setdefault(name, set()).add(writer)
        client = writer.get_extra_info("peername")[:2]
        try:
            version, count = await reader.readexactly(2)
            methods = await reader.readexactly(count)
            if version != 5:
                return
            status = "none-required"
            if auth:
                if 2 not in methods:
                    event("proxy", proxy=name, method="greeting", auth="no user/pass offered", offered=list(methods))
                    writer.write(b"\x05\xff")
                    await writer.drain()
                    return
                writer.write(b"\x05\x02")
                await writer.drain()
                _, ulen = await reader.readexactly(2)
                user = (await reader.readexactly(ulen)).decode("latin-1")
                (plen,) = await reader.readexactly(1)
                password = (await reader.readexactly(plen)).decode("latin-1")
                status = "ok" if f"{user}:{password}" == auth else "bad"
                writer.write(b"\x01\x00" if status == "ok" else b"\x01\x01")
                await writer.drain()
                if status != "ok":
                    event("proxy", proxy=name, method="auth", auth=status, client=client[0])
                    return
            else:
                writer.write(b"\x05\x00")
                await writer.drain()
            _, command, _, atyp = await reader.readexactly(4)
            if atyp == 1:
                host = socket.inet_ntoa(await reader.readexactly(4))
            elif atyp == 3:
                (n,) = await reader.readexactly(1)
                host = (await reader.readexactly(n)).decode("latin-1")
            elif atyp == 4:
                host = socket.inet_ntop(socket.AF_INET6, await reader.readexactly(16))
            else:
                return
            (port,) = struct.unpack(">H", await reader.readexactly(2))
            if command != 1:
                event("proxy", proxy=name, method={2: "BIND", 3: "UDP ASSOCIATE"}.get(command, str(command)),
                      host=host, port=port, atyp=atyp, auth=status, client=client[0])
                writer.write(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
                await writer.drain()
                return
            try:
                up_reader, up_writer, local, how = await open_upstream(name, host, port, bind)
            except Exception as error:
                event("proxy", proxy=name, method="CONNECT", host=host, port=port, atyp=atyp, auth=status,
                      client=client[0], error=str(error))
                writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
                await writer.drain()
                return
            event("proxy", proxy=name, method="CONNECT", host=host, port=port, atyp=atyp, auth=status,
                  client=client[0], upstream=f"{local[0]}:{local[1]}", resolved=how)
            writer.write(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", 0))
            await writer.drain()
            await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
        except (asyncio.IncompleteReadError, ConnectionError, ValueError):
            pass
        finally:
            PROXY_WRITERS.get(name, set()).discard(writer)
            try:
                writer.close()
            except Exception:
                pass
    return handler


async def kill_proxy(name, server):
    KILLED.add(name)
    server.close()
    for writer in list(PROXY_WRITERS.get(name, ())):
        try:
            writer.transport.abort()
        except Exception:
            pass
    event("harness", note=f"proxy {name} stopped with its connections")


# ---------------------------------------------------------------- STUN

class Stun(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if len(data) < 20:
            return
        kind, length, cookie = struct.unpack(">HHI", data[:8])
        txid = data[8:20]
        event("stun", src=addr[0], srcPort=addr[1], type=kind)
        if kind != 0x0001 or cookie != 0x2112A442:
            return
        ip = socket.inet_aton(addr[0]) if ":" not in addr[0] else None
        if ip is None:
            return
        xport = addr[1] ^ (0x2112A442 >> 16)
        xip = bytes(a ^ b for a, b in zip(ip, struct.pack(">I", 0x2112A442)))
        attr = struct.pack(">HHBBH", 0x0020, 8, 0, 1, xport) + xip
        self.transport.sendto(struct.pack(">HHI", 0x0101, len(attr), 0x2112A442) + txid + attr, addr)


# ---------------------------------------------------------------- the app's control channel

class App:
    def __init__(self):
        self.queue = asyncio.Queue()
        self.results = {}
        self.hello = asyncio.Event()
        self.info = {}

    async def cmd(self, op, timeout=60, **fields):
        fields["op"] = op
        fields["id"] = uuid.uuid4().hex[:12]
        future = asyncio.get_running_loop().create_future()
        self.results[fields["id"]] = future
        await self.queue.put(fields)
        try:
            result = await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError:
            result = {"error": f"no answer from the app in {timeout}s", "op": op}
        if ARGS.verbose:
            print("  app", op, fields.get("session", ""), json.dumps(result)[:400], flush=True)
        return result


APP = App()


async def control_handler(reader, writer):
    try:
        method, target, _, headers, _ = await read_head(reader)
        length = int(header(headers, "Content-Length") or 0)
        body = await reader.readexactly(length) if length else b""
        path = urllib.parse.urlsplit(target).path
        if path == "/result":
            result = json.loads(body or b"{}")
            future = APP.results.pop(result.get("id"), None)
            if future and not future.done():
                future.set_result(result)
            writer.write(response("200 OK", "{}"))
        elif path in ("/hello", "/next"):
            if path == "/hello":
                APP.info = json.loads(body or b"{}")
                APP.hello.set()
                event("app", note="hello", info=APP.info)
            try:
                command = await asyncio.wait_for(APP.queue.get(), 20)
                writer.write(response("200 OK", json.dumps(command)))
            except asyncio.TimeoutError:
                writer.write(response("204 No Content"))
        else:
            writer.write(response("404 Not Found", "{}"))
        await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, ValueError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


# ---------------------------------------------------------------- DNS capture

class Capture:
    """tcpdump of DNS on this Mac (pktap names the process asking). In the simulator every DNS
    question of a simulated device is asked by this Mac's mDNSResponder, so it is seen here."""

    def __init__(self, path, interface):
        self.path = path
        self.interface = interface
        self.process = None
        self.state = "not started"

    def start(self):
        if not self.interface:
            self.state = "off"
            return
        tcpdump = shutil.which("tcpdump") or "/usr/sbin/tcpdump"
        command = ["sudo", "-n", tcpdump, "-i", self.interface, "-n", "-l", "-tt", "port 53 or host 192.0.2.1"]
        if self.interface.startswith("pktap"):
            command[4:4] = []
            command.insert(5, "-k")
            command.insert(6, "NP")
        self.file = open(self.path, "w")
        self.errors = open(self.path + ".err", "w")
        try:
            self.process = subprocess.Popen(command, stdout=self.file, stderr=self.errors)
            self.state = "running: " + " ".join(command)
        except OSError as error:
            self.state = f"failed: {error}"

    def stop(self):
        if self.process:
            subprocess.run(["sudo", "-n", "kill", "-INT", str(self.process.pid)], capture_output=True)
            try:
                self.process.wait(5)
            except Exception:
                self.process.kill()
            self.file.close()
            self.errors.close()

    def lines(self):
        try:
            return open(self.path, errors="replace").read().splitlines()
        except OSError:
            return []

    def seen(self, token):
        return [line for line in self.lines() if token.lower() in line.lower()]

    def between(self, token, t0, t1):
        """Lines naming `token` whose tcpdump timestamp (-tt) falls in [t0, t1]."""
        out = []
        for line in self.seen(token):
            try:
                stamp = float(line.split(" ", 1)[0])
            except ValueError:
                continue
            if t0 <= stamp <= t1:
                out.append(line)
        return out


# ---------------------------------------------------------------- helpers for the scenario

def site_events(predicate):
    return [e for e in EVENTS if e["kind"] == "site" and predicate(e)]


def proxy_events(predicate):
    return [e for e in EVENTS if e["kind"] == "proxy" and predicate(e)]


def session_test_js(sid):
    """What a page in session `sid` does, after it has loaded: every kind of request, each to a name
    of its own so the logs can tell them apart. Returns what the page itself saw."""
    s = sid.lower()
    return f"""
const S = {json.dumps(sid)}, s = {json.dumps(s)}, R = {json.dumps(ARGS.run)}, P = {ARGS.http_port}, LAN = {json.dumps(ARGS.lan_ip or "")};
const at = (k) => `http://${{k}}-${{s}}-${{R}}.lumentest:${{P}}`;
const j = async (u, o) => {{ try {{ const r = await fetch(u, o); return await r.json(); }} catch (e) {{ return {{ error: String(e) }}; }} }};
const settle = (p, ms) => Promise.race([p, new Promise((r) => setTimeout(() => r({{ error: 'timeout' }}), ms))]);
const out = {{}};
out.same = await j(`/whoami?sid=${{S}}&k=same`);
out.cross = await j(at('x') + `/whoami?sid=${{S}}&k=cross`);
out.ws = await settle(new Promise((res) => {{
  try {{ const w = new WebSocket(at('ws').replace('http:', 'ws:') + `/ws?sid=${{S}}`);
        w.onmessage = (m) => {{ res(JSON.parse(m.data)); w.close(); }}; w.onerror = () => res({{ error: 'ws error' }}); }}
  catch (e) {{ res({{ error: String(e) }}); }} }}), 8000);
out.worker = await settle(new Promise((res) => {{
  const src = `fetch(${{JSON.stringify(at('wk') + '/whoami?sid=' + S + '&k=worker')}}).then(r => r.json()).then(v => postMessage(v), e => postMessage({{ error: String(e) }}))`;
  try {{ const w = new Worker(URL.createObjectURL(new Blob([src], {{ type: 'text/javascript' }}))); w.onmessage = (m) => res(m.data); w.onerror = (e) => res({{ error: 'worker error ' + e.message }}); }}
  catch (e) {{ res({{ error: String(e) }}); }} }}), 8000);
out.beacon = navigator.sendBeacon(at('bc') + `/beacon?sid=${{S}}&k=beacon`, 'x');
out.loopback4 = await settle(fetch(`http://127.0.0.1:${{P}}/lo?sid=${{S}}&k=lo4`, {{ mode: 'no-cors' }}).then(() => 'loaded', (e) => String(e)), 6000);
out.localhost = await settle(fetch(`http://localhost:${{P}}/lo?sid=${{S}}&k=lohost`, {{ mode: 'no-cors' }}).then(() => 'loaded', (e) => String(e)), 6000);
out.lan = await settle(j(`http://{TESTNET}:${{P}}/whoami?sid=${{S}}&k=lan`), 8000);
out.rtc = await (async () => {{
  if (typeof RTCPeerConnection !== 'function') return {{ absent: true }};
  try {{
    const pc = new RTCPeerConnection({{ iceServers: LAN ? [{{ urls: `stun:${{LAN}}:{ARGS.stun_port}` }}] : [] }});
    const candidates = []; pc.onicecandidate = (e) => {{ if (e.candidate && e.candidate.candidate) candidates.push(e.candidate.candidate); }};
    pc.createDataChannel('x'); await pc.setLocalDescription(await pc.createOffer());
    await new Promise((r) => setTimeout(r, 5000)); pc.close(); return {{ candidates }};
  }} catch (e) {{ return {{ error: String(e) }}; }} }})();
await new Promise((r) => setTimeout(r, 500));
out.ua = navigator.userAgent;
return out;
"""


def tok(prefix, sid):
    return f"{prefix}-{sid.lower()}-{ARGS.run}"


def via_of(sid):
    """The proxies that carried session `sid`'s requests to the site, by request."""
    rows = site_events(lambda e: e["query"].get("sid") == sid or f"-{sid.lower()}-{ARGS.run}." in e["host"])
    return rows


# ---------------------------------------------------------------- scenario: question 1

async def scenario_q1(capture):
    run, lan, hp = ARGS.run, ARGS.lan_ip, ARGS.http_port
    proxy_a = {"type": "http", "host": ARGS.proxy_host, "port": ARGS.port_a, "user": "ua", "pass": "pa", "allowFailover": False}
    proxy_b = {"type": "socks5", "host": ARGS.proxy_host, "port": ARGS.port_b, "user": "ub", "pass": "pb", "allowFailover": False}
    if ARGS.socks_no_auth:
        proxy_b.pop("user"), proxy_b.pop("pass")
    give = {"A": [proxy_a], "B": [proxy_b]}
    if ARGS.brk == "noproxy":
        give = {"A": [], "B": []}
    elif ARGS.brk == "swap":
        give = {"A": [proxy_b], "B": [proxy_a]}
    info = APP.info
    check("q1.api", "PASS" if info.get("storeRespondsToSetProxyConfigurations") else "FAIL",
          f"{info.get('os')} ({info.get('osBuild')}), {info.get('simulator') or info.get('machine')}: "
          f"WKWebsiteDataStore responds to setProxyConfigurations: {info.get('storeRespondsToSetProxyConfigurations')}, "
          f"dataStoreForIdentifier: {info.get('storeRespondsToDataStoreForIdentifier')}, "
          f"ProxyConfiguration().allowFailover by default: {info.get('proxyConfigurationDefaultAllowFailover')}", core=True)
    if not info.get("storeRespondsToSetProxyConfigurations"):
        return

    stores = {k: f"persistent:{uuid.uuid4()}" for k in "ABCDEFGHJ"}
    if ARGS.brk == "sharestore":
        stores["B"] = stores["A"]   # one data store for both: the isolation check must fail
    made = {}
    for sid, proxies in (("A", give["A"]), ("B", give["B"]), ("C", None)):
        made[sid] = await APP.cmd("session", session=sid, store=stores[sid], proxies=proxies)
    print("sessions:", json.dumps(made), flush=True)

    # 1. Three sessions load at the same moment: A through the HTTP proxy, B through SOCKS5, C directly.
    loads = await asyncio.gather(*[APP.cmd("load", session=sid, url=f"http://{tok('p', sid)}.lumentest:{hp}/page?sid={sid}", timeout=40)
                                   for sid in "ABC"])
    loaded = dict(zip("ABC", loads))
    print("loads:", json.dumps(loaded)[:1500], flush=True)
    tests = await asyncio.gather(*[APP.cmd("eval", session=sid, js=session_test_js(sid), timeout=60) for sid in "AB"])
    seen = dict(zip("AB", tests))
    print("pages saw:", json.dumps(seen)[:4000], flush=True)

    expect = {"A": ("A", "ua:pa"), "B": ("B", "ub:pb")}
    for sid in "AB":
        own, _ = expect[sid]
        other = "B" if own == "A" else "A"
        rows = via_of(sid)
        page_rows = [e for e in rows if e["path"] == "/page"]
        ok_load = loaded[sid].get("ok") is True
        on_own = page_rows and all(e["via"] == own for e in page_rows)
        check(f"q1.{sid}.page-through-own-proxy", "PASS" if ok_load and on_own else "FAIL",
              f"load ok={ok_load} err={loaded[sid].get('error')}; the site got /page via {[e['via'] for e in page_rows]} "
              f"from {[e['peer'] for e in page_rows]}; proxy {own} saw "
              f"{[(e['method'], e['host'], e.get('auth'), e.get('atyp')) for e in proxy_events(lambda e: e['proxy'] == own and tok('p', sid) in e.get('host', ''))]}",
              core=True)
        kinds = {}
        for e in rows:
            k = e["query"].get("k") or e["path"]
            kinds.setdefault(k, set()).add(e["via"])
        wrong = {k: sorted(v) for k, v in kinds.items() if v != {own} and k not in ("lo4", "lohost")}
        check(f"q1.{sid}.every-request-through-own-proxy", "PASS" if kinds and not wrong else "FAIL",
              f"by kind: { {k: sorted(v) for k, v in sorted(kinds.items())} }" + (f"; NOT on {own}: {wrong}" if wrong else ""),
              core=True)
        needed = {"/page", "img", "iframe", "same", "cross", "worker", "beacon"}
        missing = needed - set(kinds)
        ws_ok = isinstance(seen[sid].get("value"), dict) and seen[sid]["value"].get("ws", {}).get("via") == own
        check(f"q1.{sid}.request-kinds-covered", "PASS" if not missing and ws_ok else "FAIL",
              f"missing kinds: {sorted(missing) or 'none'}; WebSocket via {seen[sid].get('value', {}).get('ws') if isinstance(seen[sid].get('value'), dict) else seen[sid]}",
              core=True)
        value = seen[sid].get("value") if isinstance(seen[sid].get("value"), dict) else {}
        check(f"q1.{sid}.site-sees", "INFO",
              f"the site saw the page from {value.get('same', {}).get('peer')} (proxy {own}'s upstream address), "
              f"cross-origin from {value.get('cross', {}).get('peer')}, worker from {value.get('worker', {}).get('peer')}")
        if sid == "B":
            atyps = sorted({e.get("atyp") for e in proxy_events(lambda e: e["proxy"] == "B" and e.get("method") == "CONNECT"
                                                                and f"-b-{run}." in e.get("host", ""))})
            check("q1.B.socks-remote-dns", "PASS" if atyps == [3] else "FAIL",
                  f"SOCKS5 address types the app sent for its pages: {atyps} (3 = the name, resolved by the proxy)", core=True)
        auths = sorted({e.get("auth") for e in proxy_events(lambda e: e["proxy"] == own)})
        check(f"q1.{sid}.proxy-auth", "INFO", f"proxy {own} auth states seen: {auths}; challenges answered by the app: "
              f"{loaded[sid].get('challenges')}")
        # Loopback and LAN literal: where did they go?
        lo = [e for e in rows if e["query"].get("k") in ("lo4", "lohost")]
        check(f"q1.{sid}.loopback", "LEAK" if any(e["via"] == "direct" for e in lo) else "INFO",
              f"fetch to 127.0.0.1 / localhost: {[(e['query'].get('k'), e['via']) for e in lo]} (page said "
              f"{value.get('loopback4')}, {value.get('localhost')}) — a direct one reaches this device's own services, never the network")
        lan_rows = [e for e in rows if e["query"].get("k") == "lan"]
        check(f"q1.{sid}.ip-literal", "PASS" if lan_rows and all(e["via"] == own for e in lan_rows) else "FAIL",
              f"fetch to {TESTNET} (an IP literal, no name; only a proxy reaches the site there): via {[e['via'] for e in lan_rows]} "
              f"(page saw {value.get('lan')})", core=True)

    # Control: C has no proxy, so a .lumentest name must not load (proves the names resolve nowhere).
    c_rows = via_of("C")
    check("q1.C.control-direct-cannot-load", "PASS" if not loaded["C"].get("ok") and not c_rows else "INCONCLUSIVE",
          f"session without a proxy: load ok={loaded['C'].get('ok')} ({loaded['C'].get('error')}); the site saw {len(c_rows)} of its requests")

    # 2. HTTPS, both at once.
    loads = await asyncio.gather(*[APP.cmd("load", session=sid, url=f"https://{tok('s', sid)}.lumentest:{ARGS.https_port}/page?sid={sid}&k=https", timeout=40)
                                   for sid in "AB"])
    for sid, result in zip("AB", loads):
        rows = site_events(lambda e, sid=sid: e["scheme"] == "https" and e["query"].get("sid") == sid and e["path"] == "/page")
        check(f"q1.{sid}.https-through-own-proxy", "PASS" if result.get("ok") and rows and all(e["via"] == sid for e in rows) else "FAIL",
              f"load ok={result.get('ok')} err={result.get('error')}; via {[e['via'] for e in rows]}; proxy {sid}: "
              f"{[(e['method'], e['host'], e['port']) for e in proxy_events(lambda e, sid=sid: e['proxy'] == sid and tok('s', sid) in e.get('host', ''))]}",
              core=True)

    # 3. Interleaved: 25 fetches from each session, started together.
    burst = """const out = []; await Promise.all(Array.from({length: 25}, (_, i) => fetch(`/whoami?sid=%s&k=burst&i=${i}`).then(r => r.json()).then(v => out.push(v.via), e => out.push(String(e))))); return out;"""
    bursts = await asyncio.gather(*[APP.cmd("eval", session=sid, js=burst % sid, timeout=60) for sid in "AB"])
    for sid, result in zip("AB", bursts):
        vias = result.get("value") if isinstance(result.get("value"), list) else [str(result)]
        check(f"q1.{sid}.burst", "PASS" if vias and len(vias) == 25 and set(vias) == {sid} else "FAIL",
              f"25 parallel fetches while the other session did the same: via {sorted(set(map(str, vias)))} ({len(vias)})", core=True)

    # 4. Isolation: one origin in both sessions; A sets cookies and storage, B must see none.
    shared = f"http://shared-{run}.lumentest:{hp}"
    for sid in "AB":
        await APP.cmd("load", session=sid, url=f"{shared}/blank?sid={sid}", timeout=30)
    await APP.cmd("eval", session="A", js=f"""await fetch('/cookie-set?v=A-{run}'); document.cookie = 'lumen_js=A-{run}; path=/; max-age=3600';
        localStorage.setItem('lumen', 'A-{run}'); await new Promise((res) => {{ const r = indexedDB.open('lumen', 1);
        r.onupgradeneeded = () => r.result.createObjectStore('s'); r.onsuccess = () => {{ const t = r.result.transaction('s', 'readwrite');
        t.objectStore('s').put('A-{run}', 'k'); t.oncomplete = () => res(true); }}; r.onerror = () => res(false); }}); return true;""")
    reads = {}
    for sid in "AB":
        reads[sid] = await APP.cmd("eval", session=sid, js=f"""const who = await (await fetch('/whoami?sid={sid}&k=isolation')).json();
            const idb = await new Promise((res) => {{ const r = indexedDB.open('lumen', 1); r.onupgradeneeded = () => r.result.createObjectStore('s');
            r.onsuccess = () => {{ try {{ const g = r.result.transaction('s').objectStore('s').get('k'); g.onsuccess = () => res(g.result || null); g.onerror = () => res(null); }} catch (e) {{ res(null); }} }}; r.onerror = () => res(null); }});
            return {{ documentCookie: document.cookie, serverCookie: who.cookie, local: localStorage.getItem('lumen'), idb }};""")
    a, b = reads["A"].get("value") or {}, reads["B"].get("value") or {}
    a_has = all(f"A-{run}" in str(a.get(k)) for k in ("documentCookie", "serverCookie", "local", "idb"))
    b_none = not any(f"A-{run}" in str(b.get(k)) for k in ("documentCookie", "serverCookie", "local", "idb"))
    check("q1.isolation", "PASS" if a_has and b_none else "FAIL",
          f"same origin in both: A reads {a}; B reads {b}", core=True)

    # 5. Changing a session's proxy while it runs: A gets B's proxy.
    await APP.cmd("setProxy", session="A", proxies=[proxy_b] if ARGS.brk != "swap" else [proxy_a])
    after = await APP.cmd("eval", session="A", js=f"return await (await fetch('/whoami?sid=A&k=switched')).json();")
    switched = (after.get("value") or {}).get("via")
    check("q1.A.switch-proxy-live", "INFO",
          f"after setProxy(B) on A's store, A's next fetch went via {switched} (no new web view)")

    # 6. Fail-closed: a dead proxy, failover off and default; then a proxy that dies mid-session. The
    # target is TEST-NET: through a live proxy it is the site; a direct attempt goes nowhere, and its
    # packets are in the capture (the only way to see it: nothing answers there).
    capturing = capture.state.startswith("running")
    if capturing:
        # The detector's own red run: C has no proxy, so its load of TEST-NET is a direct attempt.
        tc = time.time()
        await APP.cmd("load", session="C", url=f"http://{TESTNET}:{hp}/ctl?sid=C", timeout=8)
        await asyncio.sleep(1.5)
        control = capture.between(TESTNET, tc, time.time())
        check("q1.direct-detector-sees-a-direct-attempt", "PASS" if control else "INCONCLUSIVE",
              f"the session without a proxy, a load of {TESTNET}: {len(control)} packets seen {control[:1]}")
        capturing = bool(control)

    def direct_attempts(t0, t1):
        return capture.between(TESTNET, t0, t1) if capturing else None

    dead = {"type": "http", "host": ARGS.proxy_host, "port": ARGS.port_dead}
    await APP.cmd("session", session="D", store=stores["D"], proxies=[dict(dead, allowFailover=False)])
    await APP.cmd("session", session="E", store=stores["E"], proxies=[dead])
    t0 = time.time()
    rd = await APP.cmd("load", session="D", url=f"http://{TESTNET}:{hp}/fo?sid=D", timeout=25)
    t1 = time.time()
    re_ = await APP.cmd("load", session="E", url=f"http://{TESTNET}:{hp}/fo?sid=E", timeout=25)
    t2 = time.time()
    await asyncio.sleep(1.5)
    d_rows = site_events(lambda e: e["path"] == "/fo" and e["query"].get("sid") == "D")
    e_rows = site_events(lambda e: e["path"] == "/fo" and e["query"].get("sid") == "E")
    d_direct, e_direct = direct_attempts(t0, t1), direct_attempts(t1, t2)
    check("q1.dead-proxy-failover-off", ("PASS" if not d_rows and not d_direct else "LEAK") if capturing else "INCONCLUSIVE",
          f"proxy port with nothing on it, allowFailover=false: load ok={rd.get('ok')} ({rd.get('error')}); the site saw "
          f"{[(e['via'], e['peer']) for e in d_rows]}; direct packets to {TESTNET}: {len(d_direct or [])} {(d_direct or [])[:1]}",
          core=capturing)
    check("q1.dead-proxy-failover-default", ("LEAK" if e_rows or e_direct else "PASS") if capturing else "INCONCLUSIVE",
          f"same, allowFailover at its default ({info.get('proxyConfigurationDefaultAllowFailover')}): load ok={re_.get('ok')}; "
          f"the site saw {[(e['via'], e['peer']) for e in e_rows]}; direct packets: {len(e_direct or [])}")
    await APP.cmd("session", session="F", store=stores["F"],
                  proxies=[{"type": "http", "host": ARGS.proxy_host, "port": ARGS.port_f, "allowFailover": False}])
    r1 = await APP.cmd("load", session="F", url=f"http://{TESTNET}:{hp}/whoami?sid=F&k=before", timeout=25)
    await kill_proxy("F", SERVERS["F"])
    t3 = time.time()
    r2 = await APP.cmd("load", session="F", url=f"http://{TESTNET}:{hp}/fo2?sid=F", timeout=25)
    r3 = await APP.cmd("eval", session="F", js=f"return await fetch('http://{TESTNET}:{hp}/fo2?sid=F&k=fetch').then(() => 'loaded', (e) => String(e));")
    t4 = time.time()
    await asyncio.sleep(1.5)
    f_rows = site_events(lambda e: e["path"] == "/fo2")
    before = site_events(lambda e: e["query"].get("sid") == "F" and e["query"].get("k") == "before")
    f_direct = direct_attempts(t3, t4)
    ok_before = r1.get("ok") and before and all(e["via"] == "F" for e in before)
    check("q1.proxy-dies-mid-session",
          ("PASS" if ok_before and not f_rows and not f_direct else ("LEAK" if f_rows or f_direct else "INCONCLUSIVE"))
          if capturing else "INCONCLUSIVE",
          f"through F first: ok={r1.get('ok')} via {[e['via'] for e in before]}; F stopped with its connections; next load "
          f"ok={r2.get('ok')} ({r2.get('error')}), a fetch {r3.get('value')}; the site saw {[(e['via'], e['peer']) for e in f_rows]}; "
          f"direct packets to {TESTNET}: {len(f_direct or [])}", core=capturing)

    # 7. Proxy credentials: wrong ones must fail, and never go around the proxy.
    await APP.cmd("session", session="G", store=stores["G"], proxies=[dict(proxy_a, **{"pass": "wrong"})])
    await APP.cmd("session", session="H", store=stores["H"], proxies=[dict(proxy_b, **{"pass": "wrong"})] if "user" in proxy_b else [])
    rg = await APP.cmd("load", session="G", url=f"http://{tok('p', 'G')}.lumentest:{hp}/page?sid=G", timeout=25)
    rh = await APP.cmd("load", session="H", url=f"http://{tok('p', 'H')}.lumentest:{hp}/page?sid=H", timeout=25)
    g_rows, h_rows = via_of("G"), via_of("H")
    g_proxy = sorted({e.get("auth") for e in proxy_events(lambda e: e["proxy"] == "A" and tok("p", "G") in e.get("host", ""))})
    check("q1.wrong-password", "PASS" if not g_rows and not h_rows else "FAIL",
          f"HTTP proxy, wrong password: the site saw {len(g_rows)} requests (load ok={rg.get('ok')}, {rg.get('error')}; "
          f"proxy A answered auth states {g_proxy}; app challenges {rg.get('challenges')}); "
          f"SOCKS5, wrong password: the site saw {len(h_rows)} (load ok={rh.get('ok')}, {rh.get('error')})", core=True)
    await APP.cmd("session", session="J", store=stores["J"], proxies=[proxy_a], answerProxyAuth=False)
    rj = await APP.cmd("load", session="J", url=f"http://{tok('p', 'J')}.lumentest:{hp}/page?sid=J", timeout=25)
    check("q1.applyCredential-alone", "INFO",
          f"HTTP proxy with applyCredential and the app cancelling every proxy challenge: ok={rj.get('ok')} "
          f"({rj.get('error')}), challenges {rj.get('challenges')}")

    # 8. Leaks the page cannot see: DNS and WebRTC.
    await asyncio.sleep(2)
    stuns = [e for e in EVENTS if e["kind"] == "stun"]
    for sid in "AB":
        value = seen[sid].get("value") if isinstance(seen[sid].get("value"), dict) else {}
        cands = (value.get("rtc") or {}).get("candidates") or []
        srflx = [c for c in cands if " srflx " in c]
        check(f"q1.{sid}.webrtc", "LEAK" if stuns or srflx else "INFO",
              f"RTCPeerConnection: {('absent' if (value.get('rtc') or {}).get('absent') else str(len(cands)) + ' candidates')}; "
              f"srflx {srflx[:2]}; the STUN server got {len(stuns)} binding requests from {sorted({e['src'] for e in stuns})}")
    if capture.state.startswith("running"):
        await asyncio.sleep(1)
        socket_ok = True
        try:
            socket.getaddrinfo(f"selfcheck-{run}.lumentest", 80)
        except OSError:
            socket_ok = False
        await asyncio.sleep(2)
        self_seen = capture.seen(f"selfcheck-{run}")
        control_seen = capture.seen(tok("p", "C"))
        detector = bool(self_seen) and bool(control_seen)
        check("q1.dns.detector-sees-a-leak", "PASS" if detector else "INCONCLUSIVE",
              f"this Mac's own question for selfcheck-{run}: {len(self_seen)} lines; the session without a proxy (C): "
              f"{len(control_seen)} lines {control_seen[:1]}", core=False)
        leaks = {}
        for sid in "AB":
            for prefix in ("p", "s", "x", "ws", "wk", "bc", "fr", "an", "pc", "pf"):
                lines = capture.seen(tok(prefix, sid))
                if lines:
                    leaks[tok(prefix, sid)] = lines[:2]
        prefetch = {k: v for k, v in leaks.items() if k.startswith(("pf-", "pc-", "an-"))}
        loads_leak = {k: v for k, v in leaks.items() if k not in prefetch}
        check("q1.dns.page-names", ("FAIL" if loads_leak else "PASS") if detector else "INCONCLUSIVE",
              f"names of A's and B's loads asked of this Mac's resolver: {loads_leak or 'none'}", core=detector)
        check("q1.dns.prefetch", ("LEAK" if prefetch else "PASS") if detector else "INCONCLUSIVE",
              f"<link rel=dns-prefetch>, preconnect, <a href> names asked of this Mac's resolver: {prefetch or 'none'}")
    else:
        check("q1.dns", "INCONCLUSIVE", f"no DNS capture ({capture.state})")


# ---------------------------------------------------------------- main

SERVERS = {}


async def main():
    global ARGS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", default="q1")
    parser.add_argument("--brk", choices=["none", "noproxy", "swap", "sharestore"], default="none")
    parser.add_argument("--out", default="out")
    parser.add_argument("--listen", default="127.0.0.1", help="0.0.0.0 for a real iPhone")
    parser.add_argument("--proxy-host", default="127.0.0.1", help="the proxies' address as the app sees it")
    parser.add_argument("--lan-ip", default="", help="this Mac's address on the network (fail-closed and STUN checks)")
    parser.add_argument("--bind-a", default="", help="source address of proxy A's upstream connections (127.0.0.2)")
    parser.add_argument("--bind-b", default="", help="source address of proxy B's upstream connections (127.0.0.3)")
    parser.add_argument("--cert", default="", help="PEM certificate and key for the HTTPS site (*.lumentest)")
    parser.add_argument("--key", default="")
    parser.add_argument("--capture", default="", help="tcpdump interface for DNS (pktap,all on macOS; empty: none)")
    parser.add_argument("--socks-no-auth", action="store_true", help="proxy B without credentials (a client that has no SOCKS5 auth)")
    parser.add_argument("--static-dir", default="")
    parser.add_argument("--wait-app", type=float, default=240)
    parser.add_argument("--control-port", type=int, default=28310)
    parser.add_argument("--http-port", type=int, default=28380)
    parser.add_argument("--https-port", type=int, default=28443)
    parser.add_argument("--port-a", type=int, default=28381)
    parser.add_argument("--port-b", type=int, default=28382)
    parser.add_argument("--port-f", type=int, default=28384)
    parser.add_argument("--port-dead", type=int, default=28389)
    parser.add_argument("--stun-port", type=int, default=3478)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--run", default="")
    ARGS = parser.parse_args()
    ARGS.run = ARGS.run or "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
    os.makedirs(ARGS.out, exist_ok=True)
    listen = ARGS.listen
    loop = asyncio.get_running_loop()
    SERVERS["control"] = await asyncio.start_server(control_handler, listen, ARGS.control_port)
    SERVERS["http"] = await asyncio.start_server(lambda r, w: site_handler(r, w, "http"), "0.0.0.0", ARGS.http_port)
    if ARGS.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(ARGS.cert, ARGS.key)
        context.set_alpn_protocols(["http/1.1"])
        SERVERS["https"] = await asyncio.start_server(lambda r, w: site_handler(r, w, "https"), "0.0.0.0", ARGS.https_port, ssl=context)
    SERVERS["A"] = await asyncio.start_server(http_proxy("A", "ua:pa", ARGS.bind_a), listen, ARGS.port_a)
    SERVERS["B"] = await asyncio.start_server(socks_proxy("B", None if ARGS.socks_no_auth else "ub:pb", ARGS.bind_b), listen, ARGS.port_b)
    SERVERS["F"] = await asyncio.start_server(http_proxy("F", None, ""), listen, ARGS.port_f)
    await loop.create_datagram_endpoint(Stun, local_addr=("0.0.0.0", ARGS.stun_port))
    capture = Capture(os.path.join(ARGS.out, "dns.txt"), ARGS.capture)
    capture.start()
    print(f"harness up: run {ARGS.run}, scenario {ARGS.scenario}, break {ARGS.brk}, control {listen}:{ARGS.control_port}, "
          f"capture {capture.state}", flush=True)
    try:
        await asyncio.wait_for(APP.hello.wait(), ARGS.wait_app)
    except asyncio.TimeoutError:
        check("app", "FAIL", f"the app did not call in within {ARGS.wait_app}s", core=True)
    else:
        print("app:", json.dumps(APP.info), flush=True)
        try:
            if ARGS.scenario == "q1":
                await scenario_q1(capture)
            else:
                import importlib
                module = importlib.import_module(ARGS.scenario)
                await module.scenario(sys.modules[__name__], capture)
        except Exception as error:
            import traceback
            traceback.print_exc()
            check("scenario", "FAIL", f"the scenario stopped: {error!r}", core=True)
        await APP.cmd("exit", timeout=10)
    capture.stop()
    with open(os.path.join(ARGS.out, "events.jsonl"), "w") as f:
        for e in EVENTS:
            f.write(json.dumps(e) + "\n")
    with open(os.path.join(ARGS.out, "checks.json"), "w") as f:
        json.dump({"run": ARGS.run, "break": ARGS.brk, "app": APP.info, "checks": CHECKS}, f, indent=1)
    core = [c for c in CHECKS if c["core"]]
    failed = [c["name"] for c in core if c["status"] != "PASS"]
    print(f"\nSUMMARY scenario={ARGS.scenario} break={ARGS.brk} os={APP.info.get('os')}: "
          f"{len(core) - len(failed)}/{len(core)} core checks passed" + (f"; failed: {failed}" if failed else ""), flush=True)
    for c in CHECKS:
        if c["status"] in ("LEAK",):
            print(f"LEAK-SUMMARY {c['name']}: {c['detail']}")
    return 0 if core and not failed else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
