#!/usr/bin/env python3
"""Measurement only (never merged): do the owner's SOCKS5 proxies carry UDP, and from which address?

    PB_TEST_PROXIES="host:port:login:password\n…" python3 scripts/measure/proxy_udp.py --out build/proxy-udp \
        [--pubkey scripts/measure/report_key.pub]

For each proxy, in turn (no two measured at once, so their times do not mix):

1. TCP: the SOCKS5 handshake with its login, then CONNECT by name (the proxy resolves it) to two
   address services over plain HTTP — the address a site sees for TCP; and the app's own way
   (ProxyExitLookup): HTTPS to Cloudflare's trace at 1.1.1.1 (then 1.0.0.1), by address.
2. UDP ASSOCIATE: the reply and the relay address it names.
3. Through that association, STUN Binding requests to three public STUN servers (Google,
   Cloudflare, Twilio): the address the proxy's UDP leaves from, per server (one address and one
   port for all three: an endpoint-independent mapping, the kind WebRTC's relay advertises).
4. TURN: an Allocate without credentials to two public TURN servers (Cloudflare, Twilio) must come
   back as a 401 — the relay servers answer through the proxy.
5. 100 Binding requests 20 ms apart to Google's STUN server: round-trip times and losses.
6. A second association: does the UDP address stay the same from one association to the next?
7. What the app's gate would decide (WebRTCGate): the relay only when the UDP egress the app's own
   check finds (Cloudflare's or Google's STUN answer) is the trace's TCP exit.

The UDP address is compared with the TCP one: the same, the same /24, the same /16, or another
network — and the country and network (AS) of each, asked of ip-api.com from this runner, not
through the proxy. The repository is public: the summary (stdout, the job's summary, summary.md)
names no address — only the first two octets of a proxy's own address, to tell subnets apart —
and the full report is written only encrypted (report.json.enc, RSA-OAEP over an AES key) to the
public key given, whose private half is not in the repository.
"""
import argparse
import ipaddress
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import time

STUN_SERVERS = [("google", "stun.l.google.com", 19302), ("cloudflare", "stun.cloudflare.com", 3478),
                ("twilio", "global.stun.twilio.com", 3478)]
TURN_SERVERS = [("cloudflare", "turn.cloudflare.com", 3478), ("twilio", "global.turn.twilio.com", 3478)]
ADDRESS_SERVICES = [("api.ipify.org", "/"), ("checkip.amazonaws.com", "/")]
TRACE_ADDRESSES = ["1.1.1.1", "1.0.0.1"]  # ProxyExitLookup.endpoints
MAGIC = 0x2112A442


class SOCKSError(Exception):
    pass


def recv_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise SOCKSError("closed by the proxy")
        data += chunk
    return data


def handshake(proxy, timeout=8.0):
    """A connected, authenticated control connection, and the time the TCP connect took (ms)."""
    started = time.time()
    sock = socket.create_connection((proxy["host"], proxy["port"]), timeout=timeout)
    connect_ms = (time.time() - started) * 1000
    sock.settimeout(timeout)
    sock.sendall(b"\x05\x02\x02\x00")  # username/password, or none (a proxy that needs none says so)
    version, method = recv_exact(sock, 2)
    if method == 0:
        return sock, connect_ms
    if method != 2:
        raise SOCKSError(f"method {method} (0xff: no acceptable method)")
    user, password = proxy["login"].encode(), proxy["password"].encode()
    sock.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
    _, status = recv_exact(sock, 2)
    if status != 0:
        raise SOCKSError(f"login refused ({status})")
    return sock, connect_ms


def read_reply(sock):
    head = recv_exact(sock, 4)
    rep, atyp = head[1], head[3]
    if atyp == 1:
        address = socket.inet_ntoa(recv_exact(sock, 4))
    elif atyp == 4:
        address = socket.inet_ntop(socket.AF_INET6, recv_exact(sock, 16))
    elif atyp == 3:
        address = recv_exact(sock, recv_exact(sock, 1)[0]).decode("latin-1")
    else:
        raise SOCKSError(f"reply address type {atyp}")
    port = struct.unpack("!H", recv_exact(sock, 2))[0]
    return rep, address, port


