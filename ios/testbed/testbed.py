#!/usr/bin/env python3
"""The testbed of Lumen for iPhone's end-to-end tests: everything the app reaches in a test is on
this Mac, so a test sees on the screen what the pages say about how they were reached.

  site      http://127.0.0.1:28380 (and any *.lumentest name, through a proxy)
            /page/<name>   a page titled <name>, a link "Дальше" to /page/<name>-next
            /state[?set=V] shows (and with ?set sets) the page's cookie, localStorage and IndexedDB,
                           and the Cookie header the server got
            /cache         shows the value of /cache.js, which the server counts and lets be cached
            /whoami        shows the address the site saw and which proxy that is
            /served        "served: N", N counting the times the server sent this page (never cached)
            /whoami and /env also say which request they answer ("at: /env?x=1"), and /env counts its loads
            /env           what a page reads: User-Agent (and the one the server got), time zone,
                           language, canvas (two reads), WebGL, audio, and the natives check
                           (scripts/test-shims.mjs's probeLies) over every function the app may replace
                           and whether a worker made from a blob reads the page's canvas ("worker: same …")
            /geo.json      a geolocation service: the country and time zone of the proxy it came through
            /hold          a page that keeps a WebSocket to /ws open and says so ("ws: open", then
                           "ws: closed" once anything closes it), and which proxy it came through
            /ws            a WebSocket that stays open, saying nothing, until its client goes
            /ip.json       an address echo ({"ip": the address the site saw}), open to any page (CORS)
  proxy A   HTTP, Basic auth ua:pa, port 28381, exits from 127.0.0.2 (Germany in /geo.json)
  proxy B   SOCKS5, user/password ub:pb, port 28382, exits from 127.0.0.3 (USA in /geo.json); refuses UDP
  proxy C   SOCKS5, user/password uc:pc, port 28383, relays UDP (UDP ASSOCIATE)
  proxy D   HTTP, Basic auth ud:pd, port 28384; /__proxy?name=D&state=off stops it (and its open
            connections), state=on starts it again. Nothing listens on 28389 and 28390 (dead proxies).
  proxy E   port 28391: takes the connection and never answers a byte (a proxy that hangs)
  DNS       UDP 127.0.0.1:28353 answers *.lumentest with 127.0.0.1 for this Mac's own resolver
            (/etc/resolver/lumentest, set up by ci.sh): a page that goes around its proxy then
            reaches the site directly, and says "via: напрямую" (CI run 12: the app's web view does;
            the simulator's Safari did not). lan-* names get this Mac's network address
            (--lan-address), for the CI probe that compares the two.
  /__seen?token=T  how many site requests (by Host) and DNS questions this testbed got with T in them,
                   by which route ("route T: direct=1 A=0 B=2 D=0 "), and how many site connections
                   that served such a request are open now ("open T: 1")
  Site connections are kept alive between requests (60 s), as real sites keep them.
  STUN      UDP 127.0.0.1:3478 (stun.lumentest through a proxy), answers Binding requests
  account   http://127.0.0.1:28395: a stand-in for the Lumen account server (account.py — sign-in,
            activation, the signed document of rights). The site shows and changes its accounts:
            /__account?email=E[&set=S]; and has the site's robot check, <anything>/robot-check?action=A:
            a button that hands the app's window its token (window.webkit.messageHandlers.lumenRobotCheck)
  /__events everything the site and the proxies saw, as JSON (for the tests' own bookkeeping)

    python3 ios/testbed/testbed.py --out build/testbed
"""
import argparse
import asyncio
import base64
import hashlib
import html
import json
import os
import socket
import struct
import time
import urllib.parse

import account

EVENTS = []
KEEP_ALIVE = 60   # seconds a site connection may stay idle between requests
UPSTREAM = {}          # (ip, port) of a proxy's upstream socket -> proxy name
CACHE_COUNTER = [0]
SERVED_COUNTER = [0]
OPEN = {}              # Host -> site connections open now that have served a request for it
ENV_COUNTER = [0]
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



