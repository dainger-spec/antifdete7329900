#!/usr/bin/env python3
"""Does a SOCKS5 proxy carry UDP? Asked of real proxies, one by one (the owner's question 2).

    python3 udp_associate_probe.py proxies.txt [--json out.json]

proxies.txt: one proxy per line, `socks5://user:password@host:port`, `host:port:user:password` or
`host:port`; an optional label after a `#` names the seller (`… # provider A, residential`).
Python 3.8+, nothing to install; it runs on any Mac.

For each proxy, in order, each step only if the one before worked:
  1. TCP to the proxy, the SOCKS5 greeting, the login (RFC 1928, RFC 1929);
  2. CONNECT through it to api.ipify.org:80: the address the proxy's TCP leaves from;
  3. UDP ASSOCIATE (RFC 1928 §7): the proxy's answer — 0 means granted, 7 "command not supported";
  4. a STUN Binding (RFC 5389) through the association to two public STUN servers, by name and, if
     the proxy will not resolve names for UDP, by address: does an answer come back, and from which
     public address does the proxy's UDP leave (the XOR-MAPPED-ADDRESS);
  5. whether that address is the TCP one, and whether both STUN servers saw the same port
     (endpoint-independent mapping: what WebRTC needs for a relay port that works for every peer).

What leaves this Mac goes to the proxy only: the STUN servers and api.ipify.org are reached through
it, and their names are resolved by it. The report names each proxy by its label and a short hash of
its address, never by its address, user or password.
"""
import argparse
import hashlib
import ipaddress
import json
import os
import socket
import struct
import sys
import time

STUN_SERVERS = [("stun.l.google.com", 19302), ("stun.cloudflare.com", 3478)]
IP_ECHO = ("api.ipify.org", 80)
TIMEOUT = 8
REPLIES = {0: "granted", 1: "general failure", 2: "not allowed by ruleset", 3: "network unreachable",
           4: "host unreachable", 5: "connection refused", 6: "TTL expired", 7: "command not supported",
           8: "address type not supported"}


def parse_line(line):
    label = ""
    if "#" in line:
        line, label = line.split("#", 1)
    line, label = line.strip(), label.strip()
    if not line:
        return None
    user = password = None
    if "://" in line:
        line = line.split("://", 1)[1]
        if "@" in line:
            credentials, line = line.rsplit("@", 1)
            user, _, password = credentials.partition(":")
        host, _, port = line.rpartition(":")
    else:
        parts = line.split(":")
        host, port = parts[0], parts[1]
        if len(parts) >= 4:
            user, password = parts[2], ":".join(parts[3:])
    return {"host": host.strip("[]"), "port": int(port), "user": user, "password": password, "label": label}


def name_of(proxy):
    digest = hashlib.sha256(("%s:%d" % (proxy["host"], proxy["port"])).encode()).hexdigest()[:8]
    return (proxy["label"] + " " if proxy["label"] else "") + "#" + digest


def exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("the proxy closed the connection")
        data += chunk
    return data


def address_bytes(host):
    for family, kind in ((socket.AF_INET, 1), (socket.AF_INET6, 4)):
        try:
            return bytes([kind]) + socket.inet_pton(family, host)
        except OSError:
            pass
    encoded = host.encode("idna")
    return bytes([3, len(encoded)]) + encoded


def read_address(sock):
    kind = exact(sock, 1)[0]
    if kind == 1:
        host = socket.inet_ntop(socket.AF_INET, exact(sock, 4))
    elif kind == 4:
        host = socket.inet_ntop(socket.AF_INET6, exact(sock, 16))
    elif kind == 3:
        host = exact(sock, exact(sock, 1)[0]).decode("idna")
    else:
        raise ValueError("address type %d" % kind)
    return host, struct.unpack(">H", exact(sock, 2))[0]


def handshake(proxy):
    """A logged-in control connection to the proxy."""
    sock = socket.create_connection((proxy["host"], proxy["port"]), timeout=TIMEOUT)
    methods = [0, 2] if proxy["user"] is not None else [0]
    sock.sendall(bytes([5, len(methods)] + methods))
    version, method = exact(sock, 2)
    if version != 5:
        raise ValueError("not a SOCKS5 proxy (version %d)" % version)
    if method == 2:
        user, password = (proxy["user"] or "").encode(), (proxy["password"] or "").encode()
        sock.sendall(bytes([1, len(user)]) + user + bytes([len(password)]) + password)
        if exact(sock, 2)[1] != 0:
            raise PermissionError("login refused")
    elif method != 0:
        raise PermissionError("no acceptable login method (%d)" % method)
    return sock


def command(sock, code, host, port):
    sock.sendall(bytes([5, code, 0]) + address_bytes(host) + struct.pack(">H", port))
    version, reply, _ = exact(sock, 3)
    bound = read_address(sock)
    return reply, bound


def tcp_egress(proxy):
    sock = handshake(proxy)
    try:
        reply, _ = command(sock, 1, *IP_ECHO)
        if reply != 0:
            return None, "CONNECT refused: %s" % REPLIES.get(reply, reply)
        sock.sendall(b"GET / HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n")
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data.split(b"\r\n\r\n", 1)[-1].strip().decode("ascii", "replace"), None
    finally:
        sock.close()


def stun_request():
    transaction = os.urandom(12)
    return transaction, struct.pack(">HHI", 0x0001, 0, 0x2112A442) + transaction


