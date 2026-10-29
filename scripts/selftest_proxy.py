#!/usr/bin/env python3
"""Minimal HTTP-CONNECT and SOCKS5 proxy used by `PrivacyBrowser --self-test`.

It never connects anywhere: after the proxy handshake it answers the tunnelled HTTP request
itself with a page that reports how the request arrived, e.g.

    PB-PROXY-OK via=connect target=proxied.selftest.invalid:80 path=/one
    PB-PROXY-OK via=socks5 atyp=3 target=proxied.selftest.invalid:80 path=/

`atyp=3` means the browser sent the *hostname* to the proxy (remote DNS resolution); an
`.invalid` hostname can only load at all if it was not resolved locally.

    python3 scripts/selftest_proxy.py --http 18080 --socks 18081 --http-auth 18082 --http6 18083 \
        --socks2 18084 --socks-auth 18085

`--http-auth` is an HTTP CONNECT proxy that answers 407 until the request carries
`Proxy-Authorization: Basic pb-user:pb-pass`, then reports `via=connect-auth`.
`--http6` is the plain HTTP CONNECT proxy listening on the IPv6 loopback `::1`
(a profile whose proxy host is an IPv6 literal); it reports `via=connect6`.
`--socks2` is a second SOCKS5 proxy, and `--socks-auth` one that accepts only username/password
authentication (RFC 1929) with pb-user2:pb-pass2: several profiles behind different SOCKS5
proxies at once. Every page names the port of the listener that served it (`listener=...`).

Pages also report the request's `Accept-Language` header (`accept-language=...`), the path
`/pb-geo.json` answers like a geolocation service (`{"ip": "203.0.113.7", "timezone":
"Europe/Berlin", "country": "DE"}`; `?ip=`, `?tz=` and `?delay=<seconds>` change the answer) for
the proxy-location checks, and `/pb-served.json` lists the paths served so far (so the self-test
can tell which requests reached the proxy, e.g. that a beacon did not).

`/pb-login` is a sign-in form for the password AutoFill checks (`?signup=1`: a new password and
its confirmation; `?spa=1`: no form, a button whose script removes the fields, as a sign-in by
fetch does; `?autofocus=1`), and `/pb-frame?src=<url>` a page with that URL in an iframe.
`/pb-cookies` shows the request's `Cookie` header (`PB-COOKIES cookie=...`), for the cookie import
checks.

`/pb-warmup/<name>?run=<id>` are pages for the session warm-up robot: each sets a cookie
(`pbwarm_<name>=<id>`), is tall enough to scroll, and has, in view, one plain link to the same site
(`Next article` → `/pb-warmup/<name>-next`) next to links the robot must never follow (sign-out,
another site, a file, a new window); a page-world listener reports the page's scroll, wheel and
click events and whether they were trusted (`/pb-warmup/event/<id>/<name>-<what>`), and what its page
world can see of a robot (`window.webkit`, globals named like one) at its first scroll and click; a
jump to a fragment `#x` is rewritten to `#/x`, as a single-page app's router might. `<name>` `alert`
shows an alert; `broken` closes the connection without an answer (a page that does not load). `/pb-warmup/log.json` lists every `/pb-warmup/` request with its Referer, Cookie and
User-Agent headers and the time it came.

`/pb-leak?run=<id>` is the leak page for a profile hosted in Safari's chrome (SelfTest's
`safariChromeThroughTheProxy`, scripts/egress_check.py): served for any host, it makes every kind of
request a page can make — and that Safari makes for a page (its icons, its OpenSearch
description) — fetches to IPv4 and IPv6 literals in the documentation ranges (TEST-NET
192.0.2.0/24, 2001:db8::/32, which nothing answers and nothing routes), to host names carrying the
run id, a WebSocket, a worker's fetch, an image, a frame, a font, a video, a `<link rel=dns-prefetch>`
and `rel=preconnect`, an `<a ping>`, a beacon, WebRTC and WebTransport where the page has them —
and reports what it could see (`typeof RTCPeerConnection`, in the page, in a frame and in an
about:blank frame) to `/pb-leak/report`. Through this proxy every one of those requests reaches it
(it answers any CONNECT itself); anything that goes around it is a packet to a documentation
address or a DNS query with the run id in it, which a capture on the machine sees.
`/pb-leak/log.json?run=<id>` lists, for that run, every request this proxy answered (its via,
target and path), the page's reports, and the connections the canary listener took for the run.

`/pb-leak/secure?run=<id>` is the leak page's secure-context half, for a profile to open at
`http://127.0.0.1:<port>/` (loopback is a secure context): WebTransport and WebRTC exist only
there, so that is where their absence means something — in the page, a dedicated worker, a shared
worker and a service worker (`/pb-leak/sw.js`) — and it reports `isSecureContext` with them.

TLS: a tunnel to one of the TLS test hosts (`aia-`, `tls-`, `probe-` names, 192.0.2.14) whose client
starts a TLS handshake is answered with a certificate made at start-up whose chain cannot be completed without fetching its
intermediate, from the address it names: `http://pbaiacanary.leak.example.com/` (its OCSP
responder is `pbocspcanary`). Only a certificate check that fetches from the network asks for that
name, so a DNS query for it in the capture is the system's trust service fetching for a profile, as
this Mac (scripts/egress_check.py). `--tls-control <port>` serves the same kind of certificate,
naming `pbaiacontrol`, directly on 127.0.0.1 without a proxy: the self-test loads it in a profile
without one, and the query for that name is the proof that this macOS fetches and the capture sees
it. Needs the `openssl` command; without it, no TLS (said at start-up).

`--canary <port>` listens on 127.0.0.1 and ::1 and notes every connection it takes: the leak page
asks for that port on loopback addresses, which a proxied profile must send to its proxy like
anything else. A connection here is one that went around the proxy.
"""
import argparse
import base64
import functools
import html
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs


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


