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
  "unrestricted": without the tunnel a proxy must turn WebRTC off (`webRTCRouting`).
* WebRTC through the relay: one SOCKS5 profile runs the packet tunnel's TURN server and SOCKS5
  relay on a UDP socket of this Mac (`--capture-sites` "relay": "harness"; CI cannot load the
  Network Extension itself). Its pages must get relay candidates only, at the proxy's public
  address, and the proxy must see their UDP (UDP ASSOCIATE). Two peer connections in the page
  then open a data channel to each other through the relay and the proxy (the test proxy plays
  the NAT hairpin a real proxy's public address would need).

Both proxies run on this machine, so the address a site sees is the same either way; what counts
is whether the traffic passed through the proxy. Measured on macOS 26 (CI): HTTP/3 without a
proxy, HTTP/2 through either proxy (CFNetwork does not use QUIC with a data store's proxy), and a
STUN request around the proxy while WebRTC was allowed. Exit code 1 only if a proxied profile
leaked: a site or STUN server being down makes the result inconclusive (a warning), never a leak.
"""
import argparse
import json
import os
import select
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
let traceIP = null;
try { traceIP = (/^ip=(.*)$/m.exec(await (await fetch('/cdn-cgi/trace', { cache: 'no-store' })).text()) || [])[1]; } catch (e) {}
const relayAddresses = candidates.filter((c) => / typ relay/.test(c)).map((c) => c.split(' ')[4]);
// No addresses in the report: only the candidate types and transports, and whether relay
// candidates carry the address the site sees through the proxy.
return {
  available: true,
  candidates: candidates.map((c) => { const p = c.split(' '); return p[2].toLowerCase() + ' ' + (/ typ (\w+)/.exec(c) || [])[1]; }),
  srflx: candidates.filter((c) => / typ srflx/.test(c)).length,
  host: candidates.filter((c) => / typ host/.test(c)).length,
  relay: relayAddresses.length,
  relayIsProxyAddress: relayAddresses.length > 0 && relayAddresses.every((a) => a === traceIP),
};
"""

LOOP_SCRIPT = r"""
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
const channel = a.createDataChannel('through-the-proxy');
const timeout = (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms));
const received = new Promise((resolve) => { b.ondatachannel = (e) => { e.channel.onmessage = (m) => resolve(m.data); }; });
const opened = new Promise((resolve) => { channel.onopen = () => resolve(true); });
await a.setLocalDescription(await a.createOffer());
await b.setRemoteDescription(a.localDescription);
await b.setLocalDescription(await b.createAnswer());
await a.setRemoteDescription(b.localDescription);
const open = await Promise.race([opened, timeout(20000, false)]);
if (open) channel.send('ping-through-proxy');
const message = open ? await Promise.race([received, timeout(10000, null)]) : null;
const result = { available: true, open, delivered: message === 'ping-through-proxy', ice: a.iceConnectionState,
                 candidateTypes: [...new Set(types)].sort() };
a.close(); b.close();
return result;
"""


class ForwardingProxy:
    """An HTTP CONNECT and a SOCKS5 proxy that really forward, logging each request. With
    `udp=True` the SOCKS5 side also does UDP ASSOCIATE (RFC 1928 §7), as a proxy that carries
    WebRTC must; otherwise UDP ASSOCIATE is logged and refused."""

    # Public address (learned from STUN answers) → association: datagrams one association sends to
    # another's public address are delivered to it, as a NAT that supports hairpinning would.
    hairpin = {}
    hairpin_lock = threading.Lock()

    def __init__(self, udp=False):
        self.requests = []
        self.udp_datagrams = 0
        self.lock = threading.Lock()
        self.udp = udp
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
        if command == 3 and self.udp:
            UDPAssociation(self, client).run()
            return
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


STUN_COOKIE = 0x2112A442


def stun_mapped_address(payload):
    """The XOR-MAPPED-ADDRESS of a STUN Binding success response, as (ip, port), or None."""
    if len(payload) < 20 or payload[0:2] != b"\x01\x01" or struct.unpack(">I", payload[4:8])[0] != STUN_COOKIE:
        return None
    offset = 20
    while offset + 4 <= len(payload):
        kind, length = struct.unpack(">HH", payload[offset:offset + 4])
        value = payload[offset + 4:offset + 4 + length]
        if kind == 0x0020 and len(value) >= 8:
            port = struct.unpack(">H", value[2:4])[0] ^ (STUN_COOKIE >> 16)
            mask = struct.pack(">I", STUN_COOKIE) + payload[8:20]
            raw = bytes(x ^ y for x, y in zip(value[4:], mask))
            family = socket.AF_INET if value[1] == 1 else socket.AF_INET6
            return socket.inet_ntop(family, raw), port
        offset += 4 + ((length + 3) & ~3)
    return None


class UDPAssociation:
    """One SOCKS5 UDP association: a relay socket for the client on 127.0.0.1, and sockets to the
    Internet; it lives as long as the control connection (RFC 1928 §7)."""

    def __init__(self, proxy, control):
        self.proxy = proxy
        self.control = control
        self.inner = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.inner.bind(("127.0.0.1", 0))
        self.outer = {socket.AF_INET: socket.socket(socket.AF_INET, socket.SOCK_DGRAM)}
        self.outer[socket.AF_INET].bind(("0.0.0.0", 0))
        try:
            v6 = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
            v6.bind(("::", 0))
            self.outer[socket.AF_INET6] = v6
        except OSError:
            pass
        self.client = None
        self.public = set()
        self.destinations = set()

    @staticmethod
    def header(ip, port):
        if ":" in ip:
            return b"\x00\x00\x00\x04" + socket.inet_pton(socket.AF_INET6, ip) + struct.pack(">H", port)
        return b"\x00\x00\x00\x01" + socket.inet_aton(ip) + struct.pack(">H", port)

    def deliver(self, data, source):
        """A datagram for this association's client, from `source` (ip, port)."""
        if self.client:
            self.inner.sendto(self.header(*source) + data, self.client)

    def run(self):
        port = self.inner.getsockname()[1]
        self.control.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", port))
        sockets = [self.control, self.inner] + list(self.outer.values())
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], 120)
                if not readable:
                    break
                for sock in readable:
                    if sock is self.control:
                        if not self.control.recv(1024):
                            return
                    elif sock is self.inner:
                        self.from_client(*sock.recvfrom(65535))
                    else:
                        self.from_internet(*sock.recvfrom(65535))
        finally:
            with ForwardingProxy.hairpin_lock:
                for address in self.public:
                    ForwardingProxy.hairpin.pop(address, None)
            for sock in [self.inner] + list(self.outer.values()):
                sock.close()

    def from_client(self, datagram, address):
        if self.client is None:
            self.client = address
        if address != self.client or len(datagram) < 10 or datagram[2] != 0:
            return  # another sender, or a fragment
        atyp = datagram[3]
        if atyp == 1:
            host, rest = socket.inet_ntoa(datagram[4:8]), datagram[8:]
        elif atyp == 4:
            host, rest = socket.inet_ntop(socket.AF_INET6, datagram[4:20]), datagram[20:]
        elif atyp == 3:
            length = datagram[4]
            host, rest = datagram[5:5 + length].decode("idna"), datagram[5 + length:]
        else:
            return
        port, payload = struct.unpack(">H", rest[:2])[0], rest[2:]
        if (host, port) not in self.destinations:
            self.destinations.add((host, port))
            self.proxy.note("socks", "UDP", f"{host}:{port}")
        with self.proxy.lock:
            self.proxy.udp_datagrams += 1
        try:
            family, _, _, _, target = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)[0]
        except OSError:
            return
        with ForwardingProxy.hairpin_lock:
            peer = ForwardingProxy.hairpin.get((target[0], target[1]))
        if peer is not None and self.public:
            source = sorted(self.public)[0]
            peer.deliver(payload, source)
            return
        sock = self.outer.get(family)
        if sock is not None:
            try:
                sock.sendto(payload, target)
            except OSError:
                pass

    def from_internet(self, payload, address):
        mapped = stun_mapped_address(payload)
        if mapped:
            self.public.add(mapped)
            with ForwardingProxy.hairpin_lock:
                ForwardingProxy.hairpin[mapped] = self
        self.deliver(payload, (address[0], address[1]))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the unsandboxed PrivacyBrowser.app")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    # One proxy pair per proxied profile, so each log belongs to one profile.
    proxies = {"http-proxy": ForwardingProxy(), "socks-proxy": ForwardingProxy(), "socks-relay": ForwardingProxy(udp=True)}
    profiles = [
        {"name": "direct", "webRTC": "unrestricted"},
        {"name": "http-proxy", "webRTC": "unrestricted",
         "proxy": {"kind": "httpConnect", "host": "127.0.0.1", "port": proxies["http-proxy"].http_port}},
        {"name": "socks-proxy", "webRTC": "unrestricted",
         "proxy": {"kind": "socks5", "host": "127.0.0.1", "port": proxies["socks-proxy"].socks_port}},
        # WebRTC through the packet tunnel's relay (run outside the tunnel) and a UDP-capable proxy.
        {"name": "socks-relay", "webRTC": "unrestricted", "relay": "harness",
         "proxy": {"kind": "socks5", "host": "127.0.0.1", "port": proxies["socks-relay"].socks_port}},
    ]
    pages = [
        {"name": "quic", "url": QUIC_SITE, "script": QUIC_SCRIPT, "settleMs": 500, "timeoutMs": 60000},
        {"name": "quic-again", "url": QUIC_SITE, "script": QUIC_SCRIPT, "settleMs": 500, "timeoutMs": 60000},
        {"name": "webrtc", "url": QUIC_SITE, "script": WEBRTC_SCRIPT, "timeoutMs": 30000},
        {"name": "webrtc-loop", "url": QUIC_SITE, "script": LOOP_SCRIPT, "timeoutMs": 45000},
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
    warnings = []
    for profile in profiles:
        name = profile["name"]
        result = results.get(name, {})
        seen = quic_protocols(result)
        webrtc = result.get("webrtc") if isinstance(result.get("webrtc"), dict) else {}
        loop = result.get("webrtc-loop") if isinstance(result.get("webrtc-loop"), dict) else {}
        proxied = name in proxies
        proxy = proxies.get(name)
        log = proxy.requests if proxy else []
        through_proxy = sum(1 for r in log if "cloudflare-quic.com" in r["target"])
        udp_associations = sum(1 for r in log if r["command"] == "UDP ASSOCIATE")
        quic_bypass = proxied and any(p in ("http/3", "h3") for p in seen)
        # Through a proxy, a page may only ever see relay candidates: srflx means STUN left from
        # this Mac's address, host means WebKit gathered on its own interfaces.
        stun_bypass = proxied and ((webrtc.get("srflx") or 0) > 0 or (webrtc.get("host") or 0) > 0
                                   or any(t in ("srflx", "host", "prflx") for t in loop.get("candidateTypes") or []))
        report[name] = {"proxied": proxied, "protocols": seen, "webrtc": webrtc, "loop": loop,
                        "proxyRequestsToSite": through_proxy, "proxyUdpAssociations": udp_associations,
                        "proxyUdpDatagrams": proxy.udp_datagrams if proxy else 0,
                        "proxyLog": log, "quicBypassesProxy": quic_bypass, "stunBypassesProxy": stun_bypass}
        print(f"::group::[{name}] protocols {seen}, WebRTC {webrtc}, loop {loop}, proxy saw {through_proxy} request(s) to the site")
        for request in log:
            print(f"  {request['proxy']} {request['command']} {request['target']}")
        if proxy and proxy.udp:
            print(f"  {proxy.udp_datagrams} UDP datagram(s) relayed")
        print("::endgroup::")
        if not proxied:
            print(f"LEAK-CHECK [{name}] control: HTTP/3 {'seen' if control_h3 else 'not seen'}, "
                  f"WebRTC srflx {webrtc.get('srflx')}")
            continue
        quic = ("BYPASSES THE PROXY (HTTP/3 over UDP)" if quic_bypass else
                "stays on the proxy" if control_h3 and seen else "inconclusive (no HTTP/3 without a proxy, or no answer)")
        if stun_bypass:
            rtc = "BYPASSES THE PROXY (srflx/host candidate)"
        elif webrtc.get("available") is False:
            rtc = "no RTCPeerConnection (nothing to leak)"
        elif (webrtc.get("relay") or 0) > 0:
            rtc = (f"relay candidates only ({webrtc.get('relay')}), "
                   f"{'at the proxy address' if webrtc.get('relayIsProxyAddress') else 'NOT at the proxy address'}; "
                   f"{udp_associations} UDP association(s); data channel "
                   f"{'delivered through the proxy' if loop.get('delivered') else 'not delivered (' + str(loop.get('ice')) + ')'}")
            if not webrtc.get("relayIsProxyAddress"):
                warnings.append(f"{name}: relay candidates are not at the proxy's address")
            if not loop.get("delivered"):
                warnings.append(f"{name}: the data channel through the relay did not deliver ({loop})")
        else:
            rtc = "no candidates"
            if profile.get("relay"):
                warnings.append(f"{name}: the relay gave no candidates")
        print(f"LEAK-CHECK [{name}] QUIC: {quic}; WebRTC: {rtc}")
    with open(os.path.join(args.out, "leaks.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=1, sort_keys=True)
    for warning in warnings:
        print(f"::warning::leak check: {warning}")
    leaked = [name for name, r in report.items() if r["quicBypassesProxy"] or r["stunBypassesProxy"]]
    if leaked:
        print(f"::error::traffic went around the proxy in: {', '.join(leaked)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
