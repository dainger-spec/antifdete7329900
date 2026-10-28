#!/usr/bin/env python3
"""How fast pages load in this Mac's Safari (safaridriver) and in a profile without a proxy, and
what each part of a profile costs. Measurement and report only: it changes nothing and never fails
the build.

    sudo safaridriver --enable            # once per machine (CI does it)
    python3 scripts/page_speed.py --app build/unsandboxed/PrivacyBrowser.app --out build/page-speed

Pages: heavy local pages served here (many scripts, Date/Intl in a loop, 24 iframes of two sites,
many fonts, many requests, blob workers) and a few real sites when the network reaches them. Each
page, in Safari and in each profile variant: `--runs` cold loads (empty cache; Safari: a new
WebDriver session, a profile: its website data cleared and a new tab), each followed by a warm load
of the same URL. Metrics: the wall-clock time until the browser has loaded the page, TTFB,
DOMContentLoaded, load, FCP, LCP (where the engine has it), the page's own script time, requests,
how many came from the cache, and the protocol (nextHopProtocol). Medians are compared.

The variants (PrivacyBrowser --page-speed, PageSpeed.swift) leave one part of a profile out, or
change one setting of its WebKit process pool or data store (MeasurementFactors.swift): the
difference to the baseline profile is that part's cost. Also reported: the profile's process pool,
data store and preferences next to a plain WKWebView's, Safari's WebKit preferences this Mac has,
and whether a persistent profile's HTTP cache survives a stop and a start (sealed and restored).

Output: <out>/report.md (also printed), <out>/report.json, <out>/safari.json, <out>/app/page-speed.json.
"""
import argparse
import http.server
import json
import os
import socket
import socketserver
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from safari_reference import WebDriver, free_port, wait_for_port  # noqa: E402

REAL_SITES = [
    ("wikipedia", "https://en.wikipedia.org/wiki/WebKit"),
    ("apple", "https://www.apple.com/"),
    ("github", "https://github.com/apple"),
    ("bbc", "https://www.bbc.com/news"),
    ("mdn", "https://developer.mozilla.org/en-US/docs/Web/JavaScript"),
]

# The page's own timing entries, run after the load in both browsers (an async function body).
METRICS = r"""
const round = (v) => (typeof v === 'number' ? Math.round(v * 10) / 10 : v === undefined ? null : v);
const nav = performance.getEntriesByType('navigation')[0] || {};
const paint = performance.getEntriesByType('paint');
const fcp = (paint.find((p) => p.name === 'first-contentful-paint') || {}).startTime;
const supported = (window.PerformanceObserver && PerformanceObserver.supportedEntryTypes) || [];
const observe = (type) => new Promise((resolve) => {
  if (!supported.includes(type)) { resolve('unsupported'); return; }
  const seen = [];
  try {
    const observer = new PerformanceObserver((list) => { seen.push(...list.getEntries()); });
    observer.observe({ type, buffered: true });
    setTimeout(() => { observer.disconnect(); resolve(seen); }, 150);
  } catch (e) { resolve('error: ' + e.name); }
});
const lcpEntries = await observe('largest-contentful-paint');
const longTasks = await observe('longtask');
const resources = performance.getEntriesByType('resource');
const protocols = {};
for (const r of [nav, ...resources]) { const p = r.nextHopProtocol || '?'; protocols[p] = (protocols[p] || 0) + 1; }
return {
  ttfb: round(nav.responseStart), dcl: round(nav.domContentLoadedEventEnd), load: round(nav.loadEventEnd),
  fcp: round(fcp),
  lcp: Array.isArray(lcpEntries) ? round(lcpEntries.length ? lcpEntries[lcpEntries.length - 1].startTime : null) : lcpEntries,
  longTaskMs: Array.isArray(longTasks) ? round(longTasks.reduce((sum, t) => sum + t.duration, 0)) : longTasks,
  scriptMs: window.__work ? round(window.__work.total) : null,
  work: window.__work || null,
  firstScriptMs: round(window.__t0),
  requests: resources.length + 1,
  cached: resources.filter((r) => r.transferSize === 0 && r.decodedBodySize > 0).length,
  transferKB: round(resources.reduce((sum, r) => sum + (r.transferSize || 0), nav.transferSize || 0) / 1024),
  protocol: nav.nextHopProtocol || null,
  protocols,
  entryTypes: supported.join(','),
};
"""