GEO_ANSWER = b'{"ip":"203.0.113.7","country":"DE","timezone":"Europe/Berlin"}'
SERVED: list = []
SERVED_LOCK = threading.Lock()
WARMUP_LOG: list = []
# Every request answered, with how it came (`via`), where it was for (`target`) and its path.
TARGETS: list = []
# The leak page's reports, by run id.
LEAK_REPORTS: dict = {}
# Connections the canary listener took (each a request that went around the proxy).
CANARY: list = []
CANARY_PORT = 1
# TLS contexts serving a certificate whose chain needs a fetch: "canary" through the proxies,
# "control" on --tls-control. None when the certificates could not be made.
TLS: dict = {}

CERT_CONFIG = """[req]
distinguished_name = dn
prompt = no
[dn]
CN = PB Selftest
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[leaf_canary]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:*.leak.example.com,DNS:localhost,IP:127.0.0.1
authorityInfoAccess = caIssuers;URI:http://pbaiacanary.leak.example.com/i.cer,OCSP;URI:http://pbocspcanary.leak.example.com/
[leaf_control]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:*.leak.example.com,DNS:localhost,IP:127.0.0.1
authorityInfoAccess = caIssuers;URI:http://pbaiacontrol.leak.example.com/i.cer,OCSP;URI:http://pbocspcontrol.leak.example.com/
"""


def make_certificates() -> None:
    """A root, an intermediate it signs and, signed by the intermediate, the two leaf certificates
    of the module docstring. Each leaf is served alone: the chain is complete only for a client
    that fetches the intermediate from the address the leaf names."""
    openssl = shutil.which("openssl")
    if not openssl:
        print("[selftest-proxy] no openssl: HTTPS through the proxies is not answered with TLS", flush=True)
        return
    folder = tempfile.mkdtemp(prefix="pb-selftest-tls-")
    with open(os.path.join(folder, "ext.cnf"), "w") as config:
        config.write(CERT_CONFIG)

    def run(*arguments: str) -> None:
        subprocess.run([openssl, *arguments], check=True, capture_output=True, cwd=folder)

    try:
        run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "root.key", "-out", "root.pem", "-days", "30",
            "-config", "ext.cnf", "-extensions", "v3_ca", "-subj", "/CN=PB Selftest Root")
        run("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "inter.key", "-out", "inter.csr",
            "-config", "ext.cnf", "-subj", "/CN=PB Selftest Intermediate")
        run("x509", "-req", "-in", "inter.csr", "-CA", "root.pem", "-CAkey", "root.key", "-set_serial", "2",
            "-out", "inter.pem", "-days", "30", "-extfile", "ext.cnf", "-extensions", "v3_ca")
        for serial, name in enumerate(("canary", "control"), start=3):
            run("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{name}.key", "-out", f"{name}.csr",
                "-config", "ext.cnf", "-subj", f"/CN={name}.leak.example.com")
            run("x509", "-req", "-in", f"{name}.csr", "-CA", "inter.pem", "-CAkey", "inter.key", "-set_serial", str(serial),
                "-out", f"{name}.pem", "-days", "30", "-extfile", "ext.cnf", "-extensions", f"leaf_{name}")
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(os.path.join(folder, f"{name}.pem"), os.path.join(folder, f"{name}.key"))
            TLS[name] = context
        print(f"[selftest-proxy] TLS certificates made in {folder}", flush=True)
    except (subprocess.CalledProcessError, ssl.SSLError, OSError) as error:
        detail = getattr(error, "stderr", b"") or b""
        print(f"[selftest-proxy] could not make the TLS certificates: {error} {detail[-300:]!r}", flush=True)


def header(request: str, name: str) -> str:
    prefix = name.lower() + ":"
    return next((line.split(":", 1)[1].strip() for line in request.split("\r\n")[1:]
                 if line.lower().startswith(prefix)), "")