def stun_mapped(payload, transaction):
    if len(payload) < 20 or payload[8:20] != transaction:
        return None
    offset = 20
    while offset + 4 <= len(payload):
        kind, length = struct.unpack(">HH", payload[offset:offset + 4])
        value = payload[offset + 4:offset + 4 + length]
        if kind in (0x0020, 0x0001) and len(value) >= 8:
            family = value[1]
            port = struct.unpack(">H", value[2:4])[0]
            raw = value[4:8] if family == 1 else value[4:20]
            if kind == 0x0020:
                port ^= 0x2112
                cookie = struct.pack(">I", 0x2112A442)
                mask = cookie if family == 1 else cookie + transaction
                raw = bytes(a ^ b for a, b in zip(raw, mask))
            host = socket.inet_ntop(socket.AF_INET if family == 1 else socket.AF_INET6, raw)
            return host, port
        offset += 4 + length + ((4 - length % 4) % 4)
    return None


def udp_probe(proxy, result):
    control = handshake(proxy)
    try:
        reply, (relay_host, relay_port) = command(control, 3, "0.0.0.0", 0)
        result["udpAssociate"] = REPLIES.get(reply, str(reply))
        if reply != 0:
            return
        # 0.0.0.0, or an address of the proxy's own network: the relay is at the proxy's address.
        try:
            inside = ipaddress.ip_address(relay_host)
            inside = inside.is_unspecified or inside.is_private or inside.is_loopback
        except ValueError:
            inside = False
        if inside:
            relay_host = proxy["host"]
        result["relayIsProxyHost"] = relay_host == proxy["host"]
        family = socket.AF_INET6 if ":" in relay_host else socket.AF_INET
        udp = socket.socket(family, socket.SOCK_DGRAM)
        udp.settimeout(4)
        mapped = []
        try:
            for server_host, server_port in STUN_SERVERS:
                answer = None
                for target in (server_host, None):
                    if target is None:
                        try:
                            target = socket.getaddrinfo(server_host, server_port, socket.AF_INET)[0][4][0]
                            result["resolvedLocallyFor"] = result.get("resolvedLocallyFor", []) + [server_host]
                        except OSError:
                            break
                    transaction, request = stun_request()
                    header = b"\x00\x00\x00" + address_bytes(target) + struct.pack(">H", server_port)
                    for _ in range(3):
                        udp.sendto(header + request, (relay_host, relay_port))
                        try:
                            data, _ = udp.recvfrom(2048)
                        except socket.timeout:
                            continue
                        # The reply carries the same SOCKS5 UDP header: skip it.
                        kind = data[3] if len(data) > 3 else 0
                        skip = 4 + {1: 4, 4: 16}.get(kind, (data[4] + 1) if kind == 3 and len(data) > 4 else 0) + 2
                        answer = stun_mapped(data[skip:], transaction)
                        if answer:
                            break
                    if answer:
                        break
                mapped.append(answer)
        finally:
            udp.close()
        result["stunAnswered"] = [bool(m) for m in mapped]
        answered = [m for m in mapped if m]
        if answered:
            result["udpEgress"] = answered[0][0]
            result["endpointIndependentMapping"] = (len(answered) == 2 and answered[0] == answered[1]) if len(answered) == 2 else None
    finally:
        control.close()


def probe(proxy):
    result = {"proxy": name_of(proxy)}
    started = time.time()
    try:
        egress, problem = tcp_egress(proxy)
        result["tcp"] = "works" if egress else problem
        result["tcpEgress"] = egress
        udp_probe(proxy, result)
    except (OSError, EOFError, ValueError, PermissionError) as error:
        result.setdefault("tcp", "failed: %s" % error)
        result.setdefault("udpAssociate", "not reached")
        result["error"] = str(error)
    if result.get("udpEgress") and result.get("tcpEgress"):
        result["udpEgressIsTcpEgress"] = result["udpEgress"] == result["tcpEgress"]
    result["carriesUDP"] = bool(result.get("stunAnswered") and any(result["stunAnswered"]))
    result["seconds"] = round(time.time() - started, 1)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("proxies")
    parser.add_argument("--json")
    args = parser.parse_args()
    with open(args.proxies, encoding="utf-8") as handle:
        proxies = [p for p in (parse_line(line) for line in handle) if p]
    results = []
    for proxy in proxies:
        result = probe(proxy)
        results.append(result)
        # The addresses the proxy leaves from are the proxy's, not the user's: kept, but not printed.
        print("%-40s TCP %-10s UDP ASSOCIATE %-22s STUN through it %-12s same egress %-6s EIM %s" % (
            result["proxy"][:40], "works" if result.get("tcpEgress") else "FAILS", result.get("udpAssociate"),
            result.get("stunAnswered"), result.get("udpEgressIsTcpEgress"), result.get("endpointIndependentMapping")),
            flush=True)
    working_tcp = [r for r in results if r.get("tcpEgress")]
    granted = [r for r in working_tcp if r.get("udpAssociate") == "granted"]
    carries = [r for r in working_tcp if r["carriesUDP"]]
    print("\n%d proxies; TCP works through %d; UDP ASSOCIATE granted by %d; UDP really carried (a STUN answer) by %d; "
          "of those, leaving from the TCP address %d, endpoint-independent %d" % (
              len(results), len(working_tcp), len(granted), len(carries),
              sum(1 for r in carries if r.get("udpEgressIsTcpEgress")),
              sum(1 for r in carries if r.get("endpointIndependentMapping"))))
    if args.json:
        with open(args.json, "w") as handle:
            json.dump([{k: v for k, v in r.items() if k not in ("tcpEgress", "udpEgress")} for r in results],
                      handle, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
