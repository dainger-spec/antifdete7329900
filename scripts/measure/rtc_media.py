#!/usr/bin/env python3
"""Measurement, on a branch only (never merged): WebRTC and the camera/microphone in a profile, next
to this Mac's Safari — on our own probe pages and on live fingerprinting services.

    sudo safaridriver --enable
    python3 scripts/measure/rtc_media.py --app build/unsandboxed/Lumen.app --out build/measure

The owner's questions of 2 November, answered by measurement and not by reading code:

2. A profile with a proxy has no RTCPeerConnection at all. What does a site's script see, how does it
   differ from Safari on the same Mac, which checks tell the two apart — our probe (every RTC and
   media interface, the window's own property count, codecs, ICE gathering), and live services
   (their page text around WebRTC, and a screenshot of what they show). And: can WebKit keep the API
   while no packet can leave? Every WebKit feature whose name speaks of WebRTC sockets is flipped, one
   profile each, around a pktap capture of the whole Mac; the control is a profile with WebRTC on.
3. The camera and the microphone: what a site's request does, who is asked, what enumerateDevices
   gives before and after (labels, ids, count) — and whether two profiles on one Mac get the same ids.
   CI has no camera: WebKit's own mock devices stand in for one (the same id hashing as real ones).

Writes <out>/report.json, <out>/report.md (also the job's summary), screenshots, the capture.
A measurement: it fails only when nothing was measured at all.
"""
import argparse
import base64
import http.server
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import egress_check  # noqa: E402  (parse)
import leak_check  # noqa: E402  (ForwardingProxy)
from safari_reference import WebDriver, free_port, wait_for_port  # noqa: E402

# Every interface a page can test for, of WebRTC and of media capture.
SURFACE = r"""
const names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCIceCandidate',
  'RTCDataChannel', 'RTCDataChannelEvent', 'RTCPeerConnectionIceEvent', 'RTCPeerConnectionIceErrorEvent',
  'RTCTrackEvent', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCDTMFSender', 'RTCDTMFToneChangeEvent',
  'RTCCertificate', 'RTCStatsReport', 'RTCIceTransport', 'RTCDtlsTransport', 'RTCSctpTransport', 'RTCError',
  'RTCErrorEvent', 'RTCRtpScriptTransform', 'RTCRtpScriptTransformer', 'RTCEncodedAudioFrame', 'RTCEncodedVideoFrame',
  'RTCTransformEvent', 'MediaStream', 'MediaStreamTrack', 'MediaStreamTrackEvent', 'MediaDevices', 'MediaDeviceInfo',
  'InputDeviceInfo', 'MediaRecorder', 'MediaStreamAudioSourceNode', 'OverconstrainedError', 'CanvasCaptureMediaStreamTrack'];
const own = Object.getOwnPropertyNames(window);
const source = (f) => { try { return Function.prototype.toString.call(f); } catch (e) { return 'error ' + e.name; } };
let codecs = null;
try {
  if (window.RTCRtpSender && RTCRtpSender.getCapabilities) {
    codecs = { audio: RTCRtpSender.getCapabilities('audio').codecs.map((c) => c.mimeType + '/' + c.clockRate),
               video: RTCRtpSender.getCapabilities('video').codecs.map((c) => c.mimeType) };
  }
} catch (e) { codecs = 'error ' + e.name; }
let ice = null;
if (typeof RTCPeerConnection === 'function') {
  ice = await (async () => {
    const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
    const found = [];
    pc.onicecandidate = (e) => {
      if (e.candidate && e.candidate.candidate) {
        const c = e.candidate.candidate, p = c.split(' ');
        found.push(p[2].toLowerCase() + ' ' + ((/ typ (\w+)/.exec(c) || [])[1]) + (/\.local /.test(c) ? ' (mDNS name)' : ''));
      }
    };
    pc.createDataChannel('probe');
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await new Promise((resolve) => {
      const timer = setTimeout(resolve, 6000);
      pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') { clearTimeout(timer); resolve(); } };
    });
    const state = pc.iceGatheringState;
    pc.close();
    return { candidates: found, gatheringState: state, offerLines: offer.sdp.split('\r\n').length };
  })().catch((e) => 'error ' + e.name + ': ' + e.message);
}
return {
  userAgent: navigator.userAgent,
  present: names.filter((n) => n in window),
  absent: names.filter((n) => !(n in window)),
  ownProperties: own.length,
  related: own.filter((n) => /RTC|MediaStream|MediaDevice|UserMedia|MediaRecorder/i.test(n)).sort(),
  RTCPeerConnectionSource: window.RTCPeerConnection ? source(window.RTCPeerConnection) : null,
  mediaDevices: typeof navigator.mediaDevices,
  getUserMedia: typeof (navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
  enumerateDevices: typeof (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices),
  legacyGetUserMedia: typeof navigator.getUserMedia + ' / ' + typeof navigator.webkitGetUserMedia,
  codecs,
  ice,
  checks: {
    "'RTCPeerConnection' in window": 'RTCPeerConnection' in window,
    "typeof RTCDataChannel === 'function'": typeof RTCDataChannel === 'function',
    'navigator.mediaDevices': !!navigator.mediaDevices,
    "typeof MediaStream === 'function'": typeof MediaStream === 'function',
  },
};
"""

