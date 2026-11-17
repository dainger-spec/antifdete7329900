#!/usr/bin/env python3
"""Does anything of a profile on a VLESS, VMess, Trojan or Shadowsocks link go around the link?
Measured on a Mac, inside a capture of every packet (docs/TUNNEL.md, "Links").

    python3 -I scripts/xray_leak_check.py --app build/xray/Lumen.app --out build/xray-leaks [--quic-site URL]

Needs sudo (tcpdump on pktap), macOS, and an app built with the links' relay (`XRAY=1`).

1. Servers, all on this Mac: one Xray server (the app's own pinned Xray, copied as `xray-server` so
   the capture tells it from the relay) listening on this Mac's own network address — not loopback,
   so that every packet between a profile's relay and its server is in the capture — with an inbound
   for VLESS + REALITY + vision, VLESS + TLS + WebSocket, VMess + WebSocket, Trojan + TLS and
   Shadowsocks 2022 (REALITY's target and the TLS certificate made for the run). The server's only
   way out is the self-test proxy (scripts/selftest_proxy.py `--socks-udp`), which answers every page
   and STUN request itself and connects nowhere — but for `--quic-site`'s host, which the server
   lets out to the Internet (a page that offers HTTP/3).
2. `Lumen --xray-check` (XrayCheck.swift) starts a profile on each link the way the app does — its
   own process, its relay started by the app, the profile held to it — loads the leak page, makes a
   WebRTC call, knocks on the relay's door, and kills one relay to see the profile fail closed.
3. The capture, read here. It fails on:
   * any packet of a profile's process, or sent on its behalf (pktap `proc`/`eproc`), to anything
     but loopback — at any time: such a process has nothing else to talk to;
   * any packet of a relay (`LumenXray`, by pid) to or from anything but its server's address and port;
   * any DNS question carrying the run's token, or under leak.example.com — a name a page asked for
     that was resolved on this Mac instead of at the far end of the link;
   * any packet to a documentation address (the leak page's own targets);
   and on its controls not being there: the DNS question the check asks on purpose for a name with
   the token (the capture sees questions), and the relays' own packets to their servers, counted for
   the relay's pid (the capture sees the relays and tells processes apart). A control missing is
   SKIPPED, and fails the run: a capture that could not see is never a pass.

Exit 1 on any leak, any check of the app failing, or any control missing.
"""
import argparse
import base64
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from egress_check import FLOW, PORT, QUESTION, parse  # noqa: E402
from xray_relay_check import TLSTarget, free_port, links, make_material, wait_for_port  # noqa: E402

DOCUMENTATION = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32")]
# The kinds the app is checked with: every protocol, REALITY and TLS, two transports.
CHECKED = ["reality-vision", "tls-ws", "vmess-ws", "trojan-tls", "ss2022"]
FAIL_CLOSED = "reality-vision"
SELFTEST = {"http": 18080, "socks": 18081, "canary": 18087, "socks-udp": 18089}


