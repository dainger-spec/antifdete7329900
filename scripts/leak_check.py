#!/usr/bin/env python3
"""Does anything a profile sends go around its proxy? Measured, not assumed.

    python3 scripts/leak_check.py --app build/unsandboxed/PrivacyBrowser.app --out build/leaks

Runs `PrivacyBrowser --capture-sites` (SiteCapture.swift) with profiles that use real forwarding
proxies started here (HTTP CONNECT and SOCKS5; every request they get is logged), next to a
profile without a proxy as the control:

* QUIC / HTTP/3: cloudflare-quic.com (which offers HTTP/3) is fetched several times, in two
  visits so the Alt-Svc advertisement is known. The trace's `http=` line is the protocol the server
  saw. Neither proxy can carry UDP, so `http/3` in a proxied profile means that request went
  around the proxy. The profile without a proxy must see HTTP/3, or the check proves nothing.
* WebRTC: an RTCPeerConnection gathers candidates against public STUN servers. A server-reflexive
  (`srflx`) candidate in a proxied profile means the STUN request went out over UDP outside the
  proxy (it reveals the address the network sees, not the proxy's). The proxied profiles store
  "unrestricted": a proxy must turn WebRTC off anyway (`effectiveWebRTCPolicy`).

Both proxies run on this machine, so the address a site sees is the same either way; what counts
is whether the traffic passed through the proxy. Measured on macOS 26 (CI): HTTP/3 without a
proxy, HTTP/2 through either proxy (CFNetwork does not use QUIC with a data store's proxy), and a
STUN request around the proxy while WebRTC was allowed. Exit code 1 only if a proxied profile
leaked: a site or STUN server being down makes the result inconclusive (a warning), never a leak.
"""
import argparse
import json
import os
import socket
import struct
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from live_compare import run_app  # noqa: E402

# A small page on an HTTP/3 site: no third-party resources to wait for.
QUIC_SITE = "https://cloudflare-quic.com/cdn-cgi/trace"

QUIC_SCRIPT = r"""
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const protocols = [];
for (let i = 0; i < 6; i++) {
  try {
    const response = await fetch('/cdn-cgi/trace?n=' + i + '-' + Date.now(), { cache: 'no-store' });
    const match = /^http=(.*)$/m.exec(await response.text());
    protocols.push(match ? match[1] : 'no http= line');
  } catch (e) {
    protocols.push('error: ' + e.message);
  }
  await sleep(700);
}
const navigation = performance.getEntriesByType('navigation')[0];
return {
  protocols,
  navigation: navigation ? navigation.nextHopProtocol : null,
  resources: performance.getEntriesByType('resource')
    .filter((entry) => entry.name.includes('/cdn-cgi/trace')).map((entry) => entry.nextHopProtocol),
};
"""

WEBRTC_SCRIPT = r"""
if (typeof RTCPeerConnection !== 'function') return { available: false };
const pc = new RTCPeerConnection({ iceServers: [{ urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] }] });
const candidates = [];
pc.onicecandidate = (event) => { if (event.candidate && event.candidate.candidate) candidates.push(event.candidate.candidate); };
pc.createDataChannel('probe');
await pc.setLocalDescription(await pc.createOffer());
await new Promise((resolve) => {
  const timer = setTimeout(resolve, 8000);
  pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') { clearTimeout(timer); resolve(); } };
});
pc.close();
// No addresses in the report: only the candidate types and transports.
return {
  available: true,
  candidates: candidates.map((c) => { const p = c.split(' '); return p[2].toLowerCase() + ' ' + (/ typ (\w+)/.exec(c) || [])[1]; }),
  srflx: candidates.filter((c) => / typ srflx/.test(c)).length,
};
"""