# The App Store's screenshots (ScreenshotTests, --demo): what a session's own page sees of it — its time
# zone, language and local time as the page's scripts read them, and whether it came through the proxy
# (the testbed knows). Served for http://check.example/ (?l=en for English); words of the owner's
# positioning only (release_rules.py).
DEMO_TEXT = {
    "ru": {"title": "Проверка сессии", "through": "Через прокси", "direct": "Напрямую", "zone": "Часовой пояс",
           "lang": "Язык страницы", "time": "Местное время", "cookies": "Куки этой сессии", "own": "только свои",
           "note": "Каждая сессия — своё хранилище, свой прокси, свой часовой пояс и язык."},
    "en": {"title": "Session check", "through": "Through the proxy", "direct": "Direct", "zone": "Time zone",
           "lang": "Page language", "time": "Local time", "cookies": "This session's cookies", "own": "its own only",
           "note": "Each session has its own storage, its own proxy, its own time zone and language."},
}


def demo_page(language, via):
    t = DEMO_TEXT.get(language, DEMO_TEXT["ru"])
    route = t["direct"] if via == "direct" else t["through"]
    row = lambda key, value, ident: (f"<div class=row><span>{t[key]}</span><b id={ident}>{value}</b></div>")
    return (f"<!doctype html><html lang={language}><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width, initial-scale=1'>"
            f"<title>{t['title']}</title><style>"
            "body{margin:0;font:17px -apple-system,system-ui;background:#f4f5f8;color:#14161c}"
            "main{padding:28px 20px} h1{font-size:30px;margin:8px 0 20px}"
            ".badge{display:inline-flex;align-items:center;gap:8px;padding:8px 14px;border-radius:999px;"
            "background:#e3f6ea;color:#127a3e;font-weight:600}"
            ".badge i{width:9px;height:9px;border-radius:50%;background:#1fb35c;display:inline-block}"
            ".card{margin-top:22px;background:#fff;border-radius:18px;box-shadow:0 1px 3px rgba(0,0,0,.08)}"
            ".row{display:flex;justify-content:space-between;padding:16px 18px;border-top:1px solid #eef0f4}"
            ".row:first-child{border-top:0} .row span{color:#6a7080} p{color:#6a7080;line-height:1.45;margin-top:22px}"
            "</style></head><body><main>"
            f"<div class=badge id=route><i></i>{route}</div><h1>{t['title']}</h1><div class=card>"
            + row("zone", "…", "zone") + row("lang", "…", "lang") + row("time", "…", "time") + row("cookies", t["own"], "cookies")
            + f"</div><p>{t['note']}</p></main><script>"
            "const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;"
            "document.getElementById('zone').textContent = zone;"
            "document.getElementById('lang').textContent = navigator.language;"
            "document.getElementById('time').textContent = new Date().toLocaleTimeString(navigator.language,"
            " {hour: '2-digit', minute: '2-digit', timeZone: zone});"
            "</script></body></html>")


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
  // window.browser as Safari has it (WebKit's WebPageNamespace): its class, runtime's, the property.
  // Its line's element is not named "browser": an element's id is a window property too, and
  // without the namespace window.browser would be that element.
  show('webpagens', 'browser: ' + (() => { try {
    if (!Object.prototype.hasOwnProperty.call(window, 'browser')) return 'absent';
    const b = window.browser, d = Object.getOwnPropertyDescriptor(window, 'browser'), r = b && b.runtime;
    return [Object.prototype.toString.call(b), Object.getOwnPropertyNames(b).sort().join(','), Object.prototype.toString.call(r),
      r ? Object.getOwnPropertyNames(Object.getPrototypeOf(r)).sort().join(',') : '-',
      ['own', d.enumerable, d.configurable, d.writable, typeof d.value].join(',')].join(' ');
  } catch (e) { return 'error ' + e.message; } })());
  draw(); // the first drawing after a launch can differ while fonts load (measured): read the ones after
  show('canvas', 'canvas: ' + fnv(draw().toDataURL()));
  show('canvas2', 'canvas2: ' + fnv(draw().toDataURL()));
  // getImageData against the canvas's PNG: drawn back into a canvas (png:, the stand q2's
  // dataURLvsImageData) and the PNG's own bytes, inflated here (pngbytes:). A native canvas gives 0
  // for both; a noise the canvas cannot hold gives more (18 and ~100 bytes, ios-measure/canvas-alpha).
  try {
    const pc = draw(); const read = pc.getContext('2d').getImageData(0, 0, 240, 60).data; const url = pc.toDataURL();
    const img = new Image(); img.src = url; await img.decode();
    const back = document.createElement('canvas'); back.width = 240; back.height = 60; const bx = back.getContext('2d'); bx.drawImage(img, 0, 0);
    const drawn = bx.getImageData(0, 0, 240, 60).data; let png = 0; for (let i = 0; i < drawn.length; i++) if (drawn[i] !== read[i]) png++;
    show('png', 'png: ' + png);
    const bin = atob(url.split(',')[1]); const bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const u32 = (o) => ((bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]) >>> 0;
    let pos = 8, width = 0, height = 0, colour = 0, depth = 0; const idat = [];
    while (pos < bytes.length) { const len = u32(pos), kind = String.fromCharCode(...bytes.subarray(pos + 4, pos + 8));
      if (kind === 'IHDR') { width = u32(pos + 8); height = u32(pos + 12); depth = bytes[pos + 16]; colour = bytes[pos + 17]; }
      if (kind === 'IDAT') idat.push(bytes.subarray(pos + 8, pos + 8 + len)); pos += 12 + len; }
    if (depth !== 8 || colour !== 6) show('pngbytes', 'pngbytes: PNG depth ' + depth + ' colour type ' + colour);
    else {
      const raw = new Uint8Array(await new Response(new Blob(idat).stream().pipeThrough(new DecompressionStream('deflate'))).arrayBuffer());
      const stride = width * 4; const out = new Uint8Array(stride * height); let prev = new Uint8Array(stride);
      for (let y = 0; y < height; y++) { const f = raw[y * (stride + 1)]; const line = raw.slice(y * (stride + 1) + 1, (y + 1) * (stride + 1));
        for (let i = 0; i < stride; i++) { const l = i >= 4 ? line[i - 4] : 0, u = prev[i], c = i >= 4 ? prev[i - 4] : 0;
          const p = l + u - c, pa = Math.abs(p - l), pb = Math.abs(p - u), pc2 = Math.abs(p - c);
          line[i] = (line[i] + (f === 1 ? l : f === 2 ? u : f === 3 ? (l + u) >> 1 : f === 4 ? (pa <= pb && pa <= pc2 ? l : pb <= pc2 ? u : c) : 0)) & 255; }
        out.set(line, y * stride); prev = line; }
      let differ = 0; for (let i = 0; i < out.length; i++) if (out[i] !== read[i]) differ++;
      show('pngbytes', 'pngbytes: ' + differ);
    }
  } catch (e) { show('png', 'png: error ' + e.message); show('pngbytes', 'pngbytes: error'); }
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
  // A worker made from a blob draws the same on an OffscreenCanvas: does it read what the page reads?
  // (PrivacyScripts' hookWorkers is installed only with a replaced time zone, so with the device's own
  // zone a noised session's worker read the real canvas — the mac app's fix, 8 November.)
  const paint = (c) => { const x = c.getContext('2d'); x.textBaseline = 'top'; x.font = '14px Arial'; x.fillStyle = '#f60';
    x.fillRect(125, 1, 62, 20); x.fillStyle = '#069'; x.fillText('Lumen \u2713 Cwm fjordbank glyphs vext quiz', 2, 15);
    x.fillStyle = 'rgba(102, 204, 0, 0.7)'; x.fillText('Lumen \u2713', 4, 35);
    const d = x.getImageData(0, 0, c.width, c.height).data; let h = 0x811c9dc5;
    for (let i = 0; i < d.length; i++) { h ^= d[i]; h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(16).padStart(8, '0'); };
  try {
    paint(new OffscreenCanvas(240, 60));
    const mine = paint(new OffscreenCanvas(240, 60));
    const source = 'const paint = ' + paint.toString() + '; paint(new OffscreenCanvas(240, 60));'
      + ' postMessage({ hash: paint(new OffscreenCanvas(240, 60)), tz: Intl.DateTimeFormat().resolvedOptions().timeZone });';
    const url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
    const theirs = await new Promise((done) => {
      const worker = new Worker(url);
      const timer = setTimeout(() => done({ hash: 'no answer in 10 s' }), 10000);
      worker.onmessage = (e) => { clearTimeout(timer); done(e.data); worker.terminate(); };
      worker.onerror = (e) => { clearTimeout(timer); done({ hash: 'error ' + (e.message || e) }); };
    });
    show('worker', 'worker: ' + (theirs.hash === mine ? 'same ' + mine : 'differs: page ' + mine + ', worker ' + theirs.hash));
  } catch (e) { show('worker', 'worker: error ' + e); }
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
    hosts = set()   # the Hosts this connection has served
    try:
        # Keep-alive, as real sites do: a connection serves request after request until it has been
        # idle for KEEP_ALIVE seconds or the client asks to close. (CI runs 14, 15: after a live proxy
        # change WebKit reused a connection already open; with every response closing its connection
        # that happened only by chance, on a connection WebKit had opened ahead.)
        while True:
            try:
                method, target, _, headers = await asyncio.wait_for(read_head(reader), KEEP_ALIVE)
            except asyncio.TimeoutError:
                break
            url = urllib.parse.urlsplit(target)
            query = dict(urllib.parse.parse_qsl(url.query))
            via = UPSTREAM.get((peer[0], peer[1]), "direct")
            host = header(headers, "Host") or ""
            if host not in hosts:
                hosts.add(host)
                OPEN[host] = OPEN.get(host, 0) + 1
            event("site", path=url.path, query=query, host=header(headers, "Host"), peer=peer[0], via=via,
                  cookie=header(headers, "Cookie"), ua=header(headers, "User-Agent"), lang=header(headers, "Accept-Language"))
            path = url.path
            if path == "/ws" and (header(headers, "Upgrade") or "").lower() == "websocket":
                # A connection that stays open for as long as the client keeps it: what a proxy change
                # or a network change must close (an idle keep-alive one WebKit may close by itself).
                accept = base64.b64encode(hashlib.sha1(((header(headers, "Sec-WebSocket-Key") or "")
                                                         + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                              f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
                await writer.drain()
                while await reader.read(4096):
                    pass
                break
            if host.split(":")[0] == "check.example":
                if query.get("wait"):   # the design's k-loading: a page that takes its time to come
                    await asyncio.sleep(min(float(query["wait"]), 30))
                out = reply("200 OK", demo_page(query.get("l", "ru"), via), extra=["Cache-Control: no-store"])
            elif path.startswith("/page/"):
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
            elif path == "/__proxy":
                on = query.get("state") == "on"
                await switch(query.get("name", ""), on)
                out = reply("200 OK", page("proxy", f"<p>proxy {html.escape(query.get('name', ''))}: {'on' if on else 'off'}</p>"
                                                    f"<p>at: {html.escape(target)}</p>"), extra=["Cache-Control: no-store"])
            elif path == "/__seen":
                token = query.get("token", "")
                hits = sum(1 for e in EVENTS if e["kind"] == "site" and token and token in (e.get("host") or ""))
                asked = sum(1 for e in EVENTS if e["kind"] == "dns" and token and token in e.get("name", ""))
                routes = {v: sum(1 for e in EVENTS if e["kind"] == "site" and token and token in (e.get("host") or "") and e.get("via") == v)
                          for v in ("direct", "A", "B", "D")}
                route = " ".join(f"{k}={n}" for k, n in routes.items())
                still = sum(n for h, n in OPEN.items() if token and token in h)
                out = reply("200 OK", page("seen", f"<p>site {html.escape(token)}: {hits}</p><p>dns {html.escape(token)}: {asked}</p>"
                                                   f"<p>route {html.escape(token)}: {route} </p><p>open {html.escape(token)}: {still}</p>"
                                                   f"<p>at: {html.escape(target)}</p>"), extra=["Cache-Control: no-store"])
            elif path == "/__account":
                lines = "".join(f"<p>{html.escape(line)}</p>" for line in account.control(query))
                out = reply("200 OK", page("account", lines + f"<p>at: {html.escape(target)}</p>"), extra=["Cache-Control: no-store"])
            elif path.endswith("/robot-check"):
                # The site's robot check as the app's own window shows it (CONTRACT.md §5.5): the page
                # hands its token to the app; the stand-in's token says which action it is for.
                action = query.get("action", "")
                out = reply("200 OK", page("robot-check", f"<h1>Проверка</h1><p>action: {html.escape(action)}</p>"
                                                           "<p><button id=robot style='font-size:22px'>Я не робот</button></p>"
                                                           "<p id=sent>token: not sent</p>",
                                           "document.getElementById('robot').onclick = () => {"
                                           f"  window.webkit.messageHandlers.lumenRobotCheck.postMessage('robot-ok-' + {json.dumps(action)});"
                                           "  document.getElementById('sent').textContent = 'token: sent'; };"),
                            extra=["Cache-Control: no-store"])
            elif path == "/served":
                SERVED_COUNTER[0] += 1
                out = reply("200 OK", page("served", f"<h1>Счётчик</h1><p id=n>served: {SERVED_COUNTER[0]}</p>"),
                            extra=["Cache-Control: no-store"])
            elif path == "/hold":
                name = {"A": "прокси A", "B": "прокси B", "D": "прокси D"}.get(via, "напрямую")
                out = reply("200 OK", page("hold", f"<h1>Держит</h1><p id=via>via: {name}</p><p id=ws>ws: …</p>"
                                                   f"<p>at: {html.escape(target)}</p>",
                                           "const w = document.getElementById('ws');"
                                           "const s = new WebSocket('ws://' + location.host + '/ws');"
                                           "s.onopen = () => { w.textContent = 'ws: open'; };"
                                           "s.onclose = () => { w.textContent = 'ws: closed'; };"),
                            extra=["Cache-Control: no-store"])
            elif path == "/whoami":
                name = {"A": "прокси A", "B": "прокси B", "D": "прокси D"}.get(via, "напрямую")
                # A direct request says so on its "at:" line too: the line a test finds the page by (CI runs
                # 20, 21: the page loaded directly, and the "via:" paragraph was not found on the screen).
                direct = " — напрямую" if via == "direct" else ""
                out = reply("200 OK", page("whoami", f"<h1>Адрес</h1><p id=ip>ip: {peer[0]}</p><p id=via>via: {name}</p>"
                                                     f"<p>at: {html.escape(target)}{direct}</p>"), extra=["Cache-Control: no-store"])
            elif path == "/env":
                lines = "".join(f"<p id={i}>{i}: …</p>" for i in ("ua", "tz", "lang", "webpagens", "canvas", "canvas2", "png", "pngbytes", "webgl", "audio", "lies", "worker"))
                ENV_COUNTER[0] += 1
                served = (f"<p>server ua: {header(headers, 'User-Agent')}</p><p>server lang: {header(headers, 'Accept-Language')}</p>"
                          f"<p>at: {html.escape(target)}</p><p>load: {ENV_COUNTER[0]}</p>")
                out = reply("200 OK", page("env", "<h1>Среда</h1>" + lines + served,
                                           "const PROBE_LIES = " + json.dumps(probe_lies()) + ";" + ENV_SCRIPT),
                            extra=["Cache-Control: no-store"])
            elif path == "/geo.json":
                _, country, zone, ip = EXITS.get(peer[0], ("direct", "ZZ", "UTC", "198.51.100.1"))
                out = reply("200 OK", json.dumps({"ip": ip, "country": country, "timezone": zone}), "application/json")
            elif path == "/ip.json":
                # The address echo the network probe asks (ios/Lumen/Debug/NetProbe.swift), from a page and directly.
                out = reply("200 OK", json.dumps({"ip": peer[0]}), "application/json",
                            ["Access-Control-Allow-Origin: *", "Cache-Control: no-store"])
            elif path == "/__events":
                out = reply("200 OK", json.dumps(EVENTS), "application/json")
            else:
                out = reply("200 OK", page("ok", "<h1>ok</h1>"))
            keep = (header(headers, "Connection") or "").lower() != "close"
            if keep:
                out = out.replace(b"Connection: close\r\n", b"Connection: keep-alive\r\nKeep-Alive: timeout=60\r\n", 1)
            writer.write(out)
            await writer.drain()
            if not keep:
                break
    except (asyncio.IncompleteReadError, ConnectionError, ValueError):
        pass
    finally:
        for host in hosts:
            OPEN[host] -= 1
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
    if host.endswith(".example"):   # the screenshots' demo page (--demo): http://check.example/ is the site
        target, port = "127.0.0.1", 28380
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


class LumentestDNS(asyncio.DatagramProtocol):
    """*.lumentest for this Mac's own resolver: A 127.0.0.1, nothing else. Every question is an event."""
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        try:
            tid = struct.unpack(">H", data[:2])[0]
            i, labels = 12, []
            while data[i] != 0:
                n = data[i]
                labels.append(data[i + 1:i + 1 + n].decode("latin-1"))
                i += 1 + n
            i += 1
            qtype = struct.unpack(">H", data[i:i + 2])[0]
            question = data[12:i + 4]
        except Exception:
            return
        name = ".".join(labels).lower()
        event("dns", name=name, qtype=qtype)
        ours = name == "lumentest" or name.endswith(".lumentest") or name.endswith(".example")   # .example: --demo
        address = LAN_ADDRESS[0] if name.startswith("lan-") else "127.0.0.1"
        answer = b""
        if ours and qtype == 1:
            answer = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 5, 4) + socket.inet_aton(address)
        flags = 0x8580 if ours else 0x8583          # an answer, authoritative; NXDOMAIN for other names
        self.transport.sendto(struct.pack(">HHHHHH", tid, flags, 1, 1 if answer else 0, 0, 0) + question + answer, addr)


SWITCHABLE = {}   # name -> {"port", "handler", "server", "conns"}: proxies a test can stop and start
LAN_ADDRESS = ["127.0.0.1"]   # what lan-*.lumentest resolves to (--lan-address: this Mac's network address)


def switchable(name, port, handler):
    SWITCHABLE[name] = {"port": port, "handler": handler, "server": None, "conns": set()}


async def switch(name, on):
    entry = SWITCHABLE.get(name)
    if not entry:
        return
    if on and entry["server"] is None:
        async def handle(reader, writer):
            entry["conns"].add(writer)
            try:
                await entry["handler"](reader, writer)
            finally:
                entry["conns"].discard(writer)
        entry["server"] = await asyncio.start_server(handle, "127.0.0.1", entry["port"])
        event("switch", proxy=name, state="on")
    elif not on and entry["server"] is not None:
        entry["server"].close()           # no new connections: the port refuses
        for writer in list(entry["conns"]):
            writer.close()                # and the open ones (a kept tunnel) end with it
        entry["server"] = None
        event("switch", proxy=name, state="off")


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


async def silent_proxy(reader, writer):
    """Proxy E: reads whatever comes and never answers, until the client gives up."""
    event("proxy", proxy="E", silent=True)
    try:
        while await reader.read(4096):
            pass
    except Exception:
        pass
    finally:
        writer.close()


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="testbed")
    parser.add_argument("--lan-address", default="127.0.0.1", help="what lan-*.lumentest resolves to")
    parser.add_argument("--demo", action="store_true", help="the screenshots' proxy: HTTP berlin:demo on 8080")
    args = parser.parse_args()
    LAN_ADDRESS[0] = args.lan_address
    os.makedirs(args.out, exist_ok=True)
    await asyncio.start_server(site, "0.0.0.0", 28380)
    await asyncio.start_server(http_proxy("A", "ua:pa", "127.0.0.2"), "127.0.0.1", 28381)
    await asyncio.start_server(socks_proxy("B", "ub:pb", "127.0.0.3"), "127.0.0.1", 28382)
    await asyncio.start_server(socks_proxy("C", "uc:pc", "", udp=True), "127.0.0.1", 28383)
    switchable("D", 28384, http_proxy("D", "ud:pd", ""))
    await asyncio.start_server(silent_proxy, "127.0.0.1", 28391)
    if args.demo:   # the App Store's screenshots: the seeded "Berlin" proxy, de.proxy.example:8080 (AppStoreSeed.swift)
        await asyncio.start_server(http_proxy("demo", "berlin:demo", "127.0.0.2"), "127.0.0.1", 8080)
    await account.start(event)
    await switch("D", True)
    await asyncio.get_running_loop().create_datagram_endpoint(Stun, local_addr=("127.0.0.1", 3478))
    await asyncio.get_running_loop().create_datagram_endpoint(LumentestDNS, local_addr=("127.0.0.1", 28353))
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
