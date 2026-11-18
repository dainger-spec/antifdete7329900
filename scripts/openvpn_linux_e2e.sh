#!/usr/bin/env bash
# The OpenVPN tunnel end to end on Linux (docs/OPENVPN.md, "What is tested"): a real OpenVPN 2.7
# server with a kernel tun device, and OpenVPN 2.7's client run unprivileged with LumenTunnel as
# its tun (`--dev-node unix:`), the listening socket and status pipe passed down as the app does.
#
#   sudo scripts/openvpn_linux_e2e.sh            (root: the server's tun; the client runs as nobody)
#
# Needs: openvpn ≥ 2.7, openssl, python3, curl, tcpdump, iproute2. It checks, in order:
#   1. through the tunnel: a page named only by the tunnel's DNS server loads, and the server sees
#      it come from the client's tunnel address;
#   2. every DNS question for that name went to the pushed server through the tunnel (tcpdump on
#      every interface: none elsewhere);
#   3. the SOCKS5 port refuses a client without credentials, and one with the wrong password;
#   4. a UDP association carries a datagram through the tunnel and back;
#   5. the server killed: nothing loads any more (fail closed) and LumenTunnel is gone.
set -euo pipefail
cd "$(dirname "$0")/.."
# curl must go through the SOCKS5 port it is given, whatever proxies this shell names.
unset NO_PROXY no_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy
[[ "$(id -u)" == "0" ]] || { echo "error: run as root (the server's tun device)" >&2; exit 1; }
openvpn --version | head -1 | grep -E 'OpenVPN 2\.([7-9]|[1-9][0-9])' >/dev/null \
  || { echo "error: needs OpenVPN 2.7 or later (the AF_UNIX tun)" >&2; exit 1; }

W="$(mktemp -d /tmp/lumen-ovpn-e2e.XXXXXX)"
chmod 755 "$W"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  [[ -f "$W/server.pid" ]] && kill "$(cat "$W/server.pid")" 2>/dev/null || true
  sleep 1
  ip link del lovpn-srv 2>/dev/null || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; echo "--- client log"; tail -40 "$W/client.log" >&2 || true; echo "--- server log"; tail -20 "$W/server.log" >&2 || true; exit 1; }

swift build -c release --product LumenTunnel >/dev/null
TUNNEL="$W/LumenTunnel"
cp "$(swift build -c release --show-bin-path)/LumenTunnel" "$TUNNEL"
chmod 755 "$TUNNEL"
"$TUNNEL" --version

# The PKI: a CA, the server's and the client's certificates (EC), a tls-crypt key.
cd "$W"
printf 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.ext
printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature,keyAgreement\nextendedKeyUsage=serverAuth\n' > server.ext
printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature,keyAgreement\nextendedKeyUsage=clientAuth\n' > client.ext
openssl ecparam -name prime256v1 -genkey -noout -out ca.key 2>/dev/null
openssl req -new -x509 -key ca.key -subj /CN=e2e-ca -days 2 -out ca.crt 2>/dev/null
for who in server client; do
  openssl ecparam -name prime256v1 -genkey -noout -out $who.key 2>/dev/null
  openssl req -new -key $who.key -subj /CN=$who -out $who.csr 2>/dev/null
  openssl x509 -req -in $who.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile $who.ext -out $who.crt 2>/dev/null
done
openvpn --genkey tls-crypt ta.key
# The client runs as nobody: its files must be readable to it (a test PKI, thrown away after).
chmod 644 ca.crt client.crt client.key ta.key

cat > server.conf <<EOF
port 1194
proto udp
local 127.0.0.1
dev lovpn-srv
dev-type tun
ca $W/ca.crt
cert $W/server.crt
key $W/server.key
dh none
tls-crypt $W/ta.key
topology subnet
server 10.77.0.0 255.255.255.0
push "dhcp-option DNS 10.77.0.1"
push "redirect-gateway def1"
keepalive 2 8
verb 3
EOF
openvpn --config server.conf --daemon --log "$W/server.log" --writepid "$W/server.pid"
for _ in $(seq 1 20); do ip addr show lovpn-srv 2>/dev/null | grep -q 10.77.0.1 && break; sleep 0.5; done
ip addr show lovpn-srv | grep -q 10.77.0.1 || fail "the server's tun did not come up"