def tcp_exit(proxy, host, path):
    sock, _ = handshake(proxy)
    try:
        name = host.encode()
        sock.sendall(b"\x05\x01\x00\x03" + bytes([len(name)]) + name + struct.pack("!H", 80))
        rep, _, _ = read_reply(sock)
        if rep != 0:
            raise SOCKSError(f"CONNECT refused ({rep})")
        sock.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: curl/8\r\nConnection: close\r\n\r\n".encode())
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        body = data.split(b"\r\n\r\n", 1)[-1].decode("latin-1").strip()
        return str(ipaddress.ip_address(body.split()[0]))
    finally:
        sock.close()


def trace_exit(proxy, address):
    """The app's own way (ProxyExitLookup): HTTPS to Cloudflare's trace at an IPv4 address through
    the proxy (CONNECT by address: nothing resolved), its `ip=` line."""
    sock, _ = handshake(proxy)
    try:
        sock.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(address) + struct.pack("!H", 443))
        rep, _, _ = read_reply(sock)
        if rep != 0:
            raise SOCKSError(f"CONNECT refused ({rep})")
        tls = ssl.create_default_context().wrap_socket(sock, server_hostname=address)
        tls.sendall(f"GET /cdn-cgi/trace HTTP/1.1\r\nHost: {address}\r\nUser-Agent: curl/8\r\nConnection: close\r\n\r\n".encode())
        data = b""
        try:
            while True:
                chunk = tls.recv(4096)
                if not chunk:
                    break
                data += chunk
        except ssl.SSLError:
            pass
        return trace_ip(data.decode("latin-1"))
    finally:
        sock.close()


def trace_ip(text):
    """ExitTrace.ipv4: the first line that starts with `ip=`, when it is an IPv4 address."""
    for line in text.splitlines():
        if line.startswith("ip="):
            ip = ipaddress.ip_address(line[3:].strip())
            if ip.version != 4:
                raise SOCKSError("an IPv6 exit")
            return str(ip)
    raise SOCKSError("no ip= line in the answer")


def stun_request(kind=0x0001, transaction=None):
    transaction = transaction or os.urandom(12)
    return struct.pack("!HHI", kind, 0, MAGIC) + transaction, transaction


def parse_stun(data):
    """(message type, transaction, XOR-MAPPED-ADDRESS (ip, port) or None, error code or None)."""
    if len(data) < 20:
        return None
    kind, length, magic = struct.unpack("!HHI", data[:8])
    if magic != MAGIC:
        return None
    transaction = data[8:20]
    mapped, error = None, None
    offset = 20
    while offset + 4 <= len(data):
        attr, alen = struct.unpack("!HH", data[offset:offset + 4])
        value = data[offset + 4:offset + 4 + alen]
        if attr == 0x0020 and len(value) >= 8 and value[1] == 1:
            port = struct.unpack("!H", value[2:4])[0] ^ (MAGIC >> 16)
            ip = struct.unpack("!I", value[4:8])[0] ^ MAGIC
            mapped = (socket.inet_ntoa(struct.pack("!I", ip)), port)
        if attr == 0x0009 and len(value) >= 4:
            error = (value[2] & 0x07) * 100 + value[3]
        offset += 4 + alen + ((4 - alen % 4) % 4)
    return kind, transaction, mapped, error


class Association:
    """One UDP ASSOCIATE: its control connection kept open, a local UDP socket, the relay address."""

    def __init__(self, proxy):
        self.control, _ = handshake(proxy)
        self.control.sendall(b"\x05\x03\x00\x01" + b"\x00" * 6)
        rep, address, port = read_reply(self.control)
        self.reply = rep
        if rep != 0:
            raise SOCKSError(f"UDP ASSOCIATE refused ({rep})")
        if address in ("0.0.0.0", "::"):
            address = proxy["host"]
        self.relay = (address, port)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.settimeout(0.2)

    def send(self, ip, port, payload):
        header = b"\x00\x00\x00\x01" + socket.inet_aton(ip) + struct.pack("!H", port)
        self.udp.sendto(header + payload, self.relay)

    def receive(self, deadline):
        """(source ip, source port, payload) of the next datagram, or None by the deadline."""
        while time.time() < deadline:
            try:
                data, _ = self.udp.recvfrom(4096)
            except socket.timeout:
                continue
            if len(data) < 10 or data[3] != 1:
                continue
            return socket.inet_ntoa(data[4:8]), struct.unpack("!H", data[8:10])[0], data[10:]
        return None

    def ask(self, ip, port, payload, transaction, wait=2.0, tries=3):
        for _ in range(tries):
            self.send(ip, port, payload)
            deadline = time.time() + wait
            while True:
                answer = self.receive(deadline)
                if answer is None:
                    break
                parsed = parse_stun(answer[2])
                if parsed and parsed[1] == transaction:
                    return parsed
        return None

    def close(self):
        for thing in (self.udp, self.control):
            try:
                thing.close()
            except OSError:
                pass