# A site's request for the camera and the microphone: the list before, the answer, the list after.
MEDIA = r"""
const out = { origin: location.origin };
if (!navigator.mediaDevices) return { origin: location.origin, mediaDevices: 'absent' };
const list = async () => {
  try {
    return (await navigator.mediaDevices.enumerateDevices())
      .map((d) => ({ kind: d.kind, label: d.label, deviceId: d.deviceId, groupId: d.groupId }));
  } catch (e) { return 'error ' + e.name + ': ' + e.message; }
};
out.before = await list();
for (const name of ['camera', 'microphone']) {
  try { out['permission ' + name] = (await navigator.permissions.query({ name })).state; }
  catch (e) { out['permission ' + name] = 'error ' + e.name; }
}
const limit = (ms) => new Promise((_, reject) => setTimeout(() => reject(new Error('no answer in ' + ms + ' ms')), ms));
const started = Date.now();
try {
  const stream = await Promise.race([navigator.mediaDevices.getUserMedia({ audio: true, video: true }), limit(12000)]);
  out.getUserMedia = 'granted';
  out.tracks = stream.getTracks().map((t) => {
    const s = t.getSettings();
    return { kind: t.kind, label: t.label, deviceId: s.deviceId, groupId: s.groupId, width: s.width, height: s.height,
             frameRate: s.frameRate, sampleRate: s.sampleRate };
  });
  stream.getTracks().forEach((t) => t.stop());
} catch (e) { out.getUserMedia = (e.name || 'Error') + ': ' + e.message; }
out.answeredInMs = Date.now() - started;
out.after = await list();
return out;
"""

# What a WebRTC leak test does: STUN over UDP to two public servers, TURN over TCP and TLS to a
# public address (no credentials that work: the attempt itself is what a capture would show).
PROBE = r"""
if (typeof RTCPeerConnection !== 'function') return { available: false };
const pc = new RTCPeerConnection({ iceServers: [
  { urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] },
  { urls: ['turn:stun.l.google.com:19302?transport=tcp', 'turns:stun.l.google.com:443?transport=tcp'], username: 'probe', credential: 'probe' },
] });
const found = [];
pc.onicecandidate = (e) => {
  if (e.candidate && e.candidate.candidate) {
    const c = e.candidate.candidate, p = c.split(' ');
    found.push(p[2].toLowerCase() + ' ' + ((/ typ (\w+)/.exec(c) || [])[1]) + (/\.local /.test(c) ? ' (mDNS name)' : ''));
  }
};
let errors = 0;
pc.onicecandidateerror = () => { errors += 1; };
pc.createDataChannel('probe');
await pc.setLocalDescription(await pc.createOffer());
await new Promise((resolve) => {
  const timer = setTimeout(resolve, 10000);
  pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') { clearTimeout(timer); resolve(); } };
});
const state = pc.iceGatheringState;
pc.close();
return { available: true, candidates: found, candidateErrors: errors, gatheringState: state };
"""

# A live service: wait as a person would, bring its WebRTC part into view, keep its text.
LIVE = r"""
const marker = [...document.querySelectorAll('h1,h2,h3,h4,h5,th,td,dt,div,span,p,section,a')]
  .find((e) => /webrtc/i.test(e.textContent || '') && (e.textContent || '').trim().length < 120);
if (marker) marker.scrollIntoView({ block: 'start' });
await new Promise((r) => setTimeout(r, 1200));
const text = (document.body && document.body.innerText) || '';
return { title: document.title, url: location.href, scrolledToWebRTC: !!marker, length: text.length, text: text.slice(0, 40000) };
"""