def warmup_page(name: str, run: str) -> bytes:
    """A page of the warm-up robot checks (see the module docstring)."""
    def esc(text: str) -> str:
        return html.escape(text, quote=True)
    q = f"?run={esc(run)}"
    links = (
        f'<p><a id="next" href="/pb-warmup/{esc(name)}-next{q}">Next article</a></p>'
        f'<p><a href="/pb-warmup/logout{q}">Sign out</a></p>'
        f'<p><a href="http://partner.othersite.invalid/pb-warmup/partner{q}">Partner site</a></p>'
        f'<p><a href="/pb-warmup/file.zip{q}">Big file archive</a></p>'
        f'<p><a href="/pb-warmup/popup{q}" target="_blank">New window</a></p>'
    )
    # The links again every few paragraphs: some are in view wherever the page is scrolled to.
    filler = "".join((links if i % 5 == 4 else "") + f"<p>Paragraph {i} of the warm-up page {esc(name)}.</p>"
                     for i in range(120))
    # What the page world can see of a robot: window.webkit and globals named like one
    # ("undefined-" when nothing), reported at the first scroll and, through localStorage, by the
    # next page for the click that left this one.
    script = (
        "<script>(() => { const run = " + json.dumps(run) + ", name = " + json.dumps(name) + "; const seen = {};"
        " const report = (what) => { if (seen[what]) return; seen[what] = true;"
        " fetch('/pb-warmup/event/' + encodeURIComponent(run) + '/' + encodeURIComponent(name) + '-' + what); };"
        " const probe = () => typeof window.webkit + '-' + Object.getOwnPropertyNames(window).filter((n) => /warm|robot/i.test(n)).join('_');"
        " try { const last = localStorage.getItem('pbwarm-click'); if (last) { localStorage.removeItem('pbwarm-click'); report('clickglobals-' + last); } } catch (e) {}"
        " addEventListener('scroll', (e) => { report(e.isTrusted ? 'scroll' : 'scroll-untrusted'); report('globals-' + probe()); }, {passive: true});"
        " addEventListener('wheel', (e) => report(e.isTrusted ? 'wheel' : 'wheel-untrusted'), {passive: true});"
        " document.addEventListener('click', (e) => { report(e.isTrusted ? 'click' : 'click-untrusted');"
        " try { localStorage.setItem('pbwarm-click', name + '-' + probe()); } catch (e) {} }, true);"
        " addEventListener('hashchange', () => { if (location.hash && !location.hash.startsWith('#/'))"
        " history.replaceState(history.state, '', '#/' + location.hash.slice(1)); });"
        + (" setTimeout(() => alert('PB warm-up'), 300);" if name == "alert" else "")
        + " })();</script>"
    )
    return (f'<!doctype html><html><head><meta charset="utf-8"><title>PB warm-up {esc(name)}</title></head>'
            f'<body style="font: 15px -apple-system; margin: 20px">{links}{filler}{script}</body></html>').encode()


