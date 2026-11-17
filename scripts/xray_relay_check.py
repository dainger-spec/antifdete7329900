#!/usr/bin/env python3
"""The relay's configuration for every kind of link, against real Xray servers (docs/TUNNEL.md, "Links").

    python3 -I scripts/xray_relay_check.py --xray build/xray/xray-linux-amd64 \
        --config-tool .build/debug/lumen-xray-config [--work DIR] [--keep]

Starts, on 127.0.0.1, one Xray server with an inbound for each protocol and transport Lumen reads —
VLESS with REALITY and xtls-rprx-vision over RAW and over XHTTP, VLESS with TLS over RAW (vision),
WebSocket and gRPC, VMess over WebSocket, Trojan with TLS, Shadowsocks 2022 — whose only outbound
hands every connection, TCP and UDP, to a small HTTP server and UDP echo of this script (`redirect`):
so no name is ever resolved anywhere, and an `.invalid` host can only get through if it was carried
as a name. The TLS servers' certificate is made for the run and pinned by the links (`pcs`); REALITY's
keys too, its target a TLS 1.3 server of this script.

For each link, the relay's configuration comes from Lumen's own code (`lumen-xray-config`, BrowserCore's
XrayConfig) with a login made for the run, and a relay is started from it as the app starts one (the
configuration on standard input). Then, through the relay:

* a page: SOCKS5 CONNECT to `canary-<n>.invalid:80` by name, an HTTP request whose answer must come
  from the echo, naming that host — carried as a name to the server's side, never resolved here;
* UDP: an association made with the login, and a datagram to `udp-canary.invalid:9` that must come
  back from the echo; a datagram to the association's port from another socket gets nothing;
* the door: SOCKS5 without a login, with a wrong password, SOCKS4, and plain HTTP without
  Proxy-Authorization are each refused, and no association is had without the login.

Exit 1 if any check of any link fails. Every relay and the server are stopped at the end.
"""
import argparse
import base64
import hashlib
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid

SNI_TLS = "relay-test.example"
SNI_REALITY = "reality.example"


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_port(port, seconds=15.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


class Echo:
    """An HTTP server that answers with the request's Host, and a UDP echo, on one port number."""

    def __init__(self):
        self.port = free_port()
        self.hosts = []
        self.tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.tcp.bind(("127.0.0.1", self.port))
        self.tcp.listen(64)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(("127.0.0.1", self.port))
        threading.Thread(target=self.serve_tcp, daemon=True).start()
        threading.Thread(target=self.serve_udp, daemon=True).start()

    def serve_tcp(self):
        while True:
            try:
                connection, _ = self.tcp.accept()
            except OSError:
                return
            threading.Thread(target=self.answer, args=(connection,), daemon=True).start()

    def answer(self, connection):
        with connection:
            connection.settimeout(10)
            data = b""
            try:
                while b"\r\n\r\n" not in data and len(data) < 65536:
                    chunk = connection.recv(4096)
                    if not chunk:
                        return
                    data += chunk
            except OSError:
                return
            host = ""
            for line in data.split(b"\r\n")[1:]:
                if line.lower().startswith(b"host:"):
                    host = line.split(b":", 1)[1].strip().decode("latin-1")
            self.hosts.append(host)
            body = ("LUMEN-RELAY-OK host=%s" % host).encode()
            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)

    def serve_udp(self):
        while True:
            try:
                data, peer = self.udp.recvfrom(65536)
            except OSError:
                return
            self.udp.sendto(b"ECHO:" + data, peer)


class TLSTarget:
    """REALITY's target: a TLS 1.3 server with the run's certificate, which says nothing after the handshake."""

    def __init__(self, cert_file, key_file):
        self.port = free_port()
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_3
        self.context.set_alpn_protocols(["h2", "http/1.1"])
        self.context.load_cert_chain(cert_file, key_file)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", self.port))
        self.sock.listen(64)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                connection, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()

    def handle(self, connection):
        try:
            connection.settimeout(10)
            with self.context.wrap_socket(connection, server_side=True) as wrapped:
                wrapped.recv(1)
        except (OSError, ssl.SSLError):
            pass
        finally:
            try:
                connection.close()
            except OSError:
                pass