ASYNC_WRAPPER = """const __done = arguments[arguments.length - 1];
(async () => {
%s
})().then((v) => __done(JSON.stringify(v === undefined ? null : v)),
          (e) => __done(JSON.stringify({ error: String(e && e.message || e) })));"""

# ---- The local pages --------------------------------------------------------------------------

HEAD = """<!doctype html><html><head><meta charset="utf-8"><title>%s</title>
<script>window.__t0 = performance.now(); window.__work = { total: 0 };
window.__time = (name, fn) => { const t = performance.now(); const r = fn(); const d = performance.now() - t;
  window.__work[name] = Math.round(((window.__work[name] || 0) + d) * 10) / 10; window.__work.total += d; return r; };</script>
"""


def page_scripts():
    tags = "".join(f'<script src="/res/script{i}.js"></script>\n' for i in range(60))
    return (HEAD % "scripts") + "</head><body><h1>Scripts</h1><div id=out></div>" + tags + "</body></html>"


def script_resource(i):
    return f"""window.__time('scripts', () => {{
  const items = []; for (let k = 0; k < 4000; k++) items.push({{ k, v: Math.sqrt(k * {i + 1}) }});
  items.sort((a, b) => b.v - a.v); const p = document.createElement('p'); p.textContent = 'script {i}: ' + items[0].v.toFixed(2);
  document.getElementById('out').appendChild(p);
}});"""


def page_dateintl():
    return (HEAD % "date-intl") + """</head><body><h1>Date and Intl</h1><p id=out></p><script>
window.__time('dateIntl', () => {
  let acc = 0; const fmt = new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'long' });
  for (let i = 0; i < 30000; i++) {
    const d = new Date(1700000000000 + i * 3600000);
    acc += d.getTimezoneOffset() + d.getHours();
    if (i % 10 === 0) acc += fmt.format(d).length + d.toLocaleString().length + d.toString().length;
    if (i % 100 === 0) acc += new Intl.DateTimeFormat().resolvedOptions().timeZone.length;
  }
  document.getElementById('out').textContent = acc;
});
</script></body></html>"""


def page_iframes(other):
    frames = "".join(
        f'<iframe src="{"" if i % 2 else other}/res/frame.html?i={i}" width=160 height=90></iframe>\n' for i in range(24))
    return (HEAD % "iframes") + "</head><body><h1>24 iframes, two sites</h1>" + frames + """<script>
window.__time('frames', () => { for (const f of document.querySelectorAll('iframe')) { try { void f.contentWindow; } catch (e) {} } });
</script></body></html>"""


FRAME = """<!doctype html><html><head><meta charset="utf-8"></head><body style="font: 12px sans-serif">
<p id=p></p><script>let a = 0; for (let i = 0; i < 2000; i++) a += new Date(i * 1e7).getTimezoneOffset();
document.getElementById('p').textContent = location.host + ' ' + a; try { void parent.document; } catch (e) {}</script></body></html>"""

FONT_FAMILIES = ["Helvetica", "Helvetica Neue", "Times", "Georgia", "Courier", "Menlo", "Monaco", "Avenir", "Avenir Next",
                 "Futura", "Gill Sans", "Optima", "Palatino", "Baskerville", "Didot", "American Typewriter", "Arial",
                 "Verdana", "Tahoma", "Trebuchet MS", "Impact", "Comic Sans MS", "Hoefler Text", "Chalkboard",
                 "Marker Felt", "Noteworthy", "Papyrus", "Rockwell", "Copperplate", "Skia", "Zapfino", "Apple Chancery",
                 "Bradley Hand", "Snell Roundhand", "Kefa", "Superclarendon", "Phosphate", "Charter", "Seravek", "Athelas"]


def page_fonts():
    faces = "".join(f"@font-face {{ font-family: 'pb-local-{i}'; src: local('{name}'); }}\n"
                    for i, name in enumerate(FONT_FAMILIES))
    spans = "".join(f"<p style=\"font-family: 'pb-local-{i}', '{name}', serif\">{name}: The quick brown fox 0123456789</p>\n"
                    for i, name in enumerate(FONT_FAMILIES))
    return (HEAD % "fonts") + "<style>" + faces + "</style></head><body><h1>Fonts</h1>" + spans + """<script>
window.__time('fontLayout', () => { let w = 0; for (const p of document.querySelectorAll('p')) w += p.getBoundingClientRect().width; return w; });
</script></body></html>"""