def own_address():
    """This Mac's address on its default route (a UDP socket's, connected nowhere: nothing is sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]


def server_config(material, target, ports, address, quic_host):
    tls = {"certificates": [{"certificate": material["cert"]["certificate"], "key": material["cert"]["key"]}],
           "alpn": ["h2", "http/1.1"]}
    reality = {"target": "127.0.0.1:%d" % target.port, "serverNames": ["reality.example"], "privateKey": material["private"],
               "shortIds": ["", "6ba85179e30d4fc2"]}
    vless = {"clients": [{"id": material["id"]}], "decryption": "none"}
    vless_vision = {"clients": [{"id": material["id"], "flow": "xtls-rprx-vision"}], "decryption": "none"}

    def inbound(tag, protocol, settings, stream):
        return {"tag": tag, "listen": address, "port": ports[tag], "protocol": protocol, "settings": settings,
                "streamSettings": stream}

    inbounds = [
        inbound("reality-vision", "vless", vless_vision, {"network": "raw", "security": "reality", "realitySettings": reality}),
        inbound("reality-xhttp", "vless", vless, {"network": "xhttp", "xhttpSettings": {"path": "/xh"}, "security": "reality",
                                                   "realitySettings": reality}),
        inbound("tls-vision", "vless", vless_vision, {"network": "raw", "security": "tls", "tlsSettings": tls}),
        inbound("tls-ws", "vless", vless, {"network": "ws", "wsSettings": {"path": "/ws"}, "security": "tls", "tlsSettings": tls}),
        inbound("tls-grpc", "vless", vless, {"network": "grpc", "grpcSettings": {"serviceName": "svc"}, "security": "tls",
                                              "tlsSettings": tls}),
        inbound("vmess-ws", "vmess", {"clients": [{"id": material["id"]}]}, {"network": "ws", "wsSettings": {"path": "/vm"}}),
        inbound("trojan-tls", "trojan", {"clients": [{"password": material["trojan"]}]},
                {"network": "raw", "security": "tls", "tlsSettings": tls}),
        inbound("ss2022", "shadowsocks", {"method": "2022-blake3-aes-128-gcm", "password": material["ss"], "network": "tcp,udp"},
                {"network": "raw"}),
    ]
    rules = []
    if quic_host:
        rules.append({"type": "field", "domain": ["full:" + quic_host], "outboundTag": "internet"})
    return {
        "log": {"loglevel": "warning"},
        "inbounds": inbounds,
        # The server side: the self-test proxy, by name — it answers everything itself.
        "outbounds": [
            {"tag": "selftest", "protocol": "socks", "settings": {"address": "127.0.0.1", "port": SELFTEST["socks-udp"]}},
            {"tag": "internet", "protocol": "freedom"},
        ],
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }


def read_check_log(path):
    marks = {"windows": [], "pids": set(), "relays": {}, "token": None, "controls": [], "process": None, "killed": []}
    begin = {}
    with open(path, errors="replace") as handle:
        for line in handle:
            words = line.split()
            if len(words) < 3 or words[0] != "XRAY-CHECK" or words[1] != "INFO":
                continue
            kind = words[2]
            if kind == "egress-window" and len(words) >= 5:
                name = words[5] if len(words) > 5 else ""
                if words[3] == "begin":
                    begin[name] = float(words[4])
                elif words[3] == "end" and name in begin:
                    marks["windows"].append((name, begin.pop(name), float(words[4])))
            elif kind == "egress-pid" and len(words) >= 4:
                marks["pids"].add(int(words[3]))
            elif kind == "xray-relay-pid" and len(words) >= 5:
                marks["relays"][int(words[3])] = words[4]
            elif kind == "egress-token":
                marks["token"] = words[3]
            elif kind == "egress-control":
                marks["controls"].append(words[3])
            elif kind == "egress-process" and len(words) >= 5:
                marks["process"] = (words[3], int(words[4]))
            elif kind == "egress-relay-killed":
                marks["killed"].append(float(words[3]))
    return marks


def analyse(capture, marks, server_address, server_ports, out):
    leaks, listed = [], []
    relay_seen = {}
    controls_seen = set()
    token = marks["token"] or "\u0000"
    profile_pids = marks["pids"]
    relay_pids = set(marks["relays"])
    packets = 0
    with_metadata = 0
    with open(capture, errors="replace") as handle:
        for line in handle:
            packet = parse(line)
            if packet["time"] is None:
                continue
            packets += 1
            proc, eproc = packet["proc"], packet["eproc"]
            if proc:
                with_metadata += 1
            pids = {p[1] for p in (proc, eproc) if p}
            text = packet["line"]
            for question in QUESTION.findall(text):
                name = question.lower().rstrip(".")
                if name in marks["controls"]:
                    controls_seen.add(name)
                elif token in name or name.endswith("leak.example.com"):
                    leaks.append("a DNS question for %s, resolved on this Mac and not at the link's far end: %s" % (name, text))
            dst, src = packet["dst"], packet["src"]
            if dst is not None and any(dst in network for network in DOCUMENTATION):
                leaks.append("a packet to a documentation address (the leak page's own targets): %s" % text)
            if pids & profile_pids:
                leaks.append("a packet of a profile's process, or sent for it, to something other than loopback: %s" % text)
                continue
            relay = pids & relay_pids
            if relay:
                flow = FLOW.search(text)
                source_port = PORT.search(flow.group(1)) if flow else None
                source_port = int(source_port.group(1)) if source_port else None
                # Its way to its server, and the server's answers: the server's address and one of its ports.
                to_server = str(dst) == server_address and packet["dst_port"] in server_ports
                from_server = str(src) == server_address and source_port in server_ports
                if to_server or from_server:
                    for pid in relay:
                        relay_seen[pid] = relay_seen.get(pid, 0) + 1
                else:
                    leaks.append("a packet of a relay (pid %s) to something other than its server: %s" % (sorted(relay)[0], text))
    return {"packets": packets, "with_metadata": with_metadata, "leaks": leaks, "relay_seen": relay_seen,
            "controls_seen": controls_seen, "listed": listed}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--quic-site", default="https://cloudflare-quic.com/cdn-cgi/trace")
    options = parser.parse_args()
    os.makedirs(options.out, exist_ok=True)
    app = os.path.abspath(options.app)
    relay = os.path.join(app, "Contents", "MacOS", "LumenXray")
    if not os.access(relay, os.X_OK):
        sys.exit("XRAY-LEAK FAIL the app has no links' relay (Contents/MacOS/LumenXray): build it with XRAY=1")
    server_binary = os.path.join(options.out, "xray-server")
    shutil.copy(relay, server_binary)
    address = own_address()
    print("XRAY-LEAK INFO this Mac's address for the servers: %s" % address)
    processes = []
    status = 0
    try:
        # The self-test proxy: the servers' only way out, answering every page itself.
        proxy_log = open(os.path.join(options.out, "selftest-proxy.log"), "w")
        proxy = subprocess.Popen([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "selftest_proxy.py"),
                                  "--http", str(SELFTEST["http"]), "--socks", str(SELFTEST["socks"]), "--canary", str(SELFTEST["canary"]),
                                  "--socks-udp", str(SELFTEST["socks-udp"]), "--aia-tag", "x%d" % int(time.time())],
                                 stdout=proxy_log, stderr=subprocess.STDOUT)
        processes.append(proxy)
        if not wait_for_port(SELFTEST["socks-udp"], 30):
            sys.exit("XRAY-LEAK FAIL the self-test proxy did not listen")
        work = os.path.join(options.out, "material")
        os.makedirs(work, exist_ok=True)
        material = make_material(server_binary, work)
        target = TLSTarget(material["cert_file"], material["key_file"])
        tags = ["reality-vision", "reality-xhttp", "tls-vision", "tls-ws", "tls-grpc", "vmess-ws", "trojan-tls", "ss2022"]
        ports = {tag: free_port() for tag in tags}
        quic_host = re.sub(r"^https?://([^/:]+).*$", r"\1", options.quic_site) if options.quic_site else None
        config = server_config(material, target, ports, address, quic_host)
        server_log = open(os.path.join(options.out, "server.log"), "w")
        server = subprocess.Popen([server_binary, "run", "-c", "stdin:"], stdin=subprocess.PIPE, stdout=server_log,
                                  stderr=subprocess.STDOUT, env={"PATH": "/usr/bin:/bin"})
        processes.append(server)
        server.stdin.write(json.dumps(config).encode())
        server.stdin.close()
        for tag in tags:
            deadline = time.time() + 15
            while time.time() < deadline:
                try:
                    socket.create_connection((address, ports[tag]), timeout=0.5).close()
                    break
                except OSError:
                    time.sleep(0.2)
            else:
                sys.exit("XRAY-LEAK FAIL the server did not listen for %s" % tag)
        made = {tag: link.replace("@127.0.0.1:", "@%s:" % address) for tag, link in links(material, ports)}
        # VMess's link is base64 of JSON: made again with this Mac's address.
        vmess = {"v": "2", "ps": "vmess-ws", "add": address, "port": str(ports["vmess-ws"]), "id": material["id"], "aid": "0",
                 "scy": "auto", "net": "ws", "path": "/vm", "tls": ""}
        made["vmess-ws"] = "vmess://" + base64.b64encode(json.dumps(vmess).encode()).decode()
        spec = {"links": [{"name": tag, "link": made[tag]} for tag in CHECKED], "httpProxyPort": SELFTEST["http"],
                "exitTrace": "http://exit.selftest.invalid/cdn-cgi/trace", "failClosed": FAIL_CLOSED}
        if options.quic_site:
            spec["quicSite"] = options.quic_site
        spec_path = os.path.join(options.out, "spec.json")
        with open(spec_path, "w") as handle:
            json.dump(spec, handle)
        os.chmod(spec_path, 0o600)

        capture_path = os.path.join(options.out, "capture.txt")
        capture = subprocess.Popen(["sudo", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l", "-s", "256",
                                    "not host 127.0.0.1 and not host ::1"],
                                   stdout=open(capture_path, "w"), stderr=open(os.path.join(options.out, "tcpdump.err"), "w"))
        time.sleep(3)
        check_path = os.path.join(options.out, "check.txt")
        environment = dict(os.environ, PB_GEO_SERVICES_OFF="1")
        with open(check_path, "w") as log:
            check = subprocess.Popen([os.path.join(app, "Contents", "MacOS", "Lumen"), "--xray-check", spec_path],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment, text=True)
            for line in check.stdout:
                log.write(line)
                if line.startswith("XRAY-CHECK"):
                    print(line.rstrip())
            check.wait()
        if check.returncode != 0:
            status = 1
            print("XRAY-LEAK FAIL Lumen --xray-check exited %d" % check.returncode)
        time.sleep(2)
        subprocess.run(["sudo", "pkill", "-INT", "-f", "tcpdump -i pktap"], check=False)
        capture.wait(timeout=20)

        marks = read_check_log(check_path)
        result = analyse(capture_path, marks, address, set(ports.values()), options.out)
        print("XRAY-LEAK INFO capture: %d packets, %d with the process they belong to; profiles %s, relays %s"
              % (result["packets"], result["with_metadata"], sorted(marks["pids"]), marks["relays"]))
        for leak in result["leaks"][:40]:
            print("XRAY-LEAK FAIL %s" % leak[:600])
        if result["leaks"]:
            status = 1
            print("XRAY-LEAK FAIL %d packet(s) went around a link" % len(result["leaks"]))
        else:
            print("XRAY-LEAK PASS no packet of a profile's process off loopback; every relay's packet to its server; "
                  "no name of a page resolved on this Mac; nothing to a documentation address")
        # The controls: what the capture must see, or it proves nothing.
        missing = [name for name in marks["controls"] if name not in result["controls_seen"]]
        if not marks["controls"] or missing:
            status = 1
            print("XRAY-LEAK SKIPPED the capture did not see the DNS question asked on purpose (%s): it cannot tell a name "
                  "resolved on this Mac" % (", ".join(missing) or "none asked"))
        else:
            print("XRAY-LEAK PASS the control: the capture sees this Mac's DNS questions (%s)" % ", ".join(marks["controls"]))
        unseen = [pid for pid in marks["relays"] if pid not in result["relay_seen"]]
        if not marks["relays"] or unseen:
            status = 1
            print("XRAY-LEAK SKIPPED the capture did not see every relay's packets to its server, counted for it (%s): "
                  "it cannot tell a relay's packets apart" % (", ".join("%d %s" % (p, marks["relays"][p]) for p in unseen) or "no relay"))
        else:
            print("XRAY-LEAK PASS the control: each relay's packets to its server are in the capture, counted for it (%s)"
                  % ", ".join("%s %d" % (marks["relays"][p], n) for p, n in result["relay_seen"].items()))
        if result["with_metadata"] == 0:
            status = 1
            print("XRAY-LEAK SKIPPED no packet of the capture names its process (pktap): nothing could be told")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
    print("XRAY-LEAK %s" % ("PASSED" if status == 0 else "FAILED"))
    sys.exit(status)


if __name__ == "__main__":
    main()
