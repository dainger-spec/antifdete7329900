#!/usr/bin/env python3
"""Pages for the iOS Simulator measurement (scripts/ios_sim_stage1.sh) and for a real iPhone
(scripts/iphone_probe.py): the fingerprint probe and the isolation pages. Every result a page
sends back is written as JSON into the reports folder. Standard library only.

    python3 scripts/sim_pages.py --port 28090 --reports DIR [--host 127.0.0.1]

Pages:
  /probe?name=N         runs Resources/fingerprint_probe.js (the probe the self-test and the
                        comparison with the Mac's Safari run) and sends its result as N.json
  /iso/set?dev=D        sets, for this origin, a cookie (by script and by the server), a localStorage
                        item and an IndexedDB record, each carrying D, then reports iso-set-D.json
  /iso/get?dev=D        reports what this origin holds in the same three places, and the Cookie
                        header the request came with, as iso-get-D.json
  /plain?tag=T          a page and nothing else (for loading times and history)
  /report?name=N        (POST) where the pages send their results
Every request is noted, with its Cookie header, in requests.jsonl.
"""
import argparse
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = open(os.path.join(HERE, "..", "Resources", "fingerprint_probe.js"), encoding="utf-8").read()
SAFE = re.compile(r"[^A-Za-z0-9_.-]")
LOCK = threading.Lock()


def page(title, script, body=""):
    return ("<!doctype html><html><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<title>{title}</title>"
            "<style>body{font:15px -apple-system,sans-serif;margin:16px}pre{white-space:pre-wrap;font-size:11px}"
            "button{font-size:17px;padding:10px 16px;margin:8px 0}</style></head><body>"
            f"{body}<script>{script}</script></body></html>").encode()


SEND = """
function send(name, data) {
  return fetch('/report?name=' + encodeURIComponent(name), {method: 'POST', body: JSON.stringify(data)})
    .then(() => { document.title = 'SENT ' + name; const s = document.getElementById('state'); if (s) s.textContent = 'Sent.'; })
    .catch((e) => { document.title = 'NOT SENT'; const s = document.getElementById('state'); if (s) s.textContent = 'Not sent: ' + e; });
}
"""

PROBE_PAGE = SEND + """
const params = new URLSearchParams(location.search);
const name = params.get('name') || 'probe';
let result;
try { result = (function () { %s })(); } catch (e) { result = {probeError: String(e)}; }
result._page = {devicePixelRatio: window.devicePixelRatio, screen: screen.width + 'x' + screen.height,
                inner: innerWidth + 'x' + innerHeight, time: new Date().toISOString(),
                secureContext: String(window.isSecureContext), origin: location.origin};
// What a worker sees of the processor count (a page's override would not reach it).
function workerConcurrency() {
  return new Promise((resolve) => {
    try {
      const w = new Worker(URL.createObjectURL(new Blob(['postMessage(String(navigator.hardwareConcurrency))'], {type: 'text/javascript'})));
      w.onmessage = (e) => resolve(e.data); w.onerror = () => resolve('error');
      setTimeout(() => resolve('timeout'), 3000);
    } catch (e) { resolve('error: ' + e); }
  });
}
document.getElementById('out').textContent = JSON.stringify(result, null, 1);
document.getElementById('share').onclick = () => {
  const text = JSON.stringify(result);
  if (navigator.share) navigator.share({title: 'Lumen probe', text: text}).catch(() => {});
  else navigator.clipboard.writeText(text);
};
workerConcurrency().then((value) => { result._page.workerHardwareConcurrency = value; send(name, result); });
""" % PROBE

ISO_SET = SEND + """
const dev = new URLSearchParams(location.search).get('dev') || '?';
document.cookie = 'pbiso_js=' + dev + '; max-age=86400; path=/';
localStorage.setItem('pbiso', dev);
const open = indexedDB.open('pbiso', 1);
open.onupgradeneeded = () => open.result.createObjectStore('kv');
open.onsuccess = () => {
  const tx = open.result.transaction('kv', 'readwrite');
  tx.objectStore('kv').put(dev, 'dev');
  tx.oncomplete = () => send('iso-set-' + dev, {dev: dev, cookie: document.cookie, localStorage: localStorage.getItem('pbiso')});
};
open.onerror = () => send('iso-set-' + dev, {dev: dev, idbError: String(open.error)});
"""