def leak_page(run: str) -> bytes:
    """The leak page for `run` (see the module docstring)."""
    page = r"""<!doctype html><html><head><title>PB leak page RUN</title>
<link rel="dns-prefetch" href="//prefetch-RUN.leak.example.com">
<link rel="preconnect" href="http://preconnect-RUN.leak.example.com">
<link rel="search" type="application/opensearchdescription+xml" title="PB" href="https://osd-RUN.leak.example.com/pb-leak/osd.xml?run=RUN">
<link rel="apple-touch-icon" href="https://touchicon-RUN.leak.example.com/pb-leak/touch.png?run=RUN">
<link rel="icon" href="https://icon-RUN.leak.example.com/pb-leak/icon.png?run=RUN">
<style>@font-face{font-family:pbleak;src:url(http://font-RUN.leak.example.com/pb-leak/font.woff?run=RUN)} body{font-family:pbleak,serif}</style>
</head><body>
<p>PB-LEAK-PAGE RUN</p>
<a id="ping" href="#pinged" ping="http://ping-RUN.leak.example.com/pb-leak/ping?run=RUN">ping</a>
<img src="http://img-RUN.leak.example.com/pb-leak/img.png?run=RUN" width="1" height="1">
<iframe src="http://frame-RUN.leak.example.com/pb-leak/frame?run=RUN" width="200" height="40"></iframe>
<iframe src="http://127.0.0.1:CANARY/pb-leak/lo4frame?run=RUN" width="20" height="20"></iframe>
<video src="http://media-RUN.leak.example.com/pb-leak/media.mp4?run=RUN" preload="auto" muted width="1" height="1"></video>
<a id="anchor" href="http://anchor-RUN.leak.example.com/pb-leak/anchor?run=RUN">a link, which a browser may prefetch the name of</a>
<img src="https://aia-RUN.leak.example.com/pb-leak/aia.png?run=RUN" width="1" height="1">
<script>
(async () => {
  const run = 'RUN';
  const result = { run, rtc: typeof RTCPeerConnection, webTransport: typeof WebTransport, candidates: [], errors: {} };
  const timeout = (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms));
  const attempt = async (name, body) => {
    try { result[name] = await Promise.race([body(), timeout(4000, 'timeout')]); }
    catch (e) { result[name] = 'rejected'; result.errors[name] = String((e && e.message) || e); }
  };
  try {
    const blank = document.createElement('iframe');
    document.body.appendChild(blank);
    result.rtcBlankFrame = typeof blank.contentWindow.RTCPeerConnection;
  } catch (e) { result.rtcBlankFrame = 'error'; }
  document.getElementById('ping').click();
  // A dns-prefetch added after the page loaded, as a script would.
  setTimeout(() => document.head.insertAdjacentHTML('beforeend', '<link rel="dns-prefetch" href="//late-RUN.leak.example.com">'), 1500);
  try { result.beacon = navigator.sendBeacon('http://beacon-RUN.leak.example.com/pb-leak/beacon?run=RUN', 'x'); } catch (e) { result.beacon = 'error'; }
  const noCors = (url) => async () => { await fetch(url, { mode: 'no-cors', cache: 'no-store' }); return 'resolved'; };
  await attempt('fetch4', noCors('http://192.0.2.10:8080/pb-leak/fetch4?run=RUN'));
  await attempt('fetch6', noCors('http://[2001:db8::10]:8080/pb-leak/fetch6?run=RUN'));
  await attempt('fetchName', noCors('http://fetch-RUN.leak.example.com/pb-leak/fetchname?run=RUN'));
  await attempt('fetchTLS', noCors('https://192.0.2.14/pb-leak/tls?run=RUN'));
  await attempt('fetchTLSName', noCors('https://tls-RUN.leak.example.com/pb-leak/tlsname?run=RUN'));
  // This Mac: the system never sends loopback through a proxy, so a proxied profile refuses it
  // (anything that reaches the canary listener went around the proxy). The local network: through
  // the proxy like anything else, or the capture sees it.
  await attempt('loopback4', noCors('http://127.0.0.1:CANARY/pb-leak/lo4?run=RUN'));
  await attempt('loopbackName', noCors('http://localhost:CANARY/pb-leak/lohost?run=RUN'));
  await attempt('loopback6', noCors('http://[::1]:CANARY/pb-leak/lo6?run=RUN'));
  await attempt('loopbackAny', noCors('http://0.0.0.0:CANARY/pb-leak/lo0?run=RUN'));
  await attempt('loopbackWorker', () => new Promise((resolve) => {
    const source = "fetch('http://127.0.0.1:CANARY/pb-leak/lo4w?run=RUN',{mode:'no-cors'}).then(()=>postMessage('resolved'),()=>postMessage('rejected'))";
    const worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
    worker.onmessage = (e) => resolve(e.data);
  }));
  await attempt('lan', noCors('http://lan-RUN.local/pb-leak/lan?run=RUN'));
  await attempt('lan10', noCors('http://10.255.255.1:8080/pb-leak/lan10?run=RUN'));
  await attempt('ws', () => new Promise((resolve) => {
    const ws = new WebSocket('ws://192.0.2.11:8080/pb-leak/ws?run=RUN');
    ws.onopen = () => resolve('open'); ws.onerror = () => resolve('error');
  }));
  await attempt('worker', () => new Promise((resolve) => {
    const source = "fetch('http://192.0.2.15:8080/pb-leak/worker?run=RUN',{mode:'no-cors'}).then(()=>postMessage('resolved'),()=>postMessage('rejected'))";
    const worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
    worker.onmessage = (e) => resolve(e.data);
  }));
  if (typeof RTCPeerConnection === 'function') {
    await attempt('rtcGather', async () => {
      const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:192.0.2.12:3478' }] });
      pc.onicecandidate = (e) => { if (e.candidate && e.candidate.candidate) result.candidates.push((/ typ (\w+)/.exec(e.candidate.candidate) || [])[1]); };
      pc.createDataChannel('leak');
      await pc.setLocalDescription(await pc.createOffer());
      await timeout(3000);
      pc.close();
      return 'gathered';
    });
  }
  if (typeof WebTransport === 'function') {
    await attempt('webTransportConnect', async () => {
      const transport = new WebTransport('https://192.0.2.13:4433/pb-leak/wt?run=RUN');
      const state = await Promise.race([transport.ready.then(() => 'ready', () => 'rejected'), timeout(3500, 'timeout')]);
      try { transport.close(); } catch (e) {}
      return state;
    });
  }
  await timeout(800);
  await fetch('/pb-leak/report?run=RUN&data=' + encodeURIComponent(JSON.stringify(result)), { cache: 'no-store' });
})();
</script></body></html>"""
    return page.replace("RUN", run).replace("CANARY", str(CANARY_PORT)).encode()


