#!/usr/bin/env python3
"""The testbed of Lumen for iPhone's end-to-end tests: everything the app reaches in a test is on
this Mac, so a test sees on the screen what the pages say about how they were reached.

  site      http://127.0.0.1:28380 (and any *.lumentest name, through a proxy)
            /page/<name>   a page titled <name>, a link "Дальше" to /page/<name>-next
            /state[?set=V] shows (and with ?set sets) the page's cookie, localStorage and IndexedDB,
                           and the Cookie header the server got
            /cache         shows the value of /cache.js, which the server counts and lets be cached
            /whoami        shows the address the site saw and which proxy that is
            /env           what a page reads: User-Agent (and the one the server got), time zone,
                           language, canvas (two reads), WebGL, audio, and the natives check
                           (scripts/test-shims.mjs's probeLies) over every function the app may replace
            /geo.json      a geolocation service: the country and time zone of the proxy it came through
  proxy A   HTTP, Basic auth ua:pa, port 28381, exits from 127.0.0.2 (Germany in /geo.json)
  proxy B   SOCKS5, user/password ub:pb, port 28382, exits from 127.0.0.3 (USA in /geo.json); refuses UDP
  proxy C   SOCKS5, user/password uc:pc, port 28383, relays UDP (UDP ASSOCIATE)
  STUN      UDP 127.0.0.1:3478 (stun.lumentest through a proxy), answers Binding requests
  /__events everything the site and the proxies saw, as JSON (for the tests' own bookkeeping)

    python3 ios/testbed/testbed.py --out build/testbed
"""
import argparse
import asyncio
import base64
import json
import os
import socket
import struct
import time
import urllib.parse

EVENTS = []
UPSTREAM = {}          # (ip, port) of a proxy's upstream socket -> proxy name
CACHE_COUNTER = [0]
EXITS = {"127.0.0.2": ("A", "DE", "Europe/Berlin", "203.0.113.10"),
         "127.0.0.3": ("B", "US", "America/New_York", "203.0.113.20")}


def event(kind, **fields):
    fields.update(kind=kind, t=round(time.time(), 3))
    EVENTS.append(fields)


async def read_head(reader):
    data = await reader.readuntil(b"\r\n\r\n")
    lines = data.decode("latin-1").split("\r\n")
    method, target, version = lines[0].split(" ", 2)
    headers = [(k.strip(), v.strip()) for k, _, v in (line.partition(":") for line in lines[1:] if line)]
    return method, target, version, headers


def header(headers, name):
    return next((v for k, v in headers if k.lower() == name.lower()), None)


def reply(status, body, kind="text/html; charset=utf-8", extra=()):
    body = body.encode() if isinstance(body, str) else body
    head = [f"HTTP/1.1 {status}", f"Content-Type: {kind}", f"Content-Length: {len(body)}", "Connection: close"]
    head += list(extra)
    return ("\r\n".join(head) + "\r\n\r\n").encode() + body


def page(title, body, script=""):
    return (f"<!doctype html><html lang=ru><head><meta charset=utf-8><meta name=viewport content='width=device-width, initial-scale=1'>"
            f"<title>{title}</title><style>body{{font:18px -apple-system;margin:24px}} a{{font-size:22px}}</style></head>"
            f"<body>{body}<script>{script}</script></body></html>")


REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def probe_lies():
    text = open(os.path.join(REPO, "scripts/test-shims.mjs"), encoding="utf-8").read()
    return text.split("const probeLies = `", 1)[1].split("`;", 1)[0].replace("\\\\", "\\")