def xray_output(xray, *args):
    return subprocess.run([xray, *args], capture_output=True, text=True, check=True).stdout


def make_material(xray, work):
    keys = {}
    for line in xray_output(xray, "x25519").splitlines():
        if ":" in line:
            name, value = line.split(":", 1)
            keys[name.strip()] = value.strip()
    private = keys["PrivateKey"]
    public = keys.get("Password (PublicKey)") or keys.get("Password") or keys.get("PublicKey")
    cert = json.loads(xray_output(xray, "tls", "cert", "--domain=" + SNI_TLS))
    cert_pem = "\n".join(cert["certificate"]) + "\n"
    # Xray labels its PKCS#8 key "RSA PRIVATE KEY" whatever the key is: as PKCS#8 for this script's TLS.
    key_pem = "\n".join(cert["key"]).replace("RSA PRIVATE KEY", "PRIVATE KEY") + "\n"
    der = base64.b64decode("".join(line for line in cert["certificate"] if not line.startswith("-----")))
    cert_file = os.path.join(work, "server.crt")
    key_file = os.path.join(work, "server.key")
    with open(cert_file, "w") as handle:
        handle.write(cert_pem)
    with open(key_file, "w") as handle:
        handle.write(key_pem)
    os.chmod(key_file, 0o600)
    return {
        "private": private, "public": public, "cert": cert, "pcs": hashlib.sha256(der).hexdigest(),
        "cert_file": cert_file, "key_file": key_file,
        "id": str(uuid.uuid4()), "trojan": base64.urlsafe_b64encode(os.urandom(12)).decode().rstrip("="),
        "ss": base64.b64encode(os.urandom(16)).decode(),
    }