def leak_secure_page(run: str) -> bytes:
    """The leak page's secure-context half (see the module docstring)."""
    page = r"""<!doctype html><html><head><title>PB secure leak page RUN</title></head><body>secure RUN<script>
(async () => {
  const run = 'RUN';
  const timeout = (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms));
  const zone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
  const result = { secure: isSecureContext, run, webTransport: typeof WebTransport, rtc: typeof RTCPeerConnection, tz: zone() };
  const fromWorker = (make) => Promise.race([new Promise((resolve) => make(resolve)), timeout(3000, 'timeout')]);
  const source = (body) => URL.createObjectURL(new Blob([body], { type: 'text/javascript' }));
  try {
    result.worker = await fromWorker((resolve) => {
      const worker = new Worker(source('postMessage(typeof WebTransport)'));
      worker.onmessage = (e) => resolve(e.data);
    });
  } catch (e) { result.worker = 'error ' + e; }
  try {
    result.shared = await fromWorker((resolve) => {
      const shared = new SharedWorker(source('onconnect = (e) => e.ports[0].postMessage(typeof WebTransport)'));
      shared.port.onmessage = (e) => resolve(e.data);
      shared.port.start();
    });
  } catch (e) { result.shared = 'error ' + e; }
  try {
    // A worker loaded from a URL: no script of the page's reaches it.
    result.workerTZ = await fromWorker((resolve) => {
      const worker = new Worker('/pb-leak/tzworker.js?run=RUN');
      worker.onmessage = (e) => resolve(e.data);
    });
  } catch (e) { result.workerTZ = 'error ' + e; }
  try {
    await navigator.serviceWorker.register('/pb-leak/sw.js?run=RUN');
    result.sw = 'registered';
  } catch (e) { result.sw = 'error ' + e; }
  if ([result.webTransport, result.worker, result.shared].includes('function')) {
    try {
      const transport = new WebTransport('https://192.0.2.13:4433/pb-leak/wt?run=RUN');
      result.webTransportConnect = await Promise.race([transport.ready.then(() => 'ready', () => 'rejected'), timeout(3500, 'timeout')]);
    } catch (e) { result.webTransportConnect = 'threw'; }
  }
  await fetch('/pb-leak/report?run=RUN&data=' + encodeURIComponent(JSON.stringify(result)), { cache: 'no-store' });
})();
</script></body></html>"""
    return page.replace("RUN", run).encode()


def leak_service_worker(run: str) -> bytes:
    """The service worker of the secure page: what a service worker can reach."""
    script = r"""self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const report = { sw: true, webTransport: typeof WebTransport, tz: Intl.DateTimeFormat().resolvedOptions().timeZone };
    if (typeof WebTransport === 'function') {
      try {
        const transport = new WebTransport('https://192.0.2.13:4433/pb-leak/swwt?run=RUN');
        report.webTransportConnect = await Promise.race([transport.ready.then(() => 'ready', () => 'rejected'),
          new Promise((resolve) => setTimeout(() => resolve('timeout'), 3500))]);
      } catch (e) { report.webTransportConnect = 'threw'; }
    }
    await fetch('/pb-leak/report?run=RUN&data=' + encodeURIComponent(JSON.stringify(report)));
  })());
});
"""
    return script.replace("RUN", run).encode()


def leak_frame(run: str) -> bytes:
    """The frame of the leak page: what a frame of another site can see."""
    page = r"""<!doctype html><html><head><title>PB leak frame</title></head><body>frame RUN<script>
fetch('/pb-leak/report?run=RUN&frame=1&data=' + encodeURIComponent(JSON.stringify({ frame: true, rtc: typeof RTCPeerConnection, webTransport: typeof WebTransport })), { cache: 'no-store' });
</script></body></html>"""
    return page.replace("RUN", run).encode()


def safe_run(query: str) -> str:
    run = parse_qs(query).get("run", [""])[0]
    return "".join(c for c in run.lower() if c.isalnum())[:32]


def login_page(params: dict) -> bytes:
    """The sign-in form of the password AutoFill checks; page-world listeners log the events
    the fields receive (`pbEvents`)."""
    autofocus = " autofocus" if params.get("autofocus") else ""
    new = "new-password" if params.get("signup") else "current-password"
    fields = (
        f'<input id="user" name="login" type="text" autocomplete="username"{autofocus}>'
        f'<input id="pass" name="password" type="password" autocomplete="{new}">'
        + ('<input id="confirm" name="confirm" type="password" autocomplete="new-password">' if params.get("signup") else "")
    )
    if params.get("spa"):
        body = (f'<div id="box">{fields}<button id="go" type="button">Sign in</button></div>'
                "<script>document.getElementById('go').addEventListener('click', () =>"
                " setTimeout(() => document.getElementById('box').remove(), 300));</script>")
    else:
        body = f'<form id="f" action="/pb-welcome" method="post">{fields}<button id="go" type="submit">Sign in</button></form>'
    script = ("<script>window.pbEvents = []; for (const id of ['user', 'pass']) for (const type of ['input', 'change'])"
              " { const el = document.getElementById(id); if (el) el.addEventListener(type, () => pbEvents.push(id + ':' + type)); }</script>")
    return f'<!doctype html><html><head><meta charset="utf-8"><title>PB login</title></head><body>{body}{script}</body></html>'.encode()