# The far side's services, on the server's tunnel address only: a page that says who asked, a DNS
# server that knows the one name, a UDP echo.
cat > services.py <<'EOF'
import socket, struct, sys, threading, http.server
ADDRESS = "10.77.0.1"
BIG = bytes(range(256)) * (32 * 4096)
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = BIG if self.path == "/big" else ("seen-from=" + self.client_address[0] + "\n").encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
def dns():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((ADDRESS, 53))
    while True:
        query, peer = s.recvfrom(2048)
        with open(sys.argv[1], "a") as log: log.write(peer[0] + "\n")
        end = 12
        while query[end] != 0: end += 1 + query[end]
        qtype = struct.unpack(">H", query[end + 1:end + 3])[0]
        name = query[12:end]
        known = name == b"\x08vpn-only\x04test"
        answers = 1 if known and qtype == 1 else 0
        flags = 0x8180 if known else 0x8183
        response = query[:2] + struct.pack(">HHHHH", flags, 1, answers, 0, 0) + query[12:end + 5]
        if answers: response += b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + socket.inet_aton(ADDRESS)
        s.sendto(response, peer)
def echo():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((ADDRESS, 7))
    while True:
        data, peer = s.recvfrom(2048); s.sendto(b"echo:" + peer[0].encode() + b":" + data, peer)
threading.Thread(target=dns, daemon=True).start()
threading.Thread(target=echo, daemon=True).start()
http.server.ThreadingHTTPServer((ADDRESS, 8080), Page).serve_forever()
EOF
: > dns-askers.log
chmod 666 dns-askers.log
python3 -I services.py "$W/dns-askers.log" &
PIDS+=($!)

# Every DNS packet on every interface while the client runs.
tcpdump -i any -n -l 'udp port 53' > "$W/dns.pcap.txt" 2>/dev/null &
PIDS+=($!)

# The client as the app starts it: a listening socket on 127.0.0.1 (fd 3) and a status pipe
# (fd 4) handed down through OpenVPN to LumenTunnel; the credentials' verifier only.
cat > client.conf <<EOF
client
dev tun
proto udp
remote 127.0.0.1 1194
nobind
ca $W/ca.crt
cert $W/client.crt
key $W/client.key
tls-crypt $W/ta.key
remote-cert-tls server
verb 3
script-security 2
dev-node unix:$TUNNEL
route-noexec
ifconfig-noexec
keepalive 2 6
EOF
cat > launch.py <<'EOF'
import hashlib, os, socket, sys
workdir, conf = sys.argv[1], sys.argv[2]
user, password = b"lumen", os.urandom(16).hex().encode()
listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(64)
status_read, status_write = os.pipe()
verifier = hashlib.sha256(b"lumen-socks-v1\0" + user + b"\0" + password).hexdigest()
with open(conf, "a") as f:
    f.write("setenv LUMEN_SOCKS_FD 3\nsetenv LUMEN_STATUS_FD 4\nsetenv LUMEN_SOCKS_VERIFIER %s\n" % verifier)
with open(os.path.join(workdir, "socks.txt"), "w") as f:
    f.write("%d %s %s\n" % (listener.getsockname()[1], user.decode(), password.decode()))
