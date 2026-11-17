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
   lets out to the Internet (a page that offers HTTP/3). Two more links, REALITY + vision and
   Shadowsocks 2022, name the server by a host name (`xray-server.lumen-xray-check.test`): this Mac's
   resolver is pointed for that domain at a name server of this script (/etc/resolver, taken back at
   the end), so the relay, inside its sandbox, resolves its server's name the way it would a
   provider's — through mDNSResponder — and the name server notes the question.
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
   SKIPPED, and fails the run: a capture that could not see is never a pass. A link by name whose
   server's name was not asked of this Mac's resolver while its profile ran fails too.

Exit 1 on any leak, any check of the app failing, or any control missing.
"""
import argparse
import base64
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from egress_check import DOCUMENTATION, FLOW, PORT, QUESTION, SERVICES, parse  # noqa: E402
from xray_relay_check import TLSTarget, free_port, links, make_material, wait_for_port  # noqa: E402

# The kinds the app is checked with: every protocol, REALITY and TLS, two transports.
CHECKED = ["reality-vision", "tls-ws", "vmess-ws", "trojan-tls", "ss2022"]
FAIL_CLOSED = "reality-vision"
# Links that name their server by a host name, not an address: the relay resolves it, inside its
# sandbox, through this Mac's resolver (mDNSResponder) — as a provider's link with a name would.
# The name is under a domain this Mac's resolver is pointed at a server of this script for
# (/etc/resolver), which answers with this Mac's address and notes every question.
NAME_DOMAIN = "lumen-xray-check.test"
SERVER_NAME = "xray-server." + NAME_DOMAIN
BY_NAME = {"reality-vision-by-name": "reality-vision", "ss2022-by-name": "ss2022"}
SELFTEST = {"http": 18080, "socks": 18081, "canary": 18087, "socks-udp": 18089}


def own_address():
    """This Mac's address on its default route (a UDP socket's, connected nowhere: nothing is sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]


class NameServer:
    """A DNS server on 127.0.0.1 (UDP) for NAME_DOMAIN alone: its names answered with an IPv4 address
    (TTL 0, so that nothing keeps them), anything else of the domain NXDOMAIN; every question noted."""

    def __init__(self, names):
        self.names = {name.lower(): address for name, address in names.items()}
        self.questions = []
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                data, peer = self.sock.recvfrom(4096)
            except OSError:
                return
            try:
                answer = self.answer(data)
            except (IndexError, ValueError):
                continue
            if answer:
                self.sock.sendto(answer, peer)

    def answer(self, data):
        if len(data) < 12 or struct.unpack("!H", data[4:6])[0] != 1:
            return None
        labels, offset = [], 12
        while data[offset]:
            length = data[offset]
            labels.append(data[offset + 1:offset + 1 + length].decode("ascii", "replace"))
            offset += 1 + length
        offset += 1
        qtype, _ = struct.unpack("!HH", data[offset:offset + 4])
        question = data[12:offset + 4]
        name = ".".join(labels).lower()
        self.questions.append((time.time(), name, qtype))
        flags = 0x8180 | (0x0100 & struct.unpack("!H", data[2:4])[0])
        records = b""
        if name not in self.names:
            flags |= 3  # NXDOMAIN
        elif qtype == 1:
            records = struct.pack("!HHHIH", 0xC00C, 1, 1, 0, 4) + socket.inet_aton(self.names[name])
        header = data[:2] + struct.pack("!HHHHH", flags, 1, 1 if records else 0, 0, 0)
        return header + question + records

    def close(self):
        self.sock.close()


def point_resolver(domain, port):
    """This Mac's resolver asks 127.0.0.1:port for names under `domain` (resolver(5)); taken back by
    `unpoint_resolver`."""
    text = "nameserver 127.0.0.1\nport %d\n" % port
    subprocess.run(["sudo", "mkdir", "-p", "/etc/resolver"], check=True)
    subprocess.run(["sudo", "tee", "/etc/resolver/" + domain], input=text.encode(), stdout=subprocess.DEVNULL, check=True)


def unpoint_resolver(domain):
    subprocess.run(["sudo", "rm", "-f", "/etc/resolver/" + domain], check=False)


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


# The relay's process name, as the capture gives it (Contents/MacOS/LumenXray after its exec).
RELAY_NAME = "LumenXray"