def answer(conn: socket.socket, via: str, path: str, request: str) -> None:
    """Answers the (tunnelled or forwarded) HTTP request `request` for `path`."""
    accept_language = next((line.split(":", 1)[1].strip() for line in request.split("\r\n")[1:]
                            if line.lower().startswith("accept-language:")), "-")
    plain_path, _, query = path.partition("?")
    extra_headers = ""
    target = next((part[len("target="):] for part in via.split() if part.startswith("target=")), "")
    with SERVED_LOCK:
        if plain_path != "/pb-served.json":
            SERVED.append(plain_path)
        if not plain_path.startswith("/pb-leak/log.json"):
            TARGETS.append({"via": via.split()[0] if via else "", "target": target, "path": path,
                            "cookie": header(request, "Cookie"), "userAgent": header(request, "User-Agent"),
                            "language": accept_language})
        served = list(SERVED)
    if plain_path == "/pb-geo.json":
        params = {key: values[0] for key, values in parse_qs(query).items()}
        answer_json = json.loads(GEO_ANSWER)
        answer_json["ip"] = params.get("ip", answer_json["ip"])
        answer_json["timezone"] = params.get("tz", answer_json["timezone"])
        time.sleep(min(float(params.get("delay", "0")), 30))
        body, content_type = json.dumps(answer_json).encode(), "application/json"
    elif plain_path == "/pb-served.json":
        body, content_type = json.dumps(served).encode(), "application/json"
    elif plain_path == "/pb-leak":
        run = safe_run(query)
        body, content_type = leak_page(run), "text/html; charset=utf-8"
        # The same prefetch as a header, which WebKit also acts on; and prefetching of every link's
        # name asked for, as a site may.
        extra_headers = (f"Link: <//header-{run}.leak.example.com>; rel=dns-prefetch\r\n"
                         "X-DNS-Prefetch-Control: on\r\n")
    elif plain_path == "/pb-leak/secure":
        body, content_type = leak_secure_page(safe_run(query)), "text/html; charset=utf-8"
    elif plain_path == "/pb-leak/sw.js":
        body, content_type = leak_service_worker(safe_run(query)), "text/javascript"
    elif plain_path == "/pb-leak/tzworker.js":
        body, content_type = b"postMessage(Intl.DateTimeFormat().resolvedOptions().timeZone)", "text/javascript"
    elif plain_path == "/pb-leak/frame":
        body, content_type = leak_frame(safe_run(query)), "text/html; charset=utf-8"
    elif plain_path == "/pb-leak/report":
        params = parse_qs(query)
        run = safe_run(query)
        try:
            report = json.loads(params.get("data", ["{}"])[0])
        except ValueError:
            report = {"unreadable": params.get("data", [""])[0][:200]}
        with SERVED_LOCK:
            LEAK_REPORTS.setdefault(run, []).append(report)
        body, content_type = b"reported", "text/plain"
    elif plain_path == "/pb-leak/log.json":
        run = safe_run(query)
        with SERVED_LOCK:
            # This run's requests, and every request for an address in the documentation ranges
            # (only the leak page asks for those; a TLS request's path is its encrypted bytes).
            entries = [entry for entry in TARGETS if run and (run in entry["path"].lower() or run in entry["target"].lower()
                                                              or entry["target"].startswith(("192.0.2.", "[2001:db8:", "2001:db8:")))]
            canary = [entry for entry in CANARY if run and run in entry["request"].lower()]
            body = json.dumps({"targets": entries, "reports": LEAK_REPORTS.get(run, []), "canary": canary,
                               "canaryTotal": len(CANARY)}).encode()
        content_type = "application/json"
    elif plain_path == "/pb-cookies":
        cookie = next((line.split(":", 1)[1].strip() for line in request.split("\r\n")[1:]
                       if line.lower().startswith("cookie:")), "")
        body = (f"<!doctype html><html><head><title>PB cookies</title></head>"
                f"<body>PB-COOKIES cookie={html.escape(cookie)}</body></html>").encode()
        content_type = "text/html; charset=utf-8"
    elif plain_path == "/pb-login":
        body, content_type = login_page({key: values[0] for key, values in parse_qs(query).items()}), "text/html; charset=utf-8"
    elif plain_path == "/pb-warmup/log.json":
        with SERVED_LOCK:
            body, content_type = json.dumps(WARMUP_LOG).encode(), "application/json"
    elif plain_path.startswith("/pb-warmup/"):
        with SERVED_LOCK:
            WARMUP_LOG.append({"path": plain_path, "query": query, "referer": header(request, "Referer"),
                               "cookie": header(request, "Cookie"), "userAgent": header(request, "User-Agent"),
                               "time": time.time()})
        name = plain_path[len("/pb-warmup/"):]
        run = parse_qs(query).get("run", [""])[0]
        if name == "broken":
            # Closed without an answer: the page does not load.
            print(f"[selftest-proxy] closed unanswered {via} path={path}", flush=True)
            return
        if name.startswith("event/"):
            body, content_type = b"ok", "text/plain"
        else:
            cookie_name = "".join(c if c.isalnum() else "_" for c in name)
            extra_headers = f"Set-Cookie: pbwarm_{cookie_name}={run or 'x'}; Max-Age=86400; Path=/\r\n"
            body, content_type = warmup_page(name, run), "text/html; charset=utf-8"
    elif plain_path == "/pb-frame":
        src = parse_qs(query).get("src", ["about:blank"])[0].replace('"', "%22")
        body = (f'<!doctype html><html><head><title>PB frame</title></head><body>'
                f'<iframe id="frame" src="{src}" width="480" height="220" style="border:0"></iframe></body></html>').encode()
        content_type = "text/html; charset=utf-8"
    else:
        body = (
            f"<html><head><title>PB proxied {path}</title></head>"
            f"<body>PB-PROXY-OK {via} path={path} accept-language={accept_language}</body></html>"
        ).encode()
        content_type = "text/html; charset=utf-8"
    conn.sendall(
        f"HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\n{extra_headers}".encode()
        + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
        + body
    )
    print(f"[selftest-proxy] served {via} path={path} accept-language={accept_language}", flush=True)