def page_requests():
    images = "".join(f'<img src="/res/img{i}.png" width=8 height=8>' for i in range(200))
    return (HEAD % "requests") + "</head><body><h1>200 images, 50 fetches</h1>" + images + """<script>
window.__fetches = Promise.all(Array.from({ length: 50 }, (_, i) => fetch('/res/data' + i + '.json').then((r) => r.json())));
</script></body></html>"""


def page_workers():
    return (HEAD % "workers") + """</head><body><h1>Blob workers</h1><p id=out></p><script>
const code = "let a = 0; for (let i = 0; i < 200000; i++) a += Math.sqrt(i) + new Date(i).getTimezoneOffset(); postMessage(a);";
const started = performance.now();
let done = 0;
for (let i = 0; i < 8; i++) {
  const w = new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
  w.onmessage = () => { done++; if (done === 8) { window.__work.workers = Math.round(performance.now() - started); document.getElementById('out').textContent = 'done'; } };
}
</script></body></html>"""


PNG_1X1 = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                        "1f15c4890000000d4944415478da63f8cfc0f01f0005000201e2a3a1e40000000049454e44ae426082")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 256

    def server_bind(self):
        # Not HTTPServer's, which looks up socket.getfqdn() (a reverse DNS lookup, slow on macOS).
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


def make_handler(port):
    hits = {}
    lock = threading.Lock()
    other = f"http://localhost:{port}"
    pages = {"/heavy/scripts.html": page_scripts, "/heavy/dateintl.html": page_dateintl,
             "/heavy/iframes.html": lambda: page_iframes(other), "/heavy/fonts.html": page_fonts,
             "/heavy/requests.html": page_requests, "/heavy/workers.html": page_workers}

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        # Headers and body are two writes: without this, Nagle and delayed ACKs add ~40 ms a request.
        disable_nagle_algorithm = True

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            with lock:
                hits[path] = hits.get(path, 0) + 1
            cache = "public, max-age=3600"
            if path in pages:
                body, kind, cache = pages[path]().encode(), "text/html; charset=utf-8", "no-cache"
            elif path.startswith("/res/script") and path.endswith(".js"):
                body, kind = script_resource(int(path[len("/res/script"):-3])).encode(), "text/javascript"
            elif path == "/res/frame.html":
                body, kind = FRAME.encode(), "text/html; charset=utf-8"
            elif path.startswith("/res/img"):
                body, kind = PNG_1X1, "image/png"
            elif path.startswith("/res/data"):
                body, kind = json.dumps({"path": path, "items": list(range(50))}).encode(), "application/json"
            elif path == "/cache-probe.js":
                body, kind, cache = b"window.__probe = 1;", "text/javascript", "public, max-age=86400"
            elif path == "/cache-probe.html":
                body, kind, cache = b"<!doctype html><script src=/cache-probe.js></script>ok", "text/html", "no-cache"
            elif path == "/pb-hits":
                query = self.path.split("?", 1)[1] if "?" in self.path else ""
                wanted = dict(p.split("=", 1) for p in query.split("&") if "=" in p).get("path", "")
                with lock:
                    body, kind, cache = str(hits.get(wanted, 0)).encode(), "text/plain", "no-store"
            else:
                self.send_error(404)
                return
            etag = '"%x"' % (hash(body) & 0xFFFFFFFF)
            if self.headers.get("If-None-Match") == etag:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.send_header("Cache-Control", cache)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            self.send_header("ETag", etag)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    return Handler


def local_pages(base):
    return [{"name": name, "url": f"{base}/heavy/{name}.html", "local": True}
            for name in ["scripts", "dateintl", "iframes", "fonts", "requests", "workers"]]


def reachable(url):
    try:
        request = urllib.request.Request(url, method="GET", headers={"User-Agent": "Mozilla/5.0 page_speed.py"})
        with urllib.request.urlopen(request, timeout=8) as response:
            return response.status < 400
    except (urllib.error.URLError, OSError, ValueError):
        return False


# ---- Safari -----------------------------------------------------------------------------------