ENV_SCRIPT = r"""
const show = (id, text) => { document.getElementById(id).textContent = text; };
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(16).padStart(8, '0'); };
const draw = () => { const c = document.createElement('canvas'); c.width = 240; c.height = 60; const x = c.getContext('2d');
  x.textBaseline = 'top'; x.font = '14px Arial'; x.fillStyle = '#f60'; x.fillRect(125, 1, 62, 20);
  x.fillStyle = '#069'; x.fillText('Lumen \u2713 Cwm fjordbank glyphs vext quiz', 2, 15);
  x.fillStyle = 'rgba(102, 204, 0, 0.7)'; x.fillText('Lumen \u2713', 4, 35); return c; };
(async () => {
  show('ua', 'ua: ' + navigator.userAgent);
  show('tz', 'tz: ' + Intl.DateTimeFormat().resolvedOptions().timeZone);
  show('lang', 'lang: ' + navigator.language);
  draw(); // the first drawing after a launch can differ while fonts load (measured): read the ones after
  show('canvas', 'canvas: ' + fnv(draw().toDataURL()));
  show('canvas2', 'canvas2: ' + fnv(draw().toDataURL()));
  const gl = document.createElement('canvas').getContext('webgl');
  if (!gl) show('webgl', 'webgl: none');
  else { const e = gl.getExtension('WEBGL_debug_renderer_info'); show('webgl', 'webgl: ' + (e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : 'yes')); }
  try {
    const ctx = new OfflineAudioContext(1, 44100, 44100); const o = ctx.createOscillator(); o.type = 'triangle'; o.frequency.value = 10000;
    const k = ctx.createDynamicsCompressor(); o.connect(k); k.connect(ctx.destination); o.start(0);
    const d = (await ctx.startRendering()).getChannelData(0); let sum = 0; for (let i = 4500; i < 5000; i++) sum += Math.abs(d[i]);
    show('audio', 'audio: ' + sum.toFixed(12));
  } catch (e) { show('audio', 'audio: error'); }
  const probeLies = (0, eval)(PROBE_LIES);
  const frame = document.createElement('iframe'); document.body.appendChild(frame);
  const targets = ['HTMLCanvasElement.prototype.toDataURL', 'HTMLCanvasElement.prototype.getContext', 'CanvasRenderingContext2D.prototype.getImageData',
    'WebGLRenderingContext.prototype.readPixels', 'AudioBuffer.prototype.getChannelData', 'Date.prototype.getTimezoneOffset', 'Function.prototype.toString'];
  let lies = 0; const which = [];
  for (const expr of targets) {
    let fn; try { fn = (0, eval)(expr); } catch (e) { continue; }
    if (typeof fn !== 'function') continue;
    const iface = expr.split('.')[0];
    for (const scope of [Function.prototype.toString, frame.contentWindow.Function.prototype.toString]) {
      const Interface = iface !== 'Function' && expr.includes('.prototype.') ? window[iface] : null;
      const found = probeLies(fn, scope, Interface || null, null);
      if (found.length) { lies += found.length; which.push(expr + ': ' + found[0]); }
    }
  }
  show('lies', 'lies: ' + lies + (which.length ? ' ' + which.slice(0, 2).join('; ') : ''));
  document.title = 'env';
})();
"""


STATE_SCRIPT = r"""
const q = new URLSearchParams(location.search), v = q.get('set');
const show = (id, text) => { document.getElementById(id).textContent = text; };
(async () => {
  if (v) { document.cookie = 'lumen=' + v + '; path=/; max-age=86400'; localStorage.setItem('lumen', v); }
  const db = await new Promise((res) => { const r = indexedDB.open('lumen', 1); r.onupgradeneeded = () => r.result.createObjectStore('s'); r.onsuccess = () => res(r.result); r.onerror = () => res(null); });
  if (v && db) await new Promise((res) => { const t = db.transaction('s', 'readwrite'); t.objectStore('s').put(v, 'k'); t.oncomplete = res; t.onerror = res; });
  const idb = db ? await new Promise((res) => { const g = db.transaction('s').objectStore('s').get('k'); g.onsuccess = () => res(g.result || 'none'); g.onerror = () => res('error'); }) : 'error';
  const cookie = (document.cookie.match(/lumen=([^;]+)/) || [])[1] || 'none';
  show('cookie', 'cookie: ' + cookie);
  show('local', 'local: ' + (localStorage.getItem('lumen') || 'none'));
  show('idb', 'idb: ' + idb);
  document.title = 'state ' + cookie;
})();
"""