LIVE_SITES = [
    ("browserleaks-webrtc", "https://browserleaks.com/webrtc", 12000),
    ("creepjs", "https://abrahamjuliot.github.io/creepjs/", 25000),
    ("browserscan", "https://www.browserscan.net/", 20000),
    ("pixelscan", "https://pixelscan.net/", 25000),
    ("whoer", "https://whoer.net/", 15000),
    ("ipleak", "https://ipleak.net/", 15000),
    ("deviceinfo", "https://www.deviceinfo.me/", 15000),
]

# Lines of a service's text worth reading: what it says about WebRTC, devices and leaks.
KEYWORDS = re.compile(r"webrtc|rtc|peer ?connection|media ?devices?|camera|microphone|webcam|speaker|leak|ice|stun|"
                      r"lie|spoof|masking|inconsisten|anomal|trust|score|bot|fingerprint", re.I)


class Pages(http.server.BaseHTTPRequestHandler):
    """A blank page at every path: the scripts are run in it."""

    def log_message(self, *args):
        pass

    def do_GET(self):
        body = b"<!doctype html><html><head><meta charset='utf-8'><title>probe</title></head><body>probe</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


ASYNC_WRAPPER = """const __done = arguments[arguments.length - 1];
(async () => {
%s
})().then((v) => __done(JSON.stringify(v === undefined ? null : v)),
          (e) => __done(JSON.stringify({ error: String(e && e.message || e) })));"""