def safari_runs(pages, runs, settle_ms, window):
    port = free_port()
    driver_process = subprocess.Popen(["safaridriver", "-p", str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = {}
    try:
        if not wait_for_port(port, 20):
            print("PAGE-SPEED Safari: safaridriver did not listen")
            return {}
        for page in pages:
            cold, warm = [], []
            for run in range(runs):
                driver = WebDriver(f"http://127.0.0.1:{port}")
                try:
                    capabilities = driver.start()
                    results.setdefault("_safari", capabilities.get("browserVersion"))
                    driver.request("POST", f"/session/{driver.session}/timeouts", {"script": 60000, "pageLoad": 60000})
                    driver.request("POST", f"/session/{driver.session}/window/rect",
                                   {"x": 60, "y": 60, "width": window["width"], "height": window["height"]})
                    cold.append(safari_load(driver, page["url"], settle_ms))
                    warm.append(safari_load(driver, page["url"], settle_ms))
                except Exception as error:  # noqa: BLE001 - one page failing must not stop the others
                    cold.append({"error": str(error)})
                finally:
                    driver.quit()
                print(f"INFO [safari] {page['name']} run {run + 1}/{runs}", flush=True)
            results[page["name"]] = {"cold": cold, "warm": warm}
    finally:
        driver_process.terminate()
        try:
            driver_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            driver_process.kill()
    return results


def safari_load(driver, url, settle_ms):
    started = time.time()
    # Navigate returns when the page has loaded (the default page load strategy).
    driver.navigate(url)
    metrics = {"wallMs": int((time.time() - started) * 1000)}
    time.sleep(settle_ms / 1000)
    value = driver.request("POST", f"/session/{driver.session}/execute/async",
                           {"script": ASYNC_WRAPPER % METRICS, "args": []}, timeout=90)
    page = json.loads(value) if isinstance(value, str) else value
    if isinstance(page, dict):
        metrics.update({k: v for k, v in page.items() if k not in metrics})
    return metrics


# ---- The profile ------------------------------------------------------------------------------

def variants(local_names, all_names):
    """The baseline profile on every page; each factor on the local pages."""
    def factor(name, **settings):
        return dict(name=name, pages=local_names, **settings)
    return [
        dict(name="baseline", pages=all_names),
        factor("ephemeral", persistent=False),
        factor("no-shims", changes=["shims"]),
        factor("no-toString", changes=["toString"]),
        factor("no-frame-hooks", changes=["frameHooks"]),
        factor("no-worker-hooks", changes=["workerHooks"]),
        factor("no-autofill", changes=["autofill"]),
        factor("zone", timeZone="Asia/Tokyo"),
        factor("zone-no-tz-shim", timeZone="Asia/Tokyo", changes=["tzShim"]),
        factor("shared-pool", sharedPool=True),
        factor("pool-prewarm", pool={"prewarmsProcessesAutomatically": True}),
        factor("pool-process-cache", pool={"usesWebProcessCache": True}),
        factor("pool-prewarm-and-cache", pool={"prewarmsProcessesAutomatically": True, "usesWebProcessCache": True}),
        factor("pool-no-process-swap", pool={"processSwapsOnNavigation": False}),
        factor("store-speculative-validation", store={"networkCacheSpeculativeValidationEnabled": True}),
        factor("with-content-rules", changes=["contentRules"]),
        factor("user-fonts-shown", changes=["userFonts"]),
        dict(name="iphone", generation="ios-26", pages=["fonts", "scripts"]),
        dict(name="iphone-no-font-allowlist", generation="ios-26", changes=["fontAllowlist"], pages=["fonts", "scripts"]),
    ]


def run_app(app, spec, out):
    os.makedirs(out, exist_ok=True)
    spec_path = os.path.join(out, "spec.json")
    with open(spec_path, "w", encoding="utf-8") as handle:
        json.dump(spec, handle, indent=1)
    binary = os.path.join(app, "Contents", "MacOS", "PrivacyBrowser")
    process = subprocess.Popen([binary, "--page-speed", spec_path, out], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        if line.startswith(("INFO variant", "PAGE-SPEED", "INFO macOS")) or "failed" in line:
            print("  app| " + line, end="", flush=True)
    process.wait()
    try:
        with open(os.path.join(out, "page-speed.json"), encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


# ---- Report -----------------------------------------------------------------------------------

METRIC_KEYS = ["wallMs", "ttfb", "dcl", "load", "fcp", "lcp", "scriptMs", "longTaskMs", "requests", "cached", "transferKB"]


def median(runs, key):
    values = [r[key] for r in runs if isinstance(r, dict) and isinstance(r.get(key), (int, float))]
    return round(statistics.median(values), 1) if values else None


def protocol(runs):
    values = [r.get("protocol") for r in runs if isinstance(r, dict) and r.get("protocol")]
    return max(set(values), key=values.count) if values else None


def fmt(value):
    return "—" if value is None else (f"{value:g}" if isinstance(value, (int, float)) else str(value))


def report(safari, app, pages, local_names):
    lines, data = [], {"pages": {}, "factors": {}}
    measured = app.get("variants", {})
    baseline = measured.get("baseline", {}).get("pages", {})
    lines.append(f"# Page speed: Safari {safari.get('_safari')} vs a profile without a proxy\n")
    lines.append("Medians of the runs; cold = empty cache (Safari: a new session; profile: data cleared, new tab), "
                 "warm = the same URL again in that tab. ms unless noted.\n")
    for phase in ("cold", "warm"):
        lines.append(f"\n## {phase.capitalize()} loads\n")
        lines.append("| page | browser | " + " | ".join(METRIC_KEYS) + " | protocol |")
        lines.append("|" + "---|" * (len(METRIC_KEYS) + 3))
        for page in pages:
            name = page["name"]
            for label, source in (("Safari", safari.get(name)), ("profile", baseline.get(name))):
                runs = (source or {}).get(phase, [])
                row = [median(runs, key) for key in METRIC_KEYS]
                data["pages"].setdefault(name, {}).setdefault(phase, {})[label] = dict(zip(METRIC_KEYS, row), protocol=protocol(runs))
                errors = [r.get("error") for r in runs if isinstance(r, dict) and r.get("error")]
                lines.append(f"| {name} | {label} | " + " | ".join(fmt(v) for v in row) + f" | {fmt(protocol(runs))} |"
                             + (f" errors: {errors[0][:80]}" if errors else ""))
    lines.append("\n## What each part of the profile costs (local pages)\n")
    lines.append("Δ = variant median − baseline median (wall-clock ms until loaded), summed over the local pages; "
                 "negative: the variant is faster, i.e. the part left out costs that much.\n")
    lines.append("| variant | Δ cold wall | Δ warm wall | Δ cold load | Δ cold scriptMs | per page (cold wall) | applied |")
    lines.append("|---|---|---|---|---|---|---|")
    for variant, result in measured.items():
        if variant == "baseline" or not isinstance(result, dict) or "pages" not in result:
            if variant != "baseline" and isinstance(result, dict) and result.get("error"):
                lines.append(f"| {variant} | error: {result['error'][:80]} | | | | | |")
            continue
        sums, per_page = {}, []
        for name, runs in result["pages"].items():
            base = baseline.get(name)
            if not base:
                continue
            for phase, key in (("cold", "wallMs"), ("warm", "wallMs"), ("cold", "load"), ("cold", "scriptMs")):
                a, b = median(runs.get(phase, []), key), median(base.get(phase, []), key)
                if a is not None and b is not None:
                    sums[(phase, key)] = round(sums.get((phase, key), 0) + a - b, 1)
                    if (phase, key) == ("cold", "wallMs"):
                        per_page.append(f"{name} {a - b:+.0f}")
        data["factors"][variant] = {**{f"{p}.{k}": v for (p, k), v in sums.items()}, "applied": result.get("applied"),
                                                                                    "shimTrace": result.get("shimTrace")}
        applied = result.get("applied") or {}
        notes = ", ".join(str(x) for x in (applied.get("pool") or []) + (applied.get("store") or []))
        lines.append(f"| {variant} | {fmt(sums.get(('cold', 'wallMs')))} | {fmt(sums.get(('warm', 'wallMs')))} | "
                     f"{fmt(sums.get(('cold', 'load')))} | {fmt(sums.get(('cold', 'scriptMs')))} | {'; '.join(per_page)} | {notes} |")
    dump = app.get("dump") or {}
    lines.append("\n## Configuration: the profile next to a plain WKWebView\n")
    for a, b, title in (("poolProfile", "poolShared", "process pool (_WKProcessPoolConfiguration)"),
                        ("storeProfile", "storeEphemeral", "data store (_WKWebsiteDataStoreConfiguration; vs an ephemeral store)"),
                        ("preferencesProfile", "preferencesPlain", "WKPreferences"),
                        ("featuresProfile", "featuresPlain", "WebKit features"),
                        ("webViewConfigurationProfile", "webViewConfigurationPlain", "WKWebViewConfiguration")):
        left, right = dump.get(a), dump.get(b)
        if not isinstance(left, dict) or not isinstance(right, dict):
            lines.append(f"- {title}: {fmt(left)} / {fmt(right)}")
            continue
        differ = [f"`{k}`: profile {left.get(k, '—')}, plain {right.get(k, '—')}" for k in sorted(set(left) | set(right))
                  if left.get(k) != right.get(k)]
        lines.append(f"- {title}: {len(differ)} of {len(set(left) | set(right))} differ" + ("".join(f"\n  - {d}" for d in differ)))
    for key in ("poolProfile", "storeProfile"):
        if isinstance(dump.get(key), dict):
            lines.append(f"\n<details><summary>{key} (all)</summary>\n\n```\n"
                         + "\n".join(f"{k} = {v}" for k, v in sorted(dump[key].items())) + "\n```\n</details>")
    lines.append(f"\n- user scripts: {dump.get('userScripts')}")
    lines.append(f"- shim in the baseline page: {json.dumps(dump.get('shimTrace'))}")
    for variant in ("zone", "zone-no-tz-shim", "no-shims"):
        trace = (measured.get(variant) or {}).get("shimTrace") if isinstance(measured.get(variant), dict) else None
        lines.append(f"- shim in {variant}: {json.dumps(trace)}")
    lines.append("\n## The HTTP cache across a stop and a start (sealed, restored)\n")
    lines.append("```\n" + json.dumps(app.get("cache"), indent=1, sort_keys=True) + "\n```")
    data["dump"], data["cache"] = dump, app.get("cache")
    return "\n".join(lines), data


def safari_webkit_defaults():
    """Safari's WebKit preferences on this Mac (its defaults domain), as far as they can be read."""
    out = {}
    for domain in ("com.apple.Safari", os.path.expanduser("~/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari")):
        try:
            text = subprocess.run(["defaults", "read", domain], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        for line in text.splitlines():
            if "WebKit" in line and "=" in line:
                key, value = line.split("=", 1)
                out[key.strip().strip('"')] = value.strip().rstrip(";")
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the unsandboxed PrivacyBrowser.app")
    parser.add_argument("--out", required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--settle", type=int, default=400, help="ms after the load before the metrics are read")
    parser.add_argument("--width", type=int, default=1000)
    parser.add_argument("--height", type=int, default=700)
    parser.add_argument("--no-real-sites", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    server = Server(("127.0.0.1", port), make_handler(port))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{port}"
    pages = local_pages(base)
    if not args.no_real_sites:
        for name, url in REAL_SITES:
            ok = reachable(url)
            print(f"INFO real site {name} {url}: {'reachable' if ok else 'not reachable, left out'}")
            if ok:
                pages.append({"name": name, "url": url, "local": False})
    window = {"width": args.width, "height": args.height}
    local_names = [p["name"] for p in pages if p["local"]]

    print("PAGE-SPEED Safari", flush=True)
    safari = safari_runs(pages, args.runs, args.settle, window)
    with open(os.path.join(args.out, "safari.json"), "w", encoding="utf-8") as handle:
        json.dump(safari, handle, indent=1, sort_keys=True)
    print("PAGE-SPEED profile", flush=True)
    spec = {"window": window, "runs": args.runs, "settleMs": args.settle, "timeoutMs": 30000, "metricsScript": METRICS,
            "pages": [{"name": p["name"], "url": p["url"]} for p in pages],
            "variants": variants(local_names, [p["name"] for p in pages]),
            "cacheProbe": {"url": f"{base}/cache-probe.html", "hits": f"{base}/pb-hits?path=/cache-probe.js"}}
    app = run_app(os.path.abspath(args.app), spec, os.path.abspath(os.path.join(args.out, "app")))
    server.shutdown()
    if not safari and not app:
        print("PAGE-SPEED: nothing measured")
        return 2
    text, data = report(safari, app, pages, local_names)
    defaults = safari_webkit_defaults()
    text += "\n\n## Safari's WebKit preferences on this Mac (defaults)\n\n" + (
        "\n".join(f"- `{k}` = {v}" for k, v in sorted(defaults.items())) or "none readable")
    data["safariDefaults"] = defaults
    with open(os.path.join(args.out, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(text + "\n")
    with open(os.path.join(args.out, "report.json"), "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=1, sort_keys=True)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