async def site(reader, writer, scheme="http"):
    peer = writer.get_extra_info("peername")[:2]
    try:
        method, target, _, headers = await read_head(reader)
        url = urllib.parse.urlsplit(target)
        query = dict(urllib.parse.parse_qsl(url.query))
        via = UPSTREAM.get((peer[0], peer[1]), "direct")
        event("site", path=url.path, query=query, host=header(headers, "Host"), peer=peer[0], via=via,
              cookie=header(headers, "Cookie"), ua=header(headers, "User-Agent"), lang=header(headers, "Accept-Language"))
        path = url.path
        if path.startswith("/page/"):
            name = urllib.parse.unquote(path[len("/page/"):]) or "page"
            out = reply("200 OK", page(name, f"<h1>Страница {name}</h1><p><a id=next href='/page/{name}-next'>Дальше</a></p>"))
        elif path == "/state":
            server_cookie = header(headers, "Cookie") or "none"
            out = reply("200 OK", page("state", f"<h1>Состояние</h1><p id=cookie>cookie: …</p><p id=local>local: …</p>"
                                                f"<p id=idb>idb: …</p><p>server cookie: {server_cookie}</p>", STATE_SCRIPT))
        elif path == "/cache":
            out = reply("200 OK", page("cache", "<h1>Кэш</h1><p id=v>cache: …</p><script src='/cache.js'></script>",
                                       "document.getElementById('v').textContent = 'cache: ' + window.lumenCache;"))
        elif path == "/cache.js":
            CACHE_COUNTER[0] += 1
            out = reply("200 OK", f"window.lumenCache = {CACHE_COUNTER[0]};", "text/javascript",
                        ["Cache-Control: public, max-age=3600"])
        elif path == "/whoami":
            name = {"A": "прокси A", "B": "прокси B"}.get(via, "напрямую")
            out = reply("200 OK", page("whoami", f"<h1>Адрес</h1><p id=ip>ip: {peer[0]}</p><p id=via>via: {name}</p>"))
        elif path == "/env":
            lines = "".join(f"<p id={i}>{i}: …</p>" for i in ("ua", "tz", "lang", "canvas", "canvas2", "webgl", "audio", "lies"))
            served = f"<p>server ua: {header(headers, 'User-Agent')}</p><p>server lang: {header(headers, 'Accept-Language')}</p>"
            out = reply("200 OK", page("env", "<h1>Среда</h1>" + lines + served,
                                       "const PROBE_LIES = " + json.dumps(probe_lies()) + ";" + ENV_SCRIPT))
        elif path == "/geo.json":
            _, country, zone, ip = EXITS.get(peer[0], ("direct", "ZZ", "UTC", "198.51.100.1"))
            out = reply("200 OK", json.dumps({"ip": ip, "country": country, "timezone": zone}), "application/json")
        elif path == "/__events":
            out = reply("200 OK", json.dumps(EVENTS), "application/json")
        else:
            out = reply("200 OK", page("ok", "<h1>ok</h1>"))
        writer.write(out)
        await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, ValueError):
        pass
    finally:
        writer.close()


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def upstream(name, host, port, bind):
    target = "127.0.0.1" if host.endswith(".lumentest") or host.startswith("192.0.2.") else host
    local = (bind, 0) if bind and target.startswith("127.") else None
    reader, writer = await asyncio.wait_for(asyncio.open_connection(target, port, local_addr=local), 15)
    sock = writer.get_extra_info("sockname")[:2]
    UPSTREAM[(sock[0], sock[1])] = name
    return reader, writer


def http_proxy(name, auth, bind):
    async def handle(reader, writer):
        try:
            method, target, version, headers = await read_head(reader)
            expected = "Basic " + base64.b64encode(auth.encode()).decode()
            if header(headers, "Proxy-Authorization") != expected:
                event("proxy", proxy=name, auth="refused", target=target)
                writer.write(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"lumen\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                await writer.drain()
                return
            if method == "CONNECT":
                host, _, port = target.rpartition(":")
                up_r, up_w = await upstream(name, host.strip("[]"), int(port), bind)
                event("proxy", proxy=name, auth="ok", host=host, port=int(port))
                writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                await writer.drain()
                await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))
            else:
                u = urllib.parse.urlsplit(target)
                up_r, up_w = await upstream(name, u.hostname, u.port or 80, bind)
                event("proxy", proxy=name, auth="ok", host=u.hostname, port=u.port or 80)
                kept = [(k, v) for k, v in headers if k.lower() not in ("proxy-authorization", "proxy-connection", "connection")]
                up_w.write((f"{method} {u.path or '/'}{'?' + u.query if u.query else ''} {version}\r\n"
                            + "".join(f"{k}: {v}\r\n" for k, v in kept) + "Connection: close\r\n\r\n").encode("latin-1"))
                await up_w.drain()
                await pipe(up_r, writer)
        except Exception:
            pass
        finally:
            writer.close()
    return handle