log = os.open(os.path.join(workdir, "client.log"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
pid = os.fork()
if pid == 0:
    os.close(status_read)
    # Above 4 first, so that putting them at 3 and 4 cannot close one with the other.
    listening, status = os.dup2(listener.fileno(), 30), os.dup2(status_write, 31)
    os.dup2(listening, 3); os.dup2(status, 4); os.dup2(log, 1); os.dup2(log, 2)
    os.set_inheritable(3, True); os.set_inheritable(4, True)
    os.setgid(65534); os.setuid(65534)
    os.execvp("openvpn", ["openvpn", "--config", conf])
os.close(status_write); os.close(log); listener.close()
with open(os.path.join(workdir, "client.pid"), "w") as f: f.write(str(pid))
with os.fdopen(status_read) as status, open(os.path.join(workdir, "status.log"), "a") as out:
    for line in status:
        out.write(line); out.flush()
EOF
chmod 644 client.conf
python3 -I launch.py "$W" "$W/client.conf" &
PIDS+=($!)
for _ in $(seq 1 30); do grep -q '"event":"up"' "$W/status.log" 2>/dev/null && break; sleep 0.5; done
grep -q '"event":"up"' "$W/status.log" 2>/dev/null || fail "LumenTunnel did not come up"
PIDS+=("$(cat "$W/client.pid")")
read -r PORT USER PASS < "$W/socks.txt"
echo "status: $(head -1 "$W/status.log")"
grep -q '"dns":"10.77.0.1"' "$W/status.log" || fail "the pushed DNS server did not reach LumenTunnel"
ps -o user=,args= -C openvpn | grep client.conf | grep -q '^nobody' || fail "the client does not run unprivileged"

echo "== 1. a page known only inside the tunnel"
BODY="$(curl -sS --max-time 20 --socks5-hostname "$USER:$PASS@127.0.0.1:$PORT" http://vpn-only.test:8080/)" || fail "the page did not load"
echo "$BODY"
[[ "$BODY" == "seen-from=10.77.0.2" ]] || fail "the server saw the page come from elsewhere: $BODY"
BIG="$(curl -sS --max-time 60 --socks5-hostname "$USER:$PASS@127.0.0.1:$PORT" -o /dev/null -w '%{http_code}' http://10.77.0.1:8080/)" || fail "a load by address failed"
[[ "$BIG" == "200" ]] || fail "a load by address answered $BIG"

SECONDS_TAKEN="$( { /usr/bin/time -f %e curl -sS --max-time 120 --socks5-hostname "$USER:$PASS@127.0.0.1:$PORT" -o "$W/big" http://10.77.0.1:8080/big; } 2>&1 | tail -1)"
[[ "$(stat -c %s "$W/big")" == "33554432" ]] || fail "32 MB did not come through whole"
python3 -I -c "import sys; d=open(sys.argv[1],'rb').read(); assert d == bytes(range(256)) * (32 * 4096)" "$W/big" || fail "32 MB came through changed"
echo "32 MB through the tunnel intact in ${SECONDS_TAKEN} s"

echo "== 2. DNS only through the tunnel"
sort -u "$W/dns-askers.log"
[[ "$(sort -u "$W/dns-askers.log")" == "10.77.0.2" ]] || fail "the DNS server was asked from elsewhere than the tunnel"
sleep 1
# The capture sees the question on the server's tun (from the client's tunnel address) and nowhere else.
grep -q 'vpn-only.test' "$W/dns.pcap.txt" || fail "the capture saw no question (its own control)"
if grep 'vpn-only.test' "$W/dns.pcap.txt" | grep -v '10.77.0.2.[0-9]* > 10.77.0.1.53\|10.77.0.1.53 > 10.77.0.2' | grep -q .; then
  grep 'vpn-only.test' "$W/dns.pcap.txt"
  fail "a question for the name went elsewhere than the tunnel's DNS server"
fi

echo "== 3. the SOCKS5 port's credentials"
if curl -sS --max-time 10 --socks5-hostname "127.0.0.1:$PORT" http://10.77.0.1:8080/ >/dev/null 2>&1; then fail "a client without credentials got through"; fi
if curl -sS --max-time 10 --socks5-hostname "$USER:wrong@127.0.0.1:$PORT" http://10.77.0.1:8080/ >/dev/null 2>&1; then fail "a wrong password got through"; fi
echo "refused without credentials and with a wrong password"

echo "== 4. a UDP association"
cat > udp.py <<'EOF'
import socket, struct, sys
port, user, password = int(sys.argv[1]), sys.argv[2].encode(), sys.argv[3].encode()
c = socket.create_connection(("127.0.0.1", port), timeout=10)
c.sendall(b"\x05\x01\x02"); assert c.recv(2) == b"\x05\x02"
c.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password); assert c.recv(2) == b"\x01\x00"
c.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
reply = c.recv(10); assert reply[1] == 0, reply
relay = (socket.inet_ntoa(reply[4:8]), struct.unpack(">H", reply[8:10])[0])
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(10)
u.sendto(b"\x00\x00\x00\x01" + socket.inet_aton("10.77.0.1") + struct.pack(">H", 7) + b"ping", relay)
data, _ = u.recvfrom(2048)
assert data[3] == 1 and data[4:8] == socket.inet_aton("10.77.0.1"), data
print(data[10:].decode())
assert data[10:] == b"echo:10.77.0.2:ping", data
EOF
python3 -I udp.py "$PORT" "$USER" "$PASS" || fail "the UDP association did not carry a datagram"

echo "== 5. the server killed: fail closed"
kill "$(cat "$W/server.pid")"
rm -f "$W/server.pid"
sleep 12
if curl -sS --max-time 10 --socks5-hostname "$USER:$PASS@127.0.0.1:$PORT" http://10.77.0.1:8080/ >/dev/null 2>&1; then
  fail "a page loaded with the server gone"
fi
grep -q '"event":"down"' "$W/status.log" || fail "LumenTunnel did not say it went down"
if pgrep -f "$TUNNEL" >/dev/null; then fail "LumenTunnel still runs with the tunnel down"; fi
echo "nothing loads; LumenTunnel is gone ($(grep '"event":"down"' "$W/status.log" | tail -1))"
echo "PASS"