def resolve(name):
    try:
        return socket.gethostbyname(name)
    except OSError:
        return None


def relation(a, b):
    if not a or not b:
        return "unknown"
    if a == b:
        return "same"
    x, y = ipaddress.ip_address(a), ipaddress.ip_address(b)
    if x.version != y.version:
        return "other family"
    for prefix, label in ((24, "same /24"), (16, "same /16")):
        if ipaddress.ip_network(f"{a}/{prefix}", strict=False) == ipaddress.ip_network(f"{b}/{prefix}", strict=False):
            return label
    return "other network"


def where(ip, cache={}):
    if not ip:
        return None
    if ip not in cache:
        try:
            import urllib.request
            with urllib.request.urlopen(f"http://ip-api.com/json/{ip}?fields=status,countryCode,regionName,city,as", timeout=8) as r:
                cache[ip] = json.loads(r.read().decode())
        except Exception as error:  # a report, never fatal
            cache[ip] = {"status": "error", "error": str(error)}
    return cache[ip]


def measure(proxy, servers):
    result = {"entry": proxy["host"], "port": proxy["port"]}
    try:
        sock, connect_ms = handshake(proxy)
        sock.close()
        result["login"] = "ok"
        result["tcpConnectMs"] = round(connect_ms, 1)
    except Exception as error:
        result["login"] = f"failed: {error}"
        return result
    exits = []
    for host, path in ADDRESS_SERVICES:
        try:
            exits.append(tcp_exit(proxy, host, path))
        except Exception as error:
            exits.append(f"error: {error}")
    result["tcpExits"] = exits
    tcp = next((e for e in exits if not e.startswith("error")), None)
    result["tcpExit"] = tcp
    traces = []
    for address in TRACE_ADDRESSES:
        try:
            traces.append(trace_exit(proxy, address))
            break
        except Exception as error:
            traces.append(f"error: {error}")
    result["traceExits"] = traces
    trace = next((t for t in traces if not t.startswith("error")), None)
    result["traceExit"] = trace
    result["traceVsTcp"] = relation(trace, tcp)
    result["gate"] = "unsupported"
    # UDP
    try:
        association = Association(proxy)
    except Exception as error:
        result["udpAssociate"] = f"failed: {error}"
        return result
    result["udpAssociate"] = "ok"
    result["relayIsEntry"] = association.relay[0] == proxy["host"]
    result["relay"] = list(association.relay)
    try:
        mapped = {}
        for name, host, port in STUN_SERVERS:
            ip = servers.get(host)
            if not ip:
                mapped[name] = "unresolved"
                continue
            payload, transaction = stun_request()
            answer = association.ask(ip, port, payload, transaction)
            mapped[name] = list(answer[2]) if answer and answer[2] else None
        result["stun"] = mapped
        turns = {}
        for name, host, port in TURN_SERVERS:
            ip = servers.get(host)
            if not ip:
                turns[name] = "unresolved"
                continue
            payload, transaction = stun_request(kind=0x0003)  # Allocate, no credentials
            answer = association.ask(ip, port, payload, transaction)
            turns[name] = (f"error {answer[3]}" if answer and answer[3] else ("answered" if answer else None))
        result["turn"] = turns
        # Round trips and losses: 100 Binding requests 20 ms apart to Google's server.
        google = servers.get("stun.l.google.com")
        sent, rtts = {}, []
        if google:
            for i in range(100):
                payload, transaction = stun_request()
                sent[transaction] = time.time()
                association.send(google, 19302, payload)
                deadline = time.time() + 0.02
                while time.time() < deadline:
                    answer = association.receive(deadline)
                    if answer is None:
                        break
                    parsed = parse_stun(answer[2])
                    if parsed and parsed[1] in sent:
                        rtts.append((time.time() - sent.pop(parsed[1])) * 1000)
            deadline = time.time() + 2.0
            while sent and time.time() < deadline:
                answer = association.receive(deadline)
                if answer is None:
                    break
                parsed = parse_stun(answer[2])
                if parsed and parsed[1] in sent:
                    rtts.append((time.time() - sent.pop(parsed[1])) * 1000)
            rtts.sort()
            result["series"] = {"sent": 100, "answered": len(rtts), "lossPercent": 100 - len(rtts),
                                "rttMs": {"min": round(rtts[0], 1), "p50": round(rtts[len(rtts) // 2], 1),
                                          "p90": round(rtts[int(len(rtts) * 0.9) - 1], 1), "max": round(rtts[-1], 1)}
                                if rtts else None}
    finally:
        association.close()
    # A second association: the same UDP address?
    try:
        second = Association(proxy)
        try:
            payload, transaction = stun_request()
            answer = second.ask(servers.get("stun.l.google.com"), 19302, payload, transaction)
            result["secondAssociation"] = list(answer[2]) if answer and answer[2] else None
        finally:
            second.close()
    except Exception as error:
        result["secondAssociation"] = f"failed: {error}"
    udp_addresses = sorted({m[0] for m in (result.get("stun") or {}).values() if isinstance(m, list)})
    result["udpEgress"] = udp_addresses
    udp = udp_addresses[0] if udp_addresses else None
    result["udpVsTcp"] = relation(udp, tcp) if len(udp_addresses) <= 1 else "several: " + ", ".join(relation(u, tcp) for u in udp_addresses)
    result["tcpVsEntry"] = relation(tcp, proxy["host"])
    result["udpVsEntry"] = relation(udp, proxy["host"])
    ports = {m[1] for m in (result.get("stun") or {}).values() if isinstance(m, list)}
    result["mapping"] = ("endpoint-independent" if len(ports) == 1 and len(udp_addresses) == 1
                         else f"{len(ports)} ports for {sum(1 for m in (result.get('stun') or {}).values() if isinstance(m, list))} servers")
    second = result.get("secondAssociation")
    result["secondSameAddress"] = (isinstance(second, list) and udp is not None and second[0] == udp)
    # The gate: the app's UDP check takes Cloudflare's or Google's answer (TunnelAddressing's STUN
    # servers); the relay only when it is the trace's exit.
    stun = result.get("stun") or {}
    checked = next((stun[name] for name in ("cloudflare", "google") if isinstance(stun.get(name), list)), None)
    if checked is None:
        result["gate"] = "unsupported"
    elif trace is None:
        result["gate"] = "exitUnknown"
    else:
        result["gate"] = "supported" if checked[0] == trace else "elsewhere"
    result["where"] = {"tcp": where(tcp), "udp": where(udp)}
    return result


def mask(ip):
    try:
        parts = str(ipaddress.ip_address(ip)).split(".")
        return f"{parts[0]}.{parts[1]}.x.x" if len(parts) == 4 else "v6"
    except ValueError:
        return "?"


def place(info):
    if not info or info.get("status") != "success":
        return "?"
    return f"{info.get('countryCode')}, {info.get('as', '')[:40]}"


def summary(results, label):
    lines = [f"### SOCKS5 UDP, {len(results)} proxies ({label})", "",
             "| # | entry | login | UDP ASSOCIATE | relay = entry | UDP from TCP's address | trace = TCP | gate | TCP exit = entry | STUN answered | TURN 401 | mapping | 2nd association same | RTT p50/p90 ms | loss % | TCP at | UDP at |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for i, r in enumerate(results, 1):
        stun = r.get("stun") or {}
        answered = sum(1 for v in stun.values() if isinstance(v, list))
        turns = r.get("turn") or {}
        turn_ok = sum(1 for v in turns.values() if isinstance(v, str) and v.startswith("error 401"))
        series = r.get("series") or {}
        rtt = series.get("rttMs") or {}
        login = "ok" if r.get("login") == "ok" else "FAILED"
        assoc = r.get("udpAssociate", "—")
        assoc = "ok" if assoc == "ok" else ("REFUSED" if "refused" in str(assoc) else ("—" if assoc == "—" else "FAILED"))
        where_ = r.get("where") or {}
        lines.append(f"| {i} | {mask(r['entry'])} | {login} | {assoc} | {r.get('relayIsEntry', '—')} | {r.get('udpVsTcp', '—')} | "
                     f"{r.get('traceVsTcp', '—')} | {r.get('gate', '—')} | {r.get('tcpVsEntry', '—')} | {answered}/{len(STUN_SERVERS) if stun else 0} | {turn_ok}/{len(turns)} | "
                     f"{r.get('mapping', '—')} | {r.get('secondSameAddress', '—')} | {rtt.get('p50', '—')}/{rtt.get('p90', '—')} | "
                     f"{series.get('lossPercent', '—')} | {place(where_.get('tcp'))} | {place(where_.get('udp'))} |")
    return "\n".join(lines) + "\n"


def encrypt(report, pubkey, out):
    """report.json.enc (AES-256-CBC, PBKDF2) and key.enc (its key, RSA-OAEP): only the private key opens them."""
    plain = os.path.join(out, "report.json")
    with open(plain, "w") as handle:
        json.dump(report, handle, indent=1)
    key = os.path.join(out, "key.hex")
    try:
        with open(key, "w") as handle:
            handle.write(os.urandom(32).hex())
        subprocess.run(["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-salt", "-in", plain,
                        "-out", plain + ".enc", "-pass", f"file:{key}"], check=True)
        subprocess.run(["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", pubkey, "-pkeyopt",
                        "rsa_padding_mode:oaep", "-in", key, "-out", os.path.join(out, "key.enc")], check=True)
        print("the full report is in report.json.enc (key.enc), for the private key only")
    except Exception as error:
        print(f"the full report could not be encrypted ({error}): not kept")
        for leftover in (plain + ".enc", os.path.join(out, "key.enc")):
            if os.path.exists(leftover):
                os.remove(leftover)
    finally:
        for secret in (plain, key):
            if os.path.exists(secret):
                os.remove(secret)


def proxies_of(text):
    """The secret's lines as proxies, and how many lines were in no form read here. Three forms:
    host:port:login:password, host:port@login:password and login:password@host:port. A line that is
    none of them is counted and never printed: the repository is public, and it holds a login."""
    proxies, unread = [], 0
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.lower().startswith("socks5://"):
            line = line[len("socks5://"):]
        host = port = login = password = None
        if "@" in line:
            left, right = line.split("@", 1)
            for address, account in ((left, right), (right, left)):
                parts = address.split(":")
                if len(parts) == 2 and parts[1].isdigit() and ":" in account:
                    host, port = parts
                    login, password = account.split(":", 1)
                    break
        else:
            parts = line.split(":")
            if len(parts) >= 4 and parts[1].isdigit():
                host, port, login, password = parts[0], parts[1], parts[2], ":".join(parts[3:])
        if host and login and password:
            proxies.append({"host": host, "port": int(port), "login": login, "password": password})
        else:
            unread += 1
    return proxies, unread


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pubkey")
    parser.add_argument("--label", default=os.environ.get("RUNNER_OS", "this machine"))
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    proxies, unread = proxies_of(os.environ.get("PB_TEST_PROXIES") or "")
    if unread:
        print(f"PROXY-UDP: {unread} line(s) of PB_TEST_PROXIES are in no form read here "
              "(host:port:login:password, host:port@login:password, login:password@host:port); not shown")
    if not proxies:
        print("PROXY-UDP SKIPPED: no PB_TEST_PROXIES (a repository secret, host:port:login:password per line)"
              if not unread else "PROXY-UDP SKIPPED: PB_TEST_PROXIES is there, and no line of it could be read")
        return 0
    servers = {host: resolve(host) for _, host, _ in STUN_SERVERS + TURN_SERVERS}
    # For a test against a local proxy: names given their addresses (JSON).
    servers.update(json.loads(os.environ.get("PB_TEST_SERVERS") or "{}"))
    results = []
    for index, proxy in enumerate(proxies, 1):
        started = time.time()
        try:
            result = measure(proxy, servers)
        except Exception as error:
            result = {"entry": proxy["host"], "port": proxy["port"], "error": str(error)}
        result["seconds"] = round(time.time() - started, 1)
        results.append(result)
        print(f"proxy #{index} ({mask(proxy['host'])}): login {result.get('login')}, UDP ASSOCIATE "
              f"{'ok' if result.get('udpAssociate') == 'ok' else 'not ok'}, UDP from TCP's address: {result.get('udpVsTcp')}, "
              f"the app's gate: {result.get('gate')}, {result['seconds']} s", flush=True)
    text = summary(results, args.label)
    print(text)
    with open(os.path.join(args.out, "summary.md"), "w") as handle:
        handle.write(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(text)
    if args.pubkey:
        encrypt({"label": args.label, "servers": servers, "results": results}, args.pubkey, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