ISO_GET = SEND + """
const dev = new URLSearchParams(location.search).get('dev') || '?';
const out = {dev: dev, cookie: document.cookie, localStorage: localStorage.getItem('pbiso')};
const open = indexedDB.open('pbiso', 1);
open.onupgradeneeded = () => open.result.createObjectStore('kv');
open.onsuccess = () => {
  try {
    const req = open.result.transaction('kv').objectStore('kv').get('dev');
    req.onsuccess = () => { out.indexedDB = req.result === undefined ? null : req.result; send('iso-get-' + dev, out); };
    req.onerror = () => { out.indexedDB = 'error'; send('iso-get-' + dev, out); };
  } catch (e) { out.indexedDB = 'error: ' + e; send('iso-get-' + dev, out); }
};
open.onerror = () => { out.indexedDB = 'open error'; send('iso-get-' + dev, out); };
"""


class Handler(BaseHTTPRequestHandler):
    reports = "."

    def log_message(self, *args):
        pass

    def note(self):
        with LOCK, open(os.path.join(self.reports, "requests.jsonl"), "a") as log:
            log.write(json.dumps({"time": time.time(), "method": self.command, "path": self.path,
                                  "cookie": self.headers.get("Cookie", ""),
                                  "ua": self.headers.get("User-Agent", ""),
                                  "accept-language": self.headers.get("Accept-Language", "")}) + "\n")

    def reply(self, body, kind="text/html; charset=utf-8", extra=()):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in extra:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.note()
        url = urlparse(self.path)
        query = parse_qs(url.query)
        dev = SAFE.sub("", (query.get("dev") or ["?"])[0])[:20]
        if url.path == "/probe":
            body = ("<h3>Lumen probe</h3><p id=state>Sending…</p>"
                    "<button id=share>Share the result</button><pre id=out></pre>")
            self.reply(page("Lumen probe", PROBE_PAGE, body))
        elif url.path == "/iso/set":
            self.reply(page("iso set " + dev, ISO_SET, "<p id=state>setting " + dev),
                       extra=[("Set-Cookie", f"pbiso_srv={dev}; Max-Age=86400; Path=/")])
        elif url.path == "/iso/get":
            self.reply(page("iso get " + dev, ISO_GET, "<p id=state>reading"))
        elif url.path == "/hold":
            # A page whose connection stays open for 25 s, so that the process holding its other end
            # can be found (Content-Length promises more than is sent, then the rest comes).
            body = b"<!doctype html><title>hold</title><p>held" + b" " * 64
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body[:20])
            self.wfile.flush()
            time.sleep(25)
            try:
                self.wfile.write(body[20:])
            except OSError:
                pass
        elif url.path == "/anim":
            script = SEND + """
let frames = 0; const box = document.getElementById('box'); const start = performance.now();
function step(t) { frames++; box.style.transform = 'rotate(' + (t / 5) + 'deg)'; if (t - start < 4000) requestAnimationFrame(step); else send('anim', {frames: frames, seconds: (t - start) / 1000}); }
requestAnimationFrame(step);"""
            self.reply(page("anim", script, "<div id=box style='width:300px;height:300px;margin:80px auto;background:linear-gradient(red,blue)'></div>"))
        elif url.path == "/tap":
            script = SEND + """
const seen = [];
for (const type of ['touchstart', 'touchend', 'pointerdown', 'pointerup', 'mousedown', 'click']) {
  document.addEventListener(type, (e) => {
    seen.push({type: e.type, trusted: e.isTrusted, pointerType: e.pointerType || null,
               x: Math.round((e.touches && e.touches[0] ? e.touches[0].clientX : e.clientX) || 0),
               y: Math.round((e.touches && e.touches[0] ? e.touches[0].clientY : e.clientY) || 0)});
    if (e.type === 'click') send('tap', {events: seen});
  }, {passive: true});
}"""
            self.reply(page("tap", script, "<div style='position:fixed;inset:0;background:#eef;font-size:30px;padding:40px'>tap anywhere</div>"))
        elif url.path == "/plain":
            tag = SAFE.sub("", (query.get("tag") or ["plain"])[0])[:40]
            self.reply(page("plain " + tag, SEND + f"send('plain-{tag}', {{loaded: performance.now()}});", "<p>" + tag))
        else:
            self.reply(b"<!doctype html><title>pages</title><p>pages")

    def do_POST(self):
        self.note()
        url = urlparse(self.path)
        name = SAFE.sub("", (parse_qs(url.query).get("name") or ["report"])[0])[:60] or "report"
        length = min(int(self.headers.get("Content-Length") or 0), 4 << 20)
        data = self.rfile.read(length)
        with LOCK, open(os.path.join(self.reports, name + ".json"), "wb") as out:
            out.write(data)
        self.reply(b"ok", "text/plain")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--reports", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    arguments = parser.parse_args()
    os.makedirs(arguments.reports, exist_ok=True)
    Handler.reports = arguments.reports
    ThreadingHTTPServer((arguments.host, arguments.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