def server_config(material, echo, target, ports):
    tls = {"certificates": [{"certificate": material["cert"]["certificate"], "key": material["cert"]["key"]}],
           "alpn": ["h2", "http/1.1"]}
    reality = {"target": "127.0.0.1:%d" % target.port, "serverNames": [SNI_REALITY], "privateKey": material["private"],
               "shortIds": ["", "6ba85179e30d4fc2"]}
    vless_vision = {"clients": [{"id": material["id"], "flow": "xtls-rprx-vision"}], "decryption": "none"}
    vless = {"clients": [{"id": material["id"]}], "decryption": "none"}

    def inbound(tag, protocol, settings, stream):
        return {"tag": tag, "listen": "127.0.0.1", "port": ports[tag], "protocol": protocol, "settings": settings,
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
    return {
        "log": {"loglevel": "warning"},
        "inbounds": inbounds,
        # Every connection and datagram to the echo, whatever it was addressed to: nothing is resolved.
        # (A server's freedom refuses private addresses by default; the echo is one, so it is allowed.)
        "outbounds": [{"protocol": "freedom", "settings": {
            "redirect": "127.0.0.1:%d" % echo.port,
            "finalRules": [{"action": "allow", "network": "tcp,udp", "ip": ["127.0.0.1/32"]}]}}],
    }


def links(material, ports):
    quoted = lambda text: text.replace("/", "%2F").replace("+", "%2B").replace("=", "%3D")  # noqa: E731
    tls = "security=tls&sni=%s&pcs=%s" % (SNI_TLS, material["pcs"])
    reality = "security=reality&sni=%s&fp=chrome&pbk=%s" % (SNI_REALITY, material["public"])
    vmess = {"v": "2", "ps": "vmess-ws", "add": "127.0.0.1", "port": str(ports["vmess-ws"]), "id": material["id"], "aid": "0",
             "scy": "auto", "net": "ws", "path": "/vm", "tls": ""}
    return [
        ("reality-vision", "vless://%s@127.0.0.1:%d?encryption=none&flow=xtls-rprx-vision&%s&sid=6ba85179e30d4fc2&spx=%%2F&type=tcp"
         "#reality-vision" % (material["id"], ports["reality-vision"], reality)),
        ("reality-xhttp", "vless://%s@127.0.0.1:%d?encryption=none&%s&sid=&type=xhttp&path=%%2Fxh&mode=auto#reality-xhttp"
         % (material["id"], ports["reality-xhttp"], reality)),
        ("tls-vision", "vless://%s@127.0.0.1:%d?encryption=none&flow=xtls-rprx-vision&%s&type=tcp#tls-vision"
         % (material["id"], ports["tls-vision"], tls)),
        ("tls-ws", "vless://%s@127.0.0.1:%d?%s&type=ws&path=%%2Fws&host=%s#tls-ws" % (material["id"], ports["tls-ws"], tls, SNI_TLS)),
        ("tls-grpc", "vless://%s@127.0.0.1:%d?%s&type=grpc&serviceName=svc#tls-grpc" % (material["id"], ports["tls-grpc"], tls)),
        ("vmess-ws", "vmess://" + base64.b64encode(json.dumps(vmess).encode()).decode()),
        ("trojan-tls", "trojan://%s@127.0.0.1:%d?%s#trojan" % (material["trojan"], ports["trojan-tls"], tls)),
        ("ss2022", "ss://2022-blake3-aes-128-gcm:%s@127.0.0.1:%d#ss2022" % (quoted(material["ss"]), ports["ss2022"])),
    ]


# SOCKS5, as a profile's process and the app's own clients speak it.

def recv_exactly(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("closed after %d of %d bytes" % (len(data), count))
        data += chunk
    return data


def socks_login(port, user, password, timeout=10):
    sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    sock.sendall(b"\x05\x01\x02")
    if recv_exactly(sock, 2) != b"\x05\x02":
        raise ConnectionError("the relay did not ask for the login")
    sock.sendall(b"\x01" + bytes([len(user)]) + user.encode() + bytes([len(password)]) + password.encode())
    if recv_exactly(sock, 2) != b"\x01\x00":
        raise ConnectionError("the login was refused")
    return sock


def read_reply(sock):
    head = recv_exactly(sock, 4)
    if head[1] != 0:
        raise ConnectionError("SOCKS5 reply %d" % head[1])
    kind = head[3]
    if kind == 1:
        address = socket.inet_ntoa(recv_exactly(sock, 4))
    elif kind == 4:
        address = socket.inet_ntop(socket.AF_INET6, recv_exactly(sock, 16))
    else:
        address = recv_exactly(sock, recv_exactly(sock, 1)[0]).decode()
    port = struct.unpack("!H", recv_exactly(sock, 2))[0]
    return address, port


def page_through(port, user, password, host):
    sock = socks_login(port, user, password, timeout=20)
    with sock:
        name = host.encode()
        sock.sendall(b"\x05\x01\x00\x03" + bytes([len(name)]) + name + struct.pack("!H", 80))
        read_reply(sock)
        sock.sendall(b"GET /canary HTTP/1.1\r\nHost: " + name + b"\r\nConnection: close\r\n\r\n")
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data.decode("latin-1")


def udp_through(port, user, password, host, payload):
    client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    client.bind(("127.0.0.1", 0))
    client.settimeout(5)
    control = socks_login(port, user, password)
    with control, client:
        # The address the datagrams will come from, as RFC 1928 asks: the association is held to it.
        own_host, own_port = client.getsockname()
        control.sendall(b"\x05\x03\x00\x01" + socket.inet_aton(own_host) + struct.pack("!H", own_port))
        relay_host, relay_port = read_reply(control)
        name = host.encode()
        header = b"\x00\x00\x00\x03" + bytes([len(name)]) + name + struct.pack("!H", 9)
        answer = None
        for _ in range(4):
            client.sendto(header + payload, (relay_host, relay_port))
            try:
                data, _ = client.recvfrom(65536)
            except socket.timeout:
                continue
            answer = data
            break
        # Another socket of this machine, to the same association's port: nothing comes back to it.
        stranger = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        stranger.bind(("127.0.0.1", 0))
        stranger.settimeout(2)
        stranger_answer = None
        with stranger:
            stranger.sendto(header + b"stranger", (relay_host, relay_port))
            try:
                stranger_answer = stranger.recvfrom(65536)[0]
            except socket.timeout:
                pass
        return answer, stranger_answer


def door_checks(port, user):
    """Each way in without the login, refused. Returns the failures."""
    failures = []
    # SOCKS5 offering no login.
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
            sock.sendall(b"\x05\x01\x00")
            answer = sock.recv(2)
            if answer != b"\x05\xff":
                failures.append("SOCKS5 without a login was answered %r, not refused" % answer)
    except OSError:
        pass
    # A wrong password.
    try:
        socks_login(port, user, "wrong-password").close()
        failures.append("a wrong password was taken")
    except (OSError, ConnectionError):
        pass
    # SOCKS4 CONNECT.
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
            sock.sendall(b"\x04\x01\x00\x50" + socket.inet_aton("127.0.0.1") + b"lumen\x00")
            answer = sock.recv(8)
            if len(answer) >= 2 and answer[1] == 0x5A:
                failures.append("SOCKS4 was granted")
    except OSError:
        pass
    # Plain HTTP, CONNECT and GET, without Proxy-Authorization.
    for request in (b"CONNECT canary.invalid:80 HTTP/1.1\r\nHost: canary.invalid:80\r\n\r\n",
                    b"GET http://canary.invalid/ HTTP/1.1\r\nHost: canary.invalid\r\n\r\n"):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                sock.sendall(request)
                answer = sock.recv(64)
                if b" 407 " not in answer and answer:
                    failures.append("HTTP without a login was answered %r" % answer[:40])
        except OSError:
            pass
    # A UDP association without the login: the greeting is refused before any command.
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
            sock.sendall(b"\x05\x01\x00" + b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
            answer = sock.recv(16)
            if answer[:2] != b"\x05\xff":
                failures.append("a UDP association without a login was answered %r" % answer)
    except OSError:
        pass
    # Nothing listens for UDP on the relay's own port: associations get ports of their own.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(1.5)
        sock.sendto(b"\x00\x00\x00\x03\x0eudp-canary.inv\x00\x09probe", ("127.0.0.1", port))
        try:
            sock.recvfrom(1024)
            failures.append("the relay's own port answered a datagram")
        except (socket.timeout, ConnectionError, OSError):
            pass
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--xray", required=True)
    parser.add_argument("--config-tool", required=True)
    parser.add_argument("--work")
    parser.add_argument("--keep", action="store_true")
    options = parser.parse_args()
    # The relays run from "/" (as the app starts one): every path given is taken as it was meant here.
    options.xray = os.path.abspath(options.xray)
    options.config_tool = os.path.abspath(options.config_tool)
    work = options.work or tempfile.mkdtemp(prefix="xray-relay-check-")
    os.makedirs(work, exist_ok=True)
    processes = []
    failed = []
    try:
        material = make_material(options.xray, work)
        echo = Echo()
        target = TLSTarget(material["cert_file"], material["key_file"])
        tags = ["reality-vision", "reality-xhttp", "tls-vision", "tls-ws", "tls-grpc", "vmess-ws", "trojan-tls", "ss2022"]
        ports = {tag: free_port() for tag in tags}
        server_log = open(os.path.join(work, "server.log"), "w")
        server = subprocess.Popen([options.xray, "run", "-c", "stdin:"], stdin=subprocess.PIPE, stdout=server_log,
                                  stderr=subprocess.STDOUT, env={"PATH": "/usr/bin:/bin"})
        processes.append(server)
        server.stdin.write(json.dumps(server_config(material, echo, target, ports)).encode())
        server.stdin.close()
        for tag in tags:
            if not wait_for_port(ports[tag]):
                sys.exit("XRAY-RELAY FAIL the server did not listen for %s (see %s/server.log)" % (tag, work))
        print("XRAY-RELAY INFO server up: %s" % ", ".join("%s:%d" % (tag, ports[tag]) for tag in tags))
        for number, (tag, link) in enumerate(links(material, ports), start=1):
            relay_port = free_port()
            user = os.urandom(16).hex()
            password = os.urandom(16).hex()
            made = subprocess.run([options.config_tool, "--port", str(relay_port), "--user", user, "--pass", password],
                                  input=link.encode(), capture_output=True)
            if made.returncode != 0:
                failed.append(tag)
                print("XRAY-RELAY FAIL %s: Lumen refused the link: %s" % (tag, made.stderr.decode().strip()))
                continue
            config = made.stdout
            log = open(os.path.join(work, "relay-%s.log" % tag), "w")
            relay = subprocess.Popen([options.xray, "run", "-c", "stdin:"], stdin=subprocess.PIPE, stdout=log,
                                     stderr=subprocess.STDOUT, env={"PATH": "/usr/bin:/bin"}, cwd="/")
            processes.append(relay)
            relay.stdin.write(config)
            relay.stdin.close()
            if not wait_for_port(relay_port):
                failed.append(tag)
                print("XRAY-RELAY FAIL %s: the relay did not listen (see relay-%s.log)" % (tag, tag))
                continue
            problems = []
            host = "canary-%d.invalid" % number
            try:
                page = page_through(relay_port, user, password, host)
                if "LUMEN-RELAY-OK host=%s" % host not in page:
                    problems.append("the page through it was %r" % page[-120:])
            except (OSError, ConnectionError) as error:
                problems.append("no page through it: %s" % error)
            try:
                answer, stranger = udp_through(relay_port, user, password, "udp-canary.invalid", b"lumen-%d" % number)
                expected = b"ECHO:lumen-%d" % number
                if answer is None or not answer.endswith(expected):
                    problems.append("UDP did not come back through it (%r)" % answer)
                if stranger is not None:
                    problems.append("another socket's datagram to the association was answered")
            except (OSError, ConnectionError) as error:
                problems.append("no UDP association: %s" % error)
            problems += door_checks(relay_port, user)
            relay.terminate()
            relay.wait(timeout=10)
            if problems:
                failed.append(tag)
                for problem in problems:
                    print("XRAY-RELAY FAIL %s: %s" % (tag, problem))
            else:
                print("XRAY-RELAY PASS %s: a page and UDP through it by name, nothing resolved; no way in without its login" % tag)
        # The door check's own control: the first link's relay with its login taken off must fail it.
        control_port = free_port()
        made = subprocess.run([options.config_tool, "--port", str(control_port), "--user", "u", "--pass", "p"],
                              input=links(material, ports)[0][1].encode(), capture_output=True, check=True)
        open_config = json.loads(made.stdout)
        open_config["inbounds"][0]["settings"] = {"auth": "noauth", "udp": True, "ip": "127.0.0.1"}
        control = subprocess.Popen([options.xray, "run", "-c", "stdin:"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, env={"PATH": "/usr/bin:/bin"}, cwd="/")
        processes.append(control)
        control.stdin.write(json.dumps(open_config).encode())
        control.stdin.close()
        if not wait_for_port(control_port) or not door_checks(control_port, "u"):
            failed.append("control")
            print("XRAY-RELAY FAIL the control: a relay without a login passed the door check, which therefore proves nothing")
        else:
            print("XRAY-RELAY PASS the control: a relay without a login fails the door check")
        if echo.hosts and any(not host.endswith(".invalid") for host in echo.hosts):
            failed.append("hosts")
            print("XRAY-RELAY FAIL the echo saw hosts it was not asked for: %s" % sorted(set(echo.hosts)))
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
        if not options.keep and not options.work:
            shutil.rmtree(work, ignore_errors=True)
    if failed:
        print("XRAY-RELAY FAILED: %s" % ", ".join(failed))
        sys.exit(1)
    print("XRAY-RELAY PASSED: every kind of link")


if __name__ == "__main__":
    main()