# The hosts whose tunnels are answered with TLS: the leak page's certificate checks and the
# process's own HTTPS probes. Any other tunnel a client starts TLS in (Safari tries HTTPS first for
# an http address; the page's icons are https) is noted — the CONNECT is the proof of where it
# went — and closed at once, as by a server with no HTTPS, and the client goes on with http where
# it can — which the leak page's own requests do.
TLS_HOSTS = ("aia-", "tls-", "probe-", "192.0.2.14:")


def is_tls_host(via: str) -> bool:
    target = next((part[len("target="):] for part in via.split() if part.startswith("target=")), "")
    return target.lower().startswith(TLS_HOSTS)


def note(via: str, path: str) -> None:
    """A request this proxy saw but did not answer with a page (a TLS handshake, say)."""
    target = next((part[len("target="):] for part in via.split() if part.startswith("target=")), "")
    with SERVED_LOCK:
        TARGETS.append({"via": via.split()[0] if via else "", "target": target, "path": path, "cookie": ""})


def respond_with_page(conn: socket.socket, via: str) -> None:
    # A client that starts a TLS handshake in the tunnel gets the canary certificate (see the
    # module docstring); one that refuses it ends the handshake there.
    try:
        first = conn.recv(1, socket.MSG_PEEK)
    except OSError:
        first = b""
    if first == b"\x16" and "canary" in TLS and is_tls_host(via):
        note(via, "(tls handshake)")
        try:
            conn = TLS["canary"].wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError) as error:
            note(via, f"(tls refused by the client: {str(error)[:120]})")
            print(f"[selftest-proxy] TLS refused {via}: {error}", flush=True)
            return
        via = via + " tls=1"
        note(via, "(tls accepted by the client)")
        try:
            serve_request(conn, via)
        finally:
            conn.close()
        return
    if first == b"\x16":
        # Waiting for a request that never comes (the client waits for the server's hello) would
        # hold the client until its own timeout.
        note(via, "(tls, no https here)")
        return
    serve_request(conn, via)


def serve_request(conn: socket.socket, via: str) -> None:
    request = read_until_blank_line(conn).decode("latin-1", "replace")
    request_line = request.split("\r\n", 1)[0]
    parts = request_line.split(" ")
    path = parts[1] if len(parts) > 1 else "?"
    answer(conn, via, path, request)


def handle_http(conn: socket.socket, via: str = "connect") -> None:
    with conn:
        head = read_until_blank_line(conn).decode("latin-1", "replace")
        first = head.split("\r\n", 1)[0]
        method, _, rest = first.partition(" ")
        target = rest.split(" ", 1)[0]
        if method.upper() == "CONNECT":
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            respond_with_page(conn, f"via={via} target={target}")
        else:
            # Absolute-form request (plain forward proxy); answer directly.
            path = "/" + target.split("://", 1)[-1].split("/", 1)[-1] if "/" in target.split("://", 1)[-1] else "/"
            answer(conn, f"via=forward target={target}", path, head)


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


def handle_http6(conn: socket.socket) -> None:
    handle_http(conn, via="connect6")