class UDPRelay(asyncio.DatagramProtocol):
    """One UDP association of proxy C: datagrams from the client, unwrapped and sent on; answers
    wrapped back (RFC 1928 §7)."""
    def __init__(self, name):
        self.name, self.client = name, None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if self.client is None or addr == self.client:
            self.client = addr
            if len(data) < 10 or data[2] != 0:
                return
            atyp = data[3]
            if atyp == 1:
                host, rest = socket.inet_ntoa(data[4:8]), data[8:]
            elif atyp == 3:
                n = data[4]
                host, rest = data[5:5 + n].decode(), data[5 + n:]
            else:
                return
            port = struct.unpack(">H", rest[:2])[0]
            target = "127.0.0.1" if host.endswith(".lumentest") else host
            event("udp", proxy=self.name, host=host, port=port)
            self.transport.sendto(rest[2:], (target, port))
        else:
            header = b"\x00\x00\x00\x01" + socket.inet_aton(addr[0]) + struct.pack(">H", addr[1])
            self.transport.sendto(header + data, self.client)


class Stun(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if len(data) < 20 or struct.unpack(">H", data[:2])[0] != 1:
            return
        event("stun", src=addr[0])
        xport = addr[1] ^ 0x2112
        xip = bytes(a ^ b for a, b in zip(socket.inet_aton(addr[0]), struct.pack(">I", 0x2112A442)))
        attr = struct.pack(">HHBBH", 0x0020, 8, 0, 1, xport) + xip
        self.transport.sendto(struct.pack(">HHI", 0x0101, len(attr), 0x2112A442) + data[8:20] + attr, addr)


def socks_proxy(name, auth, bind, udp=False):
    async def handle(reader, writer):
        try:
            _, n = await reader.readexactly(2)
            methods = await reader.readexactly(n)
            if 2 not in methods:
                writer.write(b"\x05\xff")
                return
            writer.write(b"\x05\x02")
            await writer.drain()
            _, ulen = await reader.readexactly(2)
            user = (await reader.readexactly(ulen)).decode()
            (plen,) = await reader.readexactly(1)
            password = (await reader.readexactly(plen)).decode()
            if f"{user}:{password}" != auth:
                event("proxy", proxy=name, auth="refused")
                writer.write(b"\x01\x01")
                return
            writer.write(b"\x01\x00")
            await writer.drain()
            _, command, _, atyp = await reader.readexactly(4)
            if atyp == 1:
                host = socket.inet_ntoa(await reader.readexactly(4))
            elif atyp == 3:
                (ln,) = await reader.readexactly(1)
                host = (await reader.readexactly(ln)).decode()
            else:
                host = socket.inet_ntop(socket.AF_INET6, await reader.readexactly(16))
            (port,) = struct.unpack(">H", await reader.readexactly(2))
            if command == 3 and udp:   # UDP ASSOCIATE: a relay on this Mac for as long as the TCP connection lives
                transport, _ = await asyncio.get_running_loop().create_datagram_endpoint(lambda: UDPRelay(name), local_addr=("127.0.0.1", 0))
                relay_port = transport.get_extra_info("sockname")[1]
                event("proxy", proxy=name, auth="ok", command="UDP ASSOCIATE", relay=relay_port)
                writer.write(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", relay_port))
                await writer.drain()
                try:
                    await reader.read()
                finally:
                    transport.close()
                return
            if command != 1:   # UDP ASSOCIATE (B) and BIND: refused, as many proxies do
                event("proxy", proxy=name, auth="ok", command=command, host=host, port=port)
                writer.write(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
                return
            up_r, up_w = await upstream(name, host, port, bind)
            event("proxy", proxy=name, auth="ok", host=host, port=port, atyp=atyp)
            writer.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            await writer.drain()
            await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))
        except Exception:
            pass
        finally:
            writer.close()
    return handle


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="testbed")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    await asyncio.start_server(site, "0.0.0.0", 28380)
    await asyncio.start_server(http_proxy("A", "ua:pa", "127.0.0.2"), "127.0.0.1", 28381)
    await asyncio.start_server(socks_proxy("B", "ub:pb", "127.0.0.3"), "127.0.0.1", 28382)
    await asyncio.start_server(socks_proxy("C", "uc:pc", "", udp=True), "127.0.0.1", 28383)
    await asyncio.get_running_loop().create_datagram_endpoint(Stun, local_addr=("127.0.0.1", 3478))
    print("testbed up: site 28380, proxy A (HTTP) 28381, proxy B (SOCKS5) 28382", flush=True)
    try:
        while True:
            await asyncio.sleep(5)
            with open(os.path.join(args.out, "events.json"), "w") as f:
                json.dump(EVENTS, f)
    finally:
        pass


if __name__ == "__main__":
    asyncio.run(main())