class ForwardingProxy:
    """An HTTP CONNECT and a SOCKS5 (CONNECT only) proxy that really forward, logging each request.
    Neither carries UDP: a SOCKS5 UDP ASSOCIATE is logged and refused."""

    def __init__(self):
        self.requests = []
        self.lock = threading.Lock()
        self.http_port = self.listen(self.serve_http)
        self.socks_port = self.listen(self.serve_socks)

    def listen(self, handler):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(128)
        threading.Thread(target=self.accept, args=(server, handler), daemon=True).start()
        return server.getsockname()[1]

    def accept(self, server, handler):
        while True:
            client, _ = server.accept()
            threading.Thread(target=self.serve, args=(client, handler), daemon=True).start()

    def serve(self, client, handler):
        try:
            handler(client)
        except (OSError, EOFError, ValueError):
            pass
        finally:
            client.close()

    def note(self, kind, command, target):
        with self.lock:
            self.requests.append({"proxy": kind, "command": command, "target": target})

    def serve_http(self, client):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                return
            data += chunk
        head, rest = data.split(b"\r\n\r\n", 1)
        method, target = head.split(b"\r\n")[0].decode("latin-1").split()[:2]
        self.note("http", method, target)
        if method != "CONNECT":
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            return
        host, port = target.rsplit(":", 1)
        upstream = socket.create_connection((host.strip("[]"), int(port)), timeout=20)
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        if rest:
            upstream.sendall(rest)
        self.pipe(client, upstream)

    def serve_socks(self, client):
        def exact(count):
            data = b""
            while len(data) < count:
                chunk = client.recv(count - len(data))
                if not chunk:
                    raise EOFError
                data += chunk
            return data

        _, methods = exact(2)
        exact(methods)
        client.sendall(b"\x05\x00")
        _, command, _, address_type = exact(4)
        if address_type == 1:
            host = socket.inet_ntop(socket.AF_INET, exact(4))
        elif address_type == 3:
            host = exact(exact(1)[0]).decode("idna")
        elif address_type == 4:
            host = socket.inet_ntop(socket.AF_INET6, exact(16))
        else:
            return
        port = struct.unpack(">H", exact(2))[0]
        self.note("socks", {1: "CONNECT", 2: "BIND", 3: "UDP ASSOCIATE"}.get(command, str(command)), f"{host}:{port}")
        if command != 1:
            client.sendall(b"\x05\x07\x00\x01" + bytes(6))  # command not supported
            return
        upstream = socket.create_connection((host, port), timeout=20)
        client.sendall(b"\x05\x00\x00\x01" + bytes(6))
        self.pipe(client, upstream)

    @staticmethod
    def pipe(client, upstream):
        client.settimeout(None)
        upstream.settimeout(None)

        def copy(source, destination):
            try:
                while True:
                    chunk = source.recv(65536)
                    if not chunk:
                        break
                    destination.sendall(chunk)
            except OSError:
                pass
            finally:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        back = threading.Thread(target=copy, args=(upstream, client), daemon=True)
        back.start()
        copy(client, upstream)
        back.join(120)
        upstream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the unsandboxed PrivacyBrowser.app")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    # One proxy pair per proxied profile, so each log belongs to one profile.
    proxies = {"http-proxy": ForwardingProxy(), "socks-proxy": ForwardingProxy()}
    profiles = [
        {"name": "direct", "webRTC": "unrestricted"},
        {"name": "http-proxy", "webRTC": "unrestricted",
         "proxy": {"kind": "httpConnect", "host": "127.0.0.1", "port": proxies["http-proxy"].http_port}},
        {"name": "socks-proxy", "webRTC": "unrestricted",
         "proxy": {"kind": "socks5", "host": "127.0.0.1", "port": proxies["socks-proxy"].socks_port}},
    ]
    pages = [
        {"name": "quic", "url": QUIC_SITE, "script": QUIC_SCRIPT, "settleMs": 500, "timeoutMs": 60000},
        {"name": "quic-again", "url": QUIC_SITE, "script": QUIC_SCRIPT, "settleMs": 500, "timeoutMs": 60000},
        {"name": "webrtc", "url": QUIC_SITE, "script": WEBRTC_SCRIPT, "timeoutMs": 30000},
    ]
    spec = {"window": {"width": 1000, "height": 600}, "profiles": profiles, "pages": pages}
    results = run_app(os.path.abspath(args.app), spec, os.path.abspath(os.path.join(args.out, "profiles")))
    if not results:
        print("::warning::leak check: nothing measured")
        return 0

    def quic_protocols(result):
        seen = []
        for page in ("quic", "quic-again"):
            value = result.get(page)
            if isinstance(value, dict):
                seen += value.get("protocols") or []
                seen += [p for p in value.get("resources") or [] if p]
        return seen

    control = quic_protocols(results.get("direct", {}))
    control_h3 = any(p in ("http/3", "h3") for p in control)
    report = {}
    for profile in profiles:
        name = profile["name"]
        result = results.get(name, {})
        seen = quic_protocols(result)
        webrtc = result.get("webrtc") if isinstance(result.get("webrtc"), dict) else {}
        proxied = name in proxies
        log = proxies[name].requests if proxied else []
        through_proxy = sum(1 for r in log if "cloudflare-quic.com" in r["target"])
        udp_requests = [r for r in log if r["command"] == "UDP ASSOCIATE"]
        quic_bypass = proxied and any(p in ("http/3", "h3") for p in seen)
        stun_bypass = proxied and (webrtc.get("srflx") or 0) > 0
        report[name] = {"proxied": proxied, "protocols": seen, "webrtc": webrtc,
                        "proxyRequestsToSite": through_proxy, "proxyUdpAssociate": len(udp_requests),
                        "proxyLog": log, "quicBypassesProxy": quic_bypass, "stunBypassesProxy": stun_bypass}
        print(f"::group::[{name}] protocols {seen}, WebRTC {webrtc}, proxy saw {through_proxy} request(s) to the site")
        for request in log:
            print(f"  {request['proxy']} {request['command']} {request['target']}")
        print("::endgroup::")
        if proxied:
            quic = ("BYPASSES THE PROXY (HTTP/3 over UDP)" if quic_bypass else
                    "stays on the proxy" if control_h3 and seen else "inconclusive (no HTTP/3 without a proxy, or no answer)")
            if webrtc.get("available") is False:
                rtc = "no RTCPeerConnection (nothing to leak)"
            else:
                rtc = "STUN BYPASSES THE PROXY (srflx candidate)" if stun_bypass else "no srflx candidate"
            print(f"LEAK-CHECK [{name}] QUIC: {quic}; WebRTC: {rtc}")
        else:
            print(f"LEAK-CHECK [{name}] control: HTTP/3 {'seen' if control_h3 else 'not seen'}, "
                  f"WebRTC srflx {webrtc.get('srflx')}")
    with open(os.path.join(args.out, "leaks.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=1, sort_keys=True)
    leaked = [name for name, r in report.items() if r["quicBypassesProxy"] or r["stunBypassesProxy"]]
    if leaked:
        print(f"::error::traffic went around the proxy in: {', '.join(leaked)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