def recv_exact(conn: socket.socket, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise ConnectionError("short read")
        data += chunk
    return data


SOCKS_AUTH = (b"pb-user2", b"pb-pass2")


def handle_socks(conn: socket.socket, listener: int = 0, auth: bool = False) -> None:
    with conn:
        version, nmethods = recv_exact(conn, 2)
        methods = recv_exact(conn, nmethods)
        if version != 5:
            return
        if auth:
            # Username/password only (RFC 1929): a client without credentials gets "no acceptable method".
            if 2 not in methods:
                conn.sendall(b"\x05\xff")
                print(f"[selftest-proxy] socks-auth :{listener}: no credentials offered", flush=True)
                return
            conn.sendall(b"\x05\x02")
            _, ulen = recv_exact(conn, 2)
            user = recv_exact(conn, ulen)
            plen = recv_exact(conn, 1)[0]
            password = recv_exact(conn, plen)
            if (user, password) != SOCKS_AUTH:
                conn.sendall(b"\x01\x01")
                print(f"[selftest-proxy] socks-auth :{listener}: wrong credentials", flush=True)
                return
            conn.sendall(b"\x01\x00")
        else:
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
        via = "socks5-auth" if auth else "socks5"
        respond_with_page(conn, f"via={via} atyp={atyp} target={host}:{port} listener={listener}")


def handle_tls_control(conn: socket.socket) -> None:
    """The control of the TLS check (see the module docstring): no proxy, a certificate whose chain
    needs a fetch, naming `pbaiacontrol`."""
    with conn:
        if "control" not in TLS:
            return
        note("via=tls-control target=127.0.0.1", "(tls handshake)")
        try:
            tls = TLS["control"].wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError) as error:
            note("via=tls-control target=127.0.0.1", f"(tls refused by the client: {str(error)[:120]})")
            return
        with tls:
            serve_request(tls, "via=tls-control target=127.0.0.1")


def handle_canary(conn: socket.socket, listener: str = "") -> None:
    """Notes a connection that reached loopback directly (see the module docstring)."""
    with conn:
        conn.settimeout(3)
        try:
            head = read_until_blank_line(conn).decode("latin-1", "replace")
        except OSError:
            head = ""
        with SERVED_LOCK:
            CANARY.append({"listener": listener, "request": head.split("\r\n", 1)[0][:200], "time": time.time()})
        print(f"[selftest-proxy] CANARY: a direct connection on {listener}: {head[:120]!r}", flush=True)
        try:
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nno")
        except OSError:
            pass


def handler_name(handler) -> str:
    return getattr(handler, "__name__", None) or handler.func.__name__  # a functools.partial


def serve(port: int, handler, host: str = "127.0.0.1") -> None:
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    try:
        server = socket.socket(family, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, port))
        server.listen(16)
    except OSError as exc:  # e.g. no IPv6 on this host: the other listeners keep serving
        print(f"[selftest-proxy] {handler_name(handler)} cannot listen on {host}:{port}: {exc}", flush=True)
        return
    print(f"[selftest-proxy] {handler_name(handler)} listening on {host}:{port}", flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=lambda c=conn: _safe(handler, c), daemon=True).start()


def _safe(handler, conn) -> None:
    try:
        handler(conn)
    except Exception as exc:  # noqa: BLE001 - test helper, keep serving
        print(f"[selftest-proxy] {handler_name(handler)} error: {exc}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--http", type=int, default=18080)
    parser.add_argument("--socks", type=int, default=18081)
    parser.add_argument("--http-auth", type=int, default=None)
    parser.add_argument("--http6", type=int, default=None)
    parser.add_argument("--socks2", type=int, default=None)
    parser.add_argument("--socks-auth", type=int, default=None)
    parser.add_argument("--tls-control", type=int, default=None)
    parser.add_argument("--canary", type=int, default=None)
    args = parser.parse_args()
    make_certificates()
    if args.tls_control:
        threading.Thread(target=serve, args=(args.tls_control, handle_tls_control), daemon=True).start()
    if args.canary:
        global CANARY_PORT
        CANARY_PORT = args.canary
        for host in ("127.0.0.1", "::1"):
            threading.Thread(target=serve, args=(args.canary, functools.partial(handle_canary, listener=f"{host}:{args.canary}"), host),
                             daemon=True).start()
    threading.Thread(target=serve, args=(args.http, handle_http), daemon=True).start()
    if args.http_auth:
        threading.Thread(target=serve, args=(args.http_auth, handle_http_auth), daemon=True).start()
    if args.http6:
        threading.Thread(target=serve, args=(args.http6, handle_http6, "::1"), daemon=True).start()
    if args.socks2:
        threading.Thread(target=serve, args=(args.socks2, functools.partial(handle_socks, listener=args.socks2)),
                         daemon=True).start()
    if args.socks_auth:
        threading.Thread(target=serve, args=(args.socks_auth, functools.partial(handle_socks, listener=args.socks_auth, auth=True)),
                         daemon=True).start()
    serve(args.socks, functools.partial(handle_socks, listener=args.socks))


if __name__ == "__main__":
    main()