def analyse(capture, marks, server_address, server_ports, server_names=()):
    """Every packet of the capture, against what a profile on a link may send (the module's doc).

    The app's processes are told by pid (each profile's, the check's own) and by name (the name the
    check gives for itself: a profile's process runs the same executable); a relay by its pid or its
    name, whichever relay it is — one the check announced, one started again, or one nobody announced."""
    leaks, listed = [], {}
    relay_seen = {}
    controls_seen = {}
    token = marks["token"] or "\u0000"
    profile_pids = marks["pids"]
    relay_pids = set(marks["relays"])
    manager = marks["process"]
    app_names = {manager[0][:16]} if manager else set()
    first_profile_pid = min(profile_pids) if profile_pids else None
    windows = [(begin, end) for _, begin, end in marks["windows"]]
    packets = 0
    with_metadata = 0

    def in_window(packet):
        return any(begin <= packet["time"] <= end for begin, end in windows)

    def relay(owner):
        return owner is not None and (owner[1] in relay_pids or owner[0][:16] == RELAY_NAME[:16])

    def app(owner):
        if owner is None or relay(owner):
            return False
        return owner[1] in profile_pids or (manager is not None and owner[1] == manager[1]) \
            or any(owner[0][:16].startswith(name) for name in app_names)

    def service(owner):
        # A service that was running before the first profile started was not started for it (egress_check).
        return owner is not None and any(name in owner[0] for name in SERVICES) \
            and (first_profile_pid is None or owner[1] >= first_profile_pid)

    with open(capture, errors="replace") as handle:
        for line in handle:
            packet = parse(line)
            if packet["time"] is None:
                continue
            packets += 1
            proc, eproc = packet["proc"], packet["eproc"]
            if proc:
                with_metadata += 1
            text = packet["line"]
            lowered = text.lower()
            names = [question.lower().rstrip(".") for question in QUESTION.findall(text)]
            control = next((name for name in names if name in marks["controls"]), None)
            if control:
                owners = ["%s %s" % (kind, owner[0]) for kind, owner in (("proc", proc), ("eproc", eproc)) if owner]
                controls_seen.setdefault(control, []).append((", ".join(owners) or "no process", app(proc) or app(eproc)))
                continue
            dst, src = packet["dst"], packet["src"]
            if any(token in name or name.endswith("leak.example.com") for name in names):
                leaks.append("a DNS question for a page's name, resolved on this Mac and not at the link's far end: %s" % text)
                continue
            if token in lowered:
                leaks.append("a packet carrying the run's token (a page's request made on this Mac): %s" % text)
                continue
            if dst is not None and any(dst.version == network.version and dst in network for network in DOCUMENTATION):
                leaks.append("a packet to a documentation address (the leak page's own targets): %s" % text)
                continue
            if relay(proc) or relay(eproc):
                flow = FLOW.search(text)
                source_port = PORT.search(flow.group(1)) if flow else None
                source_port = int(source_port.group(1)) if source_port else None
                # Its way to its server, and the server's answers: the server's address and one of its ports.
                to_server = str(dst) == server_address and packet["dst_port"] in server_ports
                from_server = str(src) == server_address and source_port in server_ports
                if to_server or from_server:
                    for owner in (proc, eproc):
                        if relay(owner):
                            relay_seen[owner[1]] = relay_seen.get(owner[1], 0) + 1
                elif names and all(name in server_names for name in names) or packet["dns_answer"]:
                    # The server's own name, asked of this Mac's resolver for the relay: the one name a link asks here.
                    listed.setdefault("the relay's question for its server's name", []).append(text)
                else:
                    who = proc if relay(proc) else eproc
                    leaks.append("a packet of a relay (%s %d) to something other than its server: %s" % (who[0], who[1], text))
                continue
            profile = any(owner is not None and owner[1] in profile_pids for owner in (proc, eproc))
            if profile or (in_window(packet) and (app(proc) or app(eproc))):
                if packet["dns_answer"] and not profile:
                    # An answer is not a packet the app sent; the question would have been, and fails above or here.
                    listed.setdefault("DNS answers to the app", []).append(text)
                elif dst is None or not dst.is_loopback:
                    leaks.append("a packet of the app's process (a profile's, or the check's own while a profile ran), "
                                 "or one sent for it, to something other than loopback: %s" % text)
                continue
            if in_window(packet) and (service(proc) or service(eproc)):
                who = proc[0] if service(proc) else "%s (through %s)" % (eproc[0], proc[0] if proc else "?")
                leaks.append("%s fetched for someone while a profile ran: %s" % (who, text))
                continue
            if in_window(packet) and proc:
                listed.setdefault(proc[0], []).append(text)
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
    pointed = []
    names = None
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
        # The server's name: this Mac's resolver pointed at a name server of this script for its domain,
        # and seen to answer through it (a name of the domain the relay never asks) before anything runs.
        names = NameServer({SERVER_NAME: address, "probe." + NAME_DOMAIN: address})
        point_resolver(NAME_DOMAIN, names.port)
        pointed.append(NAME_DOMAIN)
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                if address in {info[4][0] for info in socket.getaddrinfo("probe." + NAME_DOMAIN, 80, socket.AF_INET)}:
                    break
            except OSError:
                pass
            time.sleep(0.5)
        else:
            sys.exit("XRAY-LEAK FAIL this Mac's resolver did not take the name server for %s (/etc/resolver)" % NAME_DOMAIN)
        print("XRAY-LEAK INFO this Mac's resolver answers %s through the check's name server (port %d)" % (NAME_DOMAIN, names.port))
        made = {tag: link.replace("@127.0.0.1:", "@%s:" % address) for tag, link in links(material, ports)}
        # VMess's link is base64 of JSON: made again with this Mac's address.
        vmess = {"v": "2", "ps": "vmess-ws", "add": address, "port": str(ports["vmess-ws"]), "id": material["id"], "aid": "0",
                 "scy": "auto", "net": "ws", "path": "/vm", "tls": ""}
        made["vmess-ws"] = "vmess://" + base64.b64encode(json.dumps(vmess).encode()).decode()
        for name, tag in BY_NAME.items():
            made[name] = made[tag].replace("@%s:" % address, "@%s:" % SERVER_NAME)
            if SERVER_NAME not in made[name]:
                sys.exit("XRAY-LEAK FAIL the link %s could not be made to name its server" % name)
        spec = {"links": [{"name": tag, "link": made[tag]} for tag in CHECKED + list(BY_NAME)], "httpProxyPort": SELFTEST["http"],
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
        result = analyse(capture_path, marks, address, set(ports.values()), server_names={SERVER_NAME})
        print("XRAY-LEAK INFO capture: %d packets, %d with the process they belong to; profiles %s, relays %s, the check %s, "
              "windows %d" % (result["packets"], result["with_metadata"], sorted(marks["pids"]), marks["relays"], marks["process"],
                              len(marks["windows"])))
        for who, lines in sorted(result["listed"].items(), key=lambda item: -len(item[1])):
            print("XRAY-LEAK INFO listed, not failed on: %s, %d packet(s), e.g. %s" % (who, len(lines), lines[0][:220]))
        for leak in result["leaks"][:40]:
            print("XRAY-LEAK FAIL %s" % leak[:600])
        if result["leaks"]:
            status = 1
            print("XRAY-LEAK FAIL %d packet(s) went around a link" % len(result["leaks"]))
        else:
            print("XRAY-LEAK PASS no packet of a profile's process off loopback, nor of the app's while a profile ran; "
                  "every packet of a relay to or from its server; no name of a page resolved on this Mac; nothing to a "
                  "documentation address; no service fetching for a profile")
        # The controls: what the capture must see, or it proves nothing.
        if not marks["windows"] or marks["process"] is None or not marks["token"]:
            status = 1
            print("XRAY-LEAK SKIPPED the check gave no window, process or token: nothing could be told")
        missing = [name for name in marks["controls"] if name not in result["controls_seen"]]
        if not marks["controls"] or missing:
            status = 1
            print("XRAY-LEAK SKIPPED the capture did not see the DNS question asked on purpose (%s): it cannot tell a name "
                  "resolved on this Mac" % (", ".join(missing) or "none asked"))
        else:
            print("XRAY-LEAK PASS the control: the capture sees this Mac's DNS questions (%s, by %s)"
                  % (", ".join(marks["controls"]), sorted({who for seen in result["controls_seen"].values() for who, _ in seen})))
        if any(named for seen in result["controls_seen"].values() for _, named in seen):
            print("XRAY-LEAK PASS the control: the capture names the app's process on the question it asked (%s): "
                  "the app's own packets are told apart" % marks["process"][0])
        else:
            status = 1
            print("XRAY-LEAK SKIPPED no control packet was named after the app's process (%s): a packet the app sent around "
                  "a link would go unnoticed" % (marks["process"],))
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
        # The links by name: their relay, inside its sandbox, asked this Mac's resolver for the server's
        # name while their profile ran — the question reached the name server — and their checks passed
        # (above, in --xray-check's own lines): the name was resolved, and resolved only by the relay's way.
        for name in BY_NAME:
            spans = [(begin, end) for window, begin, end in marks["windows"] if window == name]
            asked = [q for q in names.questions if q[1] == SERVER_NAME and any(b <= q[0] <= e for b, e in spans)]
            if spans and asked:
                print("XRAY-LEAK PASS %s: its relay resolved %s through this Mac's resolver (%d question(s) while it ran)"
                      % (name, SERVER_NAME, len(asked)))
            else:
                status = 1
                print("XRAY-LEAK FAIL %s: no question for %s reached this Mac's resolver while its profile ran (%s)"
                      % (name, SERVER_NAME, "window seen" if spans else "no window"))
        with open(os.path.join(options.out, "names.txt"), "w") as handle:
            for when, name, qtype in names.questions:
                handle.write("%.3f %s %d\n" % (when, name, qtype))
    finally:
        for domain in pointed:
            unpoint_resolver(domain)
        if names:
            names.close()
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
