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
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from leak_check import ForwardingProxy, LOOP_SCRIPT, QUIC_SITE, WEBRTC_SCRIPT  # noqa: E402
from live_compare import run_app  # noqa: E402
import egress_check  # noqa: E402

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
const canvas = document.createElement('canvas');
canvas.width = 320; canvas.height = 240;
const context = canvas.getContext('2d');
let painted = 0;
const paint = setInterval(() => {
  context.fillStyle = 'hsl(' + ((painted * 7) % 360) + ',80%,50%)';
  context.fillRect(0, 0, 320, 240);
  context.fillStyle = '#000';
  context.fillText(String(painted++), 10, 20);
}, 33);
const stream = canvas.captureStream(30);
for (const track of stream.getTracks()) a.addTrack(track, stream);
const timeout = (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms));
const remote = new Promise((resolve) => { b.ontrack = (event) => resolve(event.track); });
await a.setLocalDescription(await a.createOffer());
await b.setRemoteDescription(a.localDescription);
await b.setLocalDescription(await b.createAnswer());
await a.setRemoteDescription(b.localDescription);
const track = await Promise.race([remote, timeout(20000, null)]);
await timeout(10000);
let inbound = null;
try {
  (await b.getStats()).forEach((s) => {
    if (s.type === 'inbound-rtp' && s.kind === 'video') {
      inbound = { framesDecoded: s.framesDecoded, bytesReceived: s.bytesReceived, packetsReceived: s.packetsReceived };
    }
  });
} catch (e) { inbound = { error: String(e) }; }
const ice = a.iceConnectionState;
clearInterval(paint);
a.close(); b.close();
return { available: true, track: !!track, ice, inbound, painted, candidateTypes: [...new Set(types)].sort() };
"""


def capture_run(app, variant, out):
    proxy = ForwardingProxy(udp=True)
    profile = {"name": f"relay-{variant}", "webRTC": "unrestricted", "relay": "harness", "relayBind": variant,
               "proxy": {"kind": "socks5", "host": "127.0.0.1", "port": proxy.socks_port}}
    pages = [
        {"name": "webrtc", "url": QUIC_SITE, "script": WEBRTC_SCRIPT, "timeoutMs": 30000},
        {"name": "webrtc-loop", "url": QUIC_SITE, "script": LOOP_SCRIPT, "timeoutMs": 45000},
        {"name": "webrtc-video", "url": QUIC_SITE, "script": VIDEO_SCRIPT, "timeoutMs": 60000},
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
        "loop": result.get("webrtc-loop"),
        "video": result.get("webrtc-video"),
        "appPacketsOutsideLoopback": len(app_packets),
        "appPacketSamples": app_packets[:25],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    report = [capture_run(args.app, variant, args.out) for variant in ("loopback", "primary")]
    with open(os.path.join(args.out, "report.json"), "w") as handle:
        json.dump(report, handle, indent=1, sort_keys=True)
    lines = ["### TURN on loopback vs the physical interface", "",
             "| relay bound to | candidates | relay at proxy address | data channel | video: frames decoded | proxy UDP assoc./datagrams | app packets outside loopback |",
             "|---|---|---|---|---|---|---|"]
    for r in report:
        w, loop, video = r["webrtc"] or {}, r["loop"] or {}, r["video"] or {}
        inbound = video.get("inbound") or {}
        lines.append(f"| {r['variant']} | {w.get('candidates')} | {w.get('relayIsProxyAddress')} | "
                     f"{loop.get('delivered')} ({loop.get('ice')}) | {inbound.get('framesDecoded')} "
                     f"({video.get('ice')}, track {video.get('track')}) | {r['proxyUdpAssociations']}/{r['proxyUdpDatagrams']} | "
                     f"{r['appPacketsOutsideLoopback']} |")
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
