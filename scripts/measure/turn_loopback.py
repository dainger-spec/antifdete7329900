#!/usr/bin/env python3
"""Measurement only (never merged): does WebKit's libwebrtc reach a TURN server on 127.0.0.1?

The relay that carries a proxied profile's WebRTC is to move out of the packet tunnel, into a TURN
server on a socket of the app itself. On the loopback interface nothing but this Mac's own processes
can reach it; on the physical interface's address (the old CI harness) every host of the LAN can.
Each variant runs `Lumen --capture-sites` once, alone, inside a pktap capture of every packet that is
not loopback, with its own SOCKS5 proxy that relays UDP (leak_check.ForwardingProxy):

* the candidates a page gathers (relay only, at the address the site sees through the proxy?),
* a data channel between two connections of the page through the relay and the proxy,
* a video call: a canvas stream from one connection to the other, frames decoded on the far side,
* packets of the app's processes (or sent on their behalf) that left other than on loopback.

Runs 609 and 610: on macOS 27 the call connected through the relay, but no frame of the canvas was
encoded (on the physical interface neither). This run keeps loopback only and calls from five
sources (SOURCES), each with the local track's state and the sender's media-source frames.
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from leak_check import ForwardingProxy, QUIC_SITE, WEBRTC_SCRIPT  # noqa: E402
from live_compare import run_app  # noqa: E402
import egress_check  # noqa: E402

# Where a video call's frames come from: a canvas not in the document (runs 609, 610: no frame
# encoded on macOS 27, none on the physical interface either), one in the document and on screen,
# one kept in memory (willReadFrequently), WebGL, and WebKit's mock camera through getUserMedia.
SOURCES = ("canvas", "canvas-dom", "canvas-cpu", "webgl", "camera")

VIDEO_SCRIPT = r"""
if (typeof RTCPeerConnection !== 'function') return { available: false };
const config = { iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }] };
const a = new RTCPeerConnection(config), b = new RTCPeerConnection(config);
const types = [];
const forward = (to) => (event) => {
  if (!event.candidate) return;
  types.push((/ typ (\w+)/.exec(event.candidate.candidate) || [])[1]);
  to.addIceCandidate(event.candidate).catch(() => {});
};
a.onicecandidate = forward(b);
b.onicecandidate = forward(a);
const source = 'SOURCE';
let painted = 0, paint = null, stream = null, sourceError = null;
const canvas = document.createElement('canvas');
canvas.width = 320; canvas.height = 240;
if (source === 'canvas-dom') { canvas.style.cssText = 'position:fixed;left:0;top:0;width:320px;height:240px;z-index:9'; document.body.appendChild(canvas); }
try {
  if (source === 'camera') {
    stream = await navigator.mediaDevices.getUserMedia({ video: { width: 320, height: 240 } });
  } else if (source === 'webgl') {
    const gl = canvas.getContext('webgl');
    paint = setInterval(() => { gl.clearColor((painted % 30) / 30, 0.5, 1 - (painted % 30) / 30, 1); gl.clear(gl.COLOR_BUFFER_BIT); painted++; }, 33);
    stream = canvas.captureStream(30);
  } else {
    const context = canvas.getContext('2d', source === 'canvas-cpu' ? { willReadFrequently: true } : undefined);
    paint = setInterval(() => {
      context.fillStyle = 'hsl(' + ((painted * 7) % 360) + ',80%,50%)';
      context.fillRect(0, 0, 320, 240);
      context.fillStyle = '#000';
      context.fillText(String(painted++), 10, 20);
    }, 33);
    stream = canvas.captureStream(30);
  }
} catch (e) { sourceError = String(e); }
if (!stream) return { available: true, source, sourceError };
const local = stream.getVideoTracks()[0];
const localState = () => local ? { readyState: local.readyState, muted: local.muted, enabled: local.enabled,
                                   settings: local.getSettings ? local.getSettings() : null } : null;
const localAtStart = localState();
for (const track of stream.getTracks()) a.addTrack(track, stream);
let preferred = 'default';
try {
  const caps = RTCRtpSender.getCapabilities('video');
  const vp8 = caps.codecs.filter((c) => c.mimeType.toLowerCase() === 'video/vp8');
  const rest = caps.codecs.filter((c) => c.mimeType.toLowerCase() !== 'video/vp8');
  if (vp8.length) { a.getTransceivers()[0].setCodecPreferences(vp8.concat(rest)); preferred = 'vp8'; }
} catch (e) { preferred = 'error: ' + e; }
const timeout = (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms));
const remote = new Promise((resolve) => { b.ontrack = (event) => resolve(event.track); });
await a.setLocalDescription(await a.createOffer());
await b.setRemoteDescription(a.localDescription);
await b.setLocalDescription(await b.createAnswer());
await a.setRemoteDescription(b.localDescription);
const track = await Promise.race([remote, timeout(20000, null)]);
await timeout(10000);
let inbound = null, outbound = null, mediaSource = null, codecs = [];
try {
  (await b.getStats()).forEach((s) => {
    if (s.type === 'inbound-rtp' && s.kind === 'video') {
      inbound = { framesDecoded: s.framesDecoded, bytesReceived: s.bytesReceived, packetsReceived: s.packetsReceived,
                  decoder: s.decoderImplementation };
    }
    if (s.type === 'codec') codecs.push(s.mimeType);
  });
  (await a.getStats()).forEach((s) => {
    if (s.type === 'outbound-rtp' && s.kind === 'video') {
      outbound = { framesEncoded: s.framesEncoded, framesSent: s.framesSent, bytesSent: s.bytesSent,
                   encoder: s.encoderImplementation, limitation: s.qualityLimitationReason };
    }
    if (s.type === 'media-source' && s.kind === 'video') {
      mediaSource = { frames: s.frames, framesPerSecond: s.framesPerSecond, width: s.width, height: s.height };
    }
  });
} catch (e) { inbound = { error: String(e) }; }
const ice = a.iceConnectionState;
if (paint) clearInterval(paint);
const localAtEnd = localState();
for (const t of stream.getTracks()) t.stop();
a.close(); b.close();
return { available: true, source, track: !!track, ice, inbound, outbound, mediaSource, codecs, preferred, painted,
         localAtStart, localAtEnd, visibility: document.visibilityState, hidden: document.hidden,
         candidateTypes: [...new Set(types)].sort() };