def safari(pages, out, window):
    """The pages in this Mac's Safari (safaridriver), with a screenshot where asked."""
    port = free_port()
    driver_process = subprocess.Popen(["safaridriver", "-p", str(port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    results = {}
    try:
        if not wait_for_port(port, 20):
            return {"error": "safaridriver did not start"}
        driver = WebDriver(f"http://127.0.0.1:{port}")
        capabilities = driver.start()
        results["_browser"] = {"name": "Safari", "version": capabilities.get("browserVersion")}
        try:
            driver.request("POST", f"/session/{driver.session}/timeouts", {"script": 150000, "pageLoad": 120000})
            driver.request("POST", f"/session/{driver.session}/window/rect", {"x": 60, "y": 60, **window})
            for page in pages:
                print(f"INFO [safari] {page['name']}: {page['url']}", flush=True)
                try:
                    driver.navigate(page["url"])
                    if page.get("settleMs"):
                        time.sleep(page["settleMs"] / 1000)
                    value = driver.request("POST", f"/session/{driver.session}/execute/async",
                                           {"script": ASYNC_WRAPPER % page["script"], "args": []},
                                           timeout=page.get("timeoutMs", 90000) / 1000 + 30)
                    results[page["name"]] = json.loads(value) if isinstance(value, str) else value
                    if page.get("screenshot"):
                        shot = driver.request("GET", f"/session/{driver.session}/screenshot", timeout=60)
                        with open(os.path.join(out, f"safari-{page['name']}.png"), "wb") as handle:
                            handle.write(base64.b64decode(shot))
                except Exception as exc:  # noqa: BLE001 - one page failing must not stop the others
                    print(f"INFO [safari] {page['name']} failed: {exc}", flush=True)
                    results[page["name"]] = {"error": str(exc)}
        finally:
            driver.quit()
    finally:
        driver_process.terminate()
        try:
            driver_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            driver_process.kill()
    return results


def lumen(app, spec, out, label):
    """`Lumen --capture-sites` with `spec`; results by profile, the run's stdout kept."""
    os.makedirs(out, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(spec, handle)
        spec_path = handle.name
    binary = os.path.join(app, "Contents", "MacOS", "Lumen")
    started = time.time()
    print(f"::group::Lumen --capture-sites ({label})", flush=True)
    try:
        run = subprocess.run([binary, "--capture-sites", spec_path, out], capture_output=True, text=True, timeout=1500)
        output, code = run.stdout + run.stderr, run.returncode
    except subprocess.TimeoutExpired as exc:
        output, code = (exc.stdout or b"").decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or ""), None
    print(output[-6000:], flush=True)
    print("::endgroup::", flush=True)
    with open(os.path.join(out, "stdout.txt"), "w", encoding="utf-8") as handle:
        handle.write(output)
    results = {"_run": {"exit": code, "started": started, "ended": time.time(),
                        "measureLines": [line for line in output.splitlines() if line.startswith("MEASURE")]}}
    for profile in spec["profiles"]:
        path = os.path.join(out, profile["name"] + ".json")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                results[profile["name"]] = json.load(handle)
    features = os.path.join(out, "features.json")
    if os.path.exists(features):
        with open(features, encoding="utf-8") as handle:
            results["_features"] = json.load(handle)
    return results


class Capture:
    """Every packet leaving or entering this Mac, with the process it is for (pktap)."""

    def __init__(self, path):
        self.path = path
        self.process = subprocess.Popen(["sudo", "-n", "tcpdump", "-i", "pktap,all", "-k", "INP", "-n", "-tt", "-l",
                                         "not host 127.0.0.1 and not host ::1"],
                                        stdout=open(path, "w"), stderr=open(path + ".err", "w"))
        time.sleep(2)

    def stop(self):
        subprocess.run(["sudo", "-n", "pkill", "-INT", "-f", "tcpdump -i pktap"], capture_output=True)
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()

    def packets(self):
        with open(self.path, encoding="utf-8", errors="replace") as handle:
            return [egress_check.parse(line) for line in handle]


def app_packets(packets, begin, end):
    """The app's packets (sent by it, or by WebKit for it) in [begin, end], outside loopback."""
    def ours(owner):
        return owner is not None and (owner[0].startswith("Lumen") or owner[0].startswith("com.apple.WebK"))
    seen = []
    for packet in packets:
        if packet["time"] is None or not (begin <= packet["time"] <= end):
            continue
        if not (ours(packet["proc"]) or ours(packet["eproc"])):
            continue
        meta = egress_check.META.search(packet["line"])
        if meta and meta.group(1).split(",")[0].strip() == "lo0":
            continue
        seen.append(packet)
    kinds = {"udp": 0, "tcp": 0}
    destinations = {}
    for packet in seen:
        kind = "tcp" if "Flags [" in packet["line"] else "udp"
        kinds[kind] += 1
        flow = egress_check.FLOW.search(packet["line"])
        port = flow.group(2).rsplit(".", 1)[-1] if flow else "?"
        key = f"{kind} {packet['dst']}:{port}"
        destinations[key] = destinations.get(key, 0) + 1
    return {"packets": len(seen), **kinds, "destinations": sorted(destinations.items(), key=lambda kv: -kv[1])[:10]}


def interesting(text, limit=40):
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return [line[:200] for line in lines if KEYWORDS.search(line)][:limit]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--no-live", action="store_true", help="skip the live services")
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    app = os.path.abspath(args.app)
    window = {"width": 1100, "height": 760}

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    origin_a, origin_b = f"http://127.0.0.1:{port}", f"http://localhost:{port}"
    proxy = leak_check.ForwardingProxy()
    http_proxy = {"kind": "httpConnect", "host": "127.0.0.1", "port": proxy.http_port}

    live = [] if args.no_live else [
        {"name": name, "url": url, "script": LIVE, "settleMs": settle, "timeoutMs": 60000, "screenshot": True}
        for name, url, settle in LIVE_SITES]
    surface_page = {"name": "surface", "url": f"{origin_a}/surface.html", "script": SURFACE, "timeoutMs": 30000}
    media_pages = [
        {"name": "media-127", "url": f"{origin_a}/media.html", "script": MEDIA, "timeoutMs": 40000, "screenshot": True},
        {"name": "media-localhost", "url": f"{origin_b}/media.html", "script": MEDIA, "timeoutMs": 40000},
        {"name": "media-127-again", "url": f"{origin_a}/media-again.html", "script": MEDIA, "timeoutMs": 40000},
    ]
    report = {"origins": [origin_a, origin_b]}

    # 1. Safari on this Mac.
    print("::group::Safari", flush=True)
    os.makedirs(os.path.join(out, "shots"), exist_ok=True)
    report["safari"] = safari([surface_page, *media_pages, *live], os.path.join(out, "shots"), window)
    print("::endgroup::", flush=True)

    # 2. Profiles: a new profile as a person gets it, WebRTC on as in Safari, a proxy.
    surface_profiles = [
        {"name": "new-profile"},
        {"name": "webrtc-on", "webRTC": "unrestricted"},
        {"name": "proxied", "proxy": http_proxy, "webRTC": "unrestricted"},
        {"name": "proxied-default", "proxy": http_proxy},
    ]
    report["profiles"] = lumen(app, {"window": window, "profiles": surface_profiles, "pages": [surface_page], "listFeatures": True},
                               os.path.join(out, "profiles"), "the surface")
    if live:
        report["live"] = lumen(app, {"window": window, "pages": live,
                                     "profiles": [{"name": "new-profile"}, {"name": "webrtc-on", "webRTC": "unrestricted"},
                                                  {"name": "proxied", "proxy": http_proxy, "webRTC": "unrestricted"}]},
                               os.path.join(out, "shots"), "live services")

    # 3. The camera and the microphone: two persistent profiles with WebKit's mock devices, one
    #    ephemeral, one without mock devices (this Mac's own, none on CI), each asked twice on one
    #    origin and once on another.
    media_profiles = [
        {"name": "camera-A", "persistent": True, "mockCapture": True, "grantMedia": True},
        {"name": "camera-B", "persistent": True, "mockCapture": True, "grantMedia": True},
        {"name": "camera-A-ephemeral", "mockCapture": True, "grantMedia": True},
        {"name": "camera-real-devices", "persistent": True, "grantMedia": True},
        {"name": "camera-proxied", "persistent": True, "mockCapture": True, "grantMedia": True, "proxy": http_proxy},
    ]
    report["media"] = lumen(app, {"window": window, "profiles": media_profiles, "pages": media_pages},
                            os.path.join(out, "media"), "camera and microphone")

    # 4. Can the API stay while nothing leaves? Each WebKit feature about WebRTC's sockets flipped from
    #    its default, one profile each, WebRTC on, no proxy; the control has nothing flipped. All inside
    #    one capture of every packet.
    features = report["profiles"].get("_features") or {}
    candidates = sorted(key for key in features
                        if re.search(r"WebRTC|ICE|PeerConnection|MDNS|mDNS|Socket|UDP", key) and "Codec" not in key)
    report["webrtcFeatures"] = {key: features[key] for key in candidates}
    flips = [key for key in candidates if re.search(r"Socket|UDP|Proxying|ICE|MDNS|mDNS|Interface", key)]
    capture = Capture(os.path.join(out, "capture.txt"))
    probes = {}
    try:
        for name, flip in [("control", None)] + [(f"flip-{key}", key) for key in flips]:
            profile = {"name": name, "webRTC": "unrestricted"}
            if flip:
                profile["features"] = {flip: not features[flip]}
            result = lumen(app, {"window": window, "profiles": [profile],
                                 "pages": [{"name": "probe", "url": f"{origin_a}/probe.html", "script": PROBE, "timeoutMs": 30000}]},
                           os.path.join(out, "probes", name), name)
            probes[name] = {"flipped": flip and {flip: not features[flip]}, "page": (result.get(name) or {}).get("probe"),
                            "run": result["_run"]}
            time.sleep(3)
    finally:
        capture.stop()
    packets = capture.packets()
    for name, probe in probes.items():
        probe["wire"] = app_packets(packets, probe["run"]["started"], probe["run"]["ended"] + 2)
    report["probes"] = probes
    report["proxyRequests"] = proxy.requests[-40:]

    with open(os.path.join(out, "report.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=1, sort_keys=True, default=str)
    summary = summarize(report)
    with open(os.path.join(out, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(summary)
    print(summary)
    server.shutdown()
    measured = bool(report.get("safari")) or any(not k.startswith("_") for k in report.get("profiles", {}))
    return 0 if measured else 2


def summarize(report):
    lines = ["# WebRTC and media: what a site sees", ""]
    safari_surface = (report.get("safari") or {}).get("surface") or {}
    lines.append(f"Safari: {(report.get('safari') or {}).get('_browser')}")
    lines.append("")
    lines.append("## The surface (our probe)")
    lines.append("| browser | typeof RTCPeerConnection | interfaces present | own window properties | related names | ICE candidates | codecs (audio/video) |")
    lines.append("|---|---|---|---|---|---|---|")

    def row(name, data):
        if not isinstance(data, dict) or "present" not in data:
            return f"| {name} | {json.dumps(data)[:120]} | | | | | |"
        ice = data.get("ice")
        candidates = ", ".join(ice.get("candidates", [])) if isinstance(ice, dict) else str(ice)
        codecs = data.get("codecs")
        codec_text = f"{len(codecs['audio'])}/{len(codecs['video'])}" if isinstance(codecs, dict) else str(codecs)
        rtc = "yes" if "RTCPeerConnection" in data["present"] else "**no**"
        return (f"| {name} | {rtc} | {len(data['present'])} | {data['ownProperties']} | {len(data['related'])} | "
                f"{candidates or 'none'} | {codec_text} |")
    lines.append(row("Safari", safari_surface))
    for name, results in (report.get("profiles") or {}).items():
        if not name.startswith("_"):
            lines.append(row(f"Lumen {name}", (results or {}).get("surface")))
    lines.append("")
    if isinstance(safari_surface, dict) and "present" in safari_surface:
        for name, results in (report.get("profiles") or {}).items():
            data = (results or {}).get("surface") if not name.startswith("_") else None
            if isinstance(data, dict) and "present" in data:
                missing = sorted(set(safari_surface["present"]) - set(data["present"]))
                extra = sorted(set(data["present"]) - set(safari_surface["present"]))
                lines.append(f"- {name}: missing against Safari {len(missing)} ({', '.join(missing) or '—'}); extra {', '.join(extra) or '—'}; "
                             f"own window properties {data['ownProperties']} vs Safari {safari_surface['ownProperties']}")
        lines.append("")

    lines.append("## Live services (their text about WebRTC and devices; screenshots in shots/)")
    live = report.get("live") or {}
    for site, _, _ in LIVE_SITES:
        lines.append(f"### {site}")
        for browser, data in [("Safari", (report.get("safari") or {}).get(site))] + \
                [(f"Lumen {name}", (results or {}).get(site)) for name, results in live.items() if not name.startswith("_")]:
            if isinstance(data, dict) and "text" in data:
                lines.append(f"- **{browser}** ({data.get('length')} characters, WebRTC in view: {data.get('scrolledToWebRTC')}):")
                for line in interesting(data["text"], 25):
                    lines.append(f"  - {line}")
            else:
                lines.append(f"- **{browser}**: {json.dumps(data)[:200]}")
        lines.append("")

    lines.append("## Camera and microphone (WebKit's mock devices in the profiles; Safari as it is)")
    media = dict(report.get("media") or {})
    media_rows = [("Safari", report.get("safari") or {})] + [(name, data or {}) for name, data in media.items() if not name.startswith("_")]
    for name, data in media_rows:
        for page in ("media-127", "media-localhost", "media-127-again"):
            result = data.get(page)
            if not isinstance(result, dict):
                lines.append(f"- {name} {page}: {json.dumps(result)[:200]}")
                continue
            def brief(listing):
                if not isinstance(listing, list):
                    return str(listing)
                return "; ".join(f"{d['kind']} '{d['label']}' id {d['deviceId'][:12] or '∅'} group {d['groupId'][:8] or '∅'}" for d in listing) or "none"
            lines.append(f"- {name} {page} ({result.get('origin')}): getUserMedia → {result.get('getUserMedia')}; "
                         f"permissions camera {result.get('permission camera')}, microphone {result.get('permission microphone')}")
            lines.append(f"  - before: {brief(result.get('before'))}")
            lines.append(f"  - after: {brief(result.get('after'))}")
    lines.append(f"- who was asked (the app's UI delegate): {media.get('_run', {}).get('measureLines', [])[:12]}")
    ids = {}
    for name, data in media.items():
        if name.startswith("_"):
            continue
        for page in ("media-127", "media-localhost", "media-127-again"):
            after = (data or {}).get(page, {}).get("after") if isinstance((data or {}).get(page), dict) else None
            if isinstance(after, list):
                ids[(name, page)] = sorted(d["deviceId"] for d in after if d.get("deviceId"))
    lines.append("")
    lines.append("Device ids compared (after the request):")
    names = sorted(ids)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if ids[a] and ids[b]:
                common = len(set(ids[a]) & set(ids[b]))
                lines.append(f"- {a[0]} {a[1]} vs {b[0]} {b[1]}: {common} of {len(ids[a])}/{len(ids[b])} ids the same")
    lines.append("")

    lines.append("## Keeping the API, losing the network: WebKit's switches under a packet capture")
    lines.append(f"WebKit features about WebRTC here: {json.dumps(report.get('webrtcFeatures'))}")
    lines.append("| profile | flipped | page: candidates | candidate errors | app packets outside loopback (udp/tcp) | where to |")
    lines.append("|---|---|---|---|---|---|")
    for name, probe in (report.get("probes") or {}).items():
        page = probe.get("page")
        candidates = ", ".join(page.get("candidates", [])) if isinstance(page, dict) else json.dumps(page)[:80]
        wire = probe.get("wire", {})
        lines.append(f"| {name} | {json.dumps(probe.get('flipped'))} | {candidates or 'none'} | "
                     f"{page.get('candidateErrors') if isinstance(page, dict) else ''} | {wire.get('packets')} ({wire.get('udp')}/{wire.get('tcp')}) | "
                     f"{', '.join(f'{d} ×{n}' for d, n in wire.get('destinations', [])[:4])} |")
    lines.append("")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    sys.exit(main())