"""


def capture_run(app, variant, out):
    proxy = ForwardingProxy(udp=True)
    profile = {"name": f"relay-{variant}", "webRTC": "unrestricted", "relay": "harness", "relayBind": variant,
               "mockCapture": True, "grantMedia": True,
               "proxy": {"kind": "socks5", "host": "127.0.0.1", "port": proxy.socks_port}}
    pages = [{"name": "webrtc", "url": QUIC_SITE, "script": WEBRTC_SCRIPT, "timeoutMs": 30000}] + [
        {"name": f"video-{source}", "url": QUIC_SITE, "script": VIDEO_SCRIPT.replace("SOURCE", source), "timeoutMs": 60000}
        for source in SOURCES
    ]
    spec = {"window": {"width": 1000, "height": 600}, "profiles": [profile], "pages": pages}
    capture_path = os.path.join(out, f"capture-{variant}.txt")
    with open(capture_path, "w") as capture_file, open(capture_path + ".err", "w") as errors:
        tcpdump = subprocess.Popen(["sudo", "-n", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l",
                                    "not host 127.0.0.1 and not host ::1"], stdout=capture_file, stderr=errors)
        time.sleep(3)
        started = time.time()
        try:
            results = run_app(os.path.abspath(app), spec, os.path.abspath(os.path.join(out, variant)))
        finally:
            ended = time.time()
            time.sleep(2)
            subprocess.run(["sudo", "-n", "pkill", "-INT", "-f", "tcpdump -i pktap"], check=False)
            tcpdump.wait(timeout=20)
    app_packets = []
    with open(capture_path, errors="replace") as handle:
        for line in handle:
            packet = egress_check.parse(line)
            if packet["time"] is None or not (started <= packet["time"] <= ended):
                continue
            owners = [o[0] for o in (packet["proc"], packet["eproc"]) if o]
            if any(name.startswith(("Lumen", "com.apple.WebKit")) for name in owners):
                app_packets.append(packet["line"][:220])
    result = results.get(profile["name"], {})
    return {
        "variant": variant,
        "proxyUdpAssociations": sum(1 for r in proxy.requests if r["command"] == "UDP ASSOCIATE"),
        "proxyUdpDatagrams": proxy.udp_datagrams,
        "webrtc": result.get("webrtc"),
        "video": {source: result.get(f"video-{source}") for source in SOURCES},
        "appPacketsOutsideLoopback": len(app_packets),
        "appPacketSamples": app_packets[:25],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    report = [capture_run(args.app, "loopback", args.out)]
    with open(os.path.join(args.out, "report.json"), "w") as handle:
        json.dump(report, handle, indent=1, sort_keys=True)
    lines = ["### A video call's frames by source (relay on 127.0.0.1, VP8 first)", "",
             "| source | painted | local track at start / end | media-source frames | encoded / sent | decoded | ice | visibility | error |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in report:
        for source, video in r["video"].items():
            video = video or {}
            out, inbound, media = video.get("outbound") or {}, video.get("inbound") or {}, video.get("mediaSource") or {}
            def state(s):
                return f"{s.get('readyState')}{' muted' if s.get('muted') else ''}" if s else None
            lines.append(f"| {source} | {video.get('painted')} | {state(video.get('localAtStart'))} / {state(video.get('localAtEnd'))} | "
                         f"{media.get('frames')} | {out.get('framesEncoded')} / {out.get('framesSent')} ({out.get('encoder')}) | "
                         f"{inbound.get('framesDecoded')} ({inbound.get('decoder')}) | {video.get('ice')} | {video.get('visibility')} | "
                         f"{video.get('sourceError') or video.get('error') or ''} |")
        lines.append("")
        lines.append(f"proxy UDP associations/datagrams {r['proxyUdpAssociations']}/{r['proxyUdpDatagrams']}; "
                     f"app packets outside loopback {r['appPacketsOutsideLoopback']}; candidates {(r['webrtc'] or {}).get('candidates')}")
    text = "\n".join(lines) + "\n"
    print(text)
    for r in report:
        print(f"[{r['variant']}] samples: " + json.dumps(r["appPacketSamples"], indent=1))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
