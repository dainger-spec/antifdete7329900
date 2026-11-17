#!/usr/bin/env bash
# OpenVPN connections end to end on a Mac (docs/OPENVPN.md, "What is tested"): an OpenVPN server on
# this Mac (root: a utun device), a profile of Lumen given a .ovpn for it, started as a person's is
# (its own process, Safari's window) through `Lumen --webdriver-serve`, and driven over WebDriver.
#
#   scripts/openvpn_macos_e2e.sh <Lumen.app built with OVPN=1> [out folder]
#
# Needs passwordless sudo (the server, its utun, the packet capture). Checks, in order — each a
# line `OPENVPN PASS …` or `OPENVPN FAIL …`, exit 1 at the first failure:
#   1. a wrong password: the launch is refused, said with why, and nothing is left running;
#   2. a page named only by the tunnel's DNS server loads in the profile, and the server sees it
#      come from the client's tunnel address — also a page by address;
#   3. the profile's SOCKS5 port refuses a client without credentials and one with wrong ones;
#   4. the server killed: nothing loads (fail closed), then the profile is stopped and said so, and
#      no OpenVPN or LumenTunnel process is left;
#   5. the capture of every packet of this Mac (pktap, with each packet's process): no packet of the
#      profile's process (or made for it) left loopback; the confined OpenVPN and LumenTunnel sent
#      none outside it; no DNS question for the tunnel's name was asked outside the tunnel — with its
#      controls: the forwarder's packets to the server, and the question inside the tunnel, are seen.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "${1:?the app built with OVPN=1}" && pwd)"
OUT="${2:-build/openvpn-e2e}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
OVPN="$APP/Contents/MacOS/openvpn"
[[ -x "$OVPN" && -x "$APP/Contents/MacOS/LumenTunnel" ]] || { echo "OPENVPN FAIL the app has no openvpn or LumenTunnel (build it with OVPN=1)"; exit 1; }
unset NO_PROXY no_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy
W="$OUT/work"
rm -rf "$W"
mkdir -p "$W"
PIDS=()
cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null; done
  [[ -f "$W/server.pid" ]] && sudo kill "$(cat "$W/server.pid")" 2>/dev/null
  sudo pkill -INT -f "tcpdump -i pktap" 2>/dev/null
  sudo pkill -f "$W/services.py" 2>/dev/null
  # The server's log is root's: a copy the run's artifact can read.
  sudo cat "$W/server.log" > "$OUT/server-log.txt" 2>/dev/null
  true
}
trap cleanup EXIT
say() { echo "$*" | tee -a "$OUT/result.txt"; }
fail() {
  say "OPENVPN FAIL $*"
  echo "--- serve.txt (last 30)"; tail -30 "$W/serve.txt" 2>/dev/null
  echo "--- server.log (last 20)"; sudo tail -20 "$W/server.log" 2>/dev/null
  exit 1
}
: > "$OUT/result.txt"
sw_vers | tr '\n' ' '; echo
"$OVPN" --version 2>&1 | head -1

# The PKI: a CA, the server's and the client's certificates, a tls-crypt key.
cd "$W"
printf 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.ext
printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature,keyAgreement\nextendedKeyUsage=serverAuth\n' > server.ext
printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature,keyAgreement\nextendedKeyUsage=clientAuth\n' > client.ext
openssl ecparam -name prime256v1 -genkey -noout -out ca.key 2>/dev/null
openssl req -new -key ca.key -subj /CN=lumen-e2e-ca -out ca.csr 2>/dev/null
openssl x509 -req -in ca.csr -signkey ca.key -days 2 -extfile ca.ext -out ca.crt 2>/dev/null
for who in server client; do
  openssl ecparam -name prime256v1 -genkey -noout -out $who.key 2>/dev/null
  openssl req -new -key $who.key -subj /CN=lumen-e2e-$who -out $who.csr 2>/dev/null
  openssl x509 -req -in $who.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile $who.ext -out $who.crt 2>/dev/null
done
"$OVPN" --genkey tls-crypt ta.key >/dev/null 2>&1 || fail "no tls-crypt key could be made"
[[ -s ta.key && -s client.crt && -s server.crt ]] || fail "the test PKI was not made"

SERVER_ADDRESS="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
[[ -n "$SERVER_ADDRESS" ]] || fail "this Mac has no address on en0 or en1 for the server"
cat > verify.sh <<'EOF'
#!/bin/sh
# The server's check of the client's user name and password.
[ "$(sed -n 1p "$1")" = "lumen-e2e" ] && [ "$(sed -n 2p "$1")" = "correct horse" ]
EOF
chmod 755 verify.sh
cat > server.conf <<EOF
port 1194
proto udp
local $SERVER_ADDRESS
dev tun
ca $W/ca.crt
cert $W/server.crt
key $W/server.key
dh none
tls-crypt $W/ta.key
topology subnet
server 10.8.0.0 255.255.255.0
push "dhcp-option DNS 10.8.0.1"
push "redirect-gateway def1"
push "route 192.0.2.0 255.255.255.0"
keepalive 2 10
script-security 2
auth-user-pass-verify $W/verify.sh via-file
verb 3
EOF
sudo "$OVPN" --config "$W/server.conf" --daemon --log "$W/server.log" --writepid "$W/server.pid" || fail "the server did not start"
for _ in $(seq 1 30); do ifconfig | grep -q "inet 10.8.0.1 " && break; sleep 0.5; done
ifconfig | grep -q "inet 10.8.0.1 " || fail "the server's utun did not come up"
say "INFO server on $SERVER_ADDRESS:1194/udp, tunnel 10.8.0.0/24"

# The far side's services, on the server's tunnel address only.
cat > services.py <<'EOF'
import socket, struct, threading, http.server
ADDRESS = "10.8.0.1"
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("<html><body>seen-from=" + self.client_address[0] + "</body></html>").encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
def dns():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((ADDRESS, 53))
    while True:
        query, peer = s.recvfrom(2048)
        end = 12
        while query[end] != 0: end += 1 + query[end]
        qtype = struct.unpack(">H", query[end + 1:end + 3])[0]
        known = query[12:end] == b"\x08vpn-only\x04test"
        answers = 1 if known and qtype == 1 else 0
        response = query[:2] + struct.pack(">HHHHH", 0x8180 if known else 0x8183, 1, answers, 0, 0) + query[12:end + 5]
        if answers: response += b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + socket.inet_aton(ADDRESS)
        s.sendto(response, peer)
threading.Thread(target=dns, daemon=True).start()
http.server.ThreadingHTTPServer((ADDRESS, 8080), Page).serve_forever()
EOF
sudo /usr/bin/python3 -I "$W/services.py" > "$W/services.log" 2>&1 &
for _ in $(seq 1 30); do sudo lsof -nP -iTCP@10.8.0.1:8080 -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.5; done
if ! sudo lsof -nP -iTCP@10.8.0.1:8080 -sTCP:LISTEN >/dev/null 2>&1 || ! sudo lsof -nP -iUDP@10.8.0.1:53 >/dev/null 2>&1; then
  echo "--- services.log"; cat "$W/services.log"
  fail "the server's page and DNS do not listen on 10.8.0.1"
fi
# Asked from this Mac directly (not through the tunnel), the page sees another address than the
# client's, or does not answer at all (macOS sends what is for a utun's own point-to-point address
# into the utun): either way not 10.8.0.2, which only the tunnel gives.
DIRECT="$(curl -s --noproxy '*' --max-time 5 http://10.8.0.1:8080/ | sed 's/<[^>]*>//g')"
say "INFO the page, asked from this Mac directly: ${DIRECT:-no answer}; through the tunnel it must see 10.8.0.2"
[[ "$DIRECT" != "seen-from=10.8.0.2" ]] || fail "the page sees the client's tunnel address without the tunnel"

# Every packet of this Mac but loopback's, with the process each is counted for.
sudo tcpdump -i pktap,all -k NP -n -tt -l 'not host 127.0.0.1 and not host ::1' > "$OUT/capture.txt" 2> "$W/tcpdump.err" &
sleep 2

# The client's configuration, as a provider gives it: everything inline.
cat > client.ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_ADDRESS 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
auth-user-pass
verb 3
<ca>
$(cat ca.crt)
</ca>
<cert>
$(cat client.crt)
</cert>
<key>
$(cat client.key)
</key>
<tls-crypt>
$(cat ta.key)
</tls-crypt>
EOF

serve() { # serve <password> <log>
  PRIVACYBROWSER_LANG=en PB_WEBDRIVER_OPENVPN="$W/client.ovpn" PB_WEBDRIVER_OPENVPN_USER=lumen-e2e \
    PB_WEBDRIVER_OPENVPN_PASSWORD="$1" PB_OPENVPN_RECONNECT_GRACE=12 PB_OPENVPN_ECHO_LOG=1 \
    "$APP/Contents/MacOS/Lumen" --webdriver-serve > "$2" 2>&1 &
  SERVE=$!
  PIDS+=("$SERVE")
  ADDRESS=""
  for _ in $(seq 1 120); do
    ADDRESS="$(sed -n 's/^WEBDRIVER ADDRESS //p' "$2" | head -1)"
    [[ -n "$ADDRESS" ]] && break
    kill -0 "$SERVE" 2>/dev/null || break
    sleep 0.5
  done
  [[ -n "$ADDRESS" ]] || fail "the app gave no WebDriver address ($(grep FAIL "$2" | head -1))"
}

echo "== 1. a wrong password"
serve "wrong horse" "$W/serve-wrong.txt"
python3 -I "$HERE/openvpn_e2e_check.py" refused "$ADDRESS" | tee -a "$OUT/result.txt"
[[ ${PIPESTATUS[0]} == 0 ]] || fail "a wrong password was not refused as such"
kill "$SERVE" 2>/dev/null; wait "$SERVE" 2>/dev/null
sleep 2
if pgrep -f "$APP/Contents/MacOS/openvpn" >/dev/null || pgrep -f "$APP/Contents/MacOS/LumenTunnel" >/dev/null; then
  fail "an OpenVPN process was left after the refused launch"
fi

echo "== 2. pages through the tunnel"
serve "correct horse" "$W/serve.txt"
python3 -I "$HERE/openvpn_e2e_check.py" pages "$ADDRESS" "$W/session.txt" | tee -a "$OUT/result.txt"
[[ ${PIPESTATUS[0]} == 0 ]] || fail "the profile's pages did not come through the tunnel"

echo "== 3. the SOCKS5 port's credentials"
PORT="$(lsof -nP -a -c LumenTunn -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { split($9, a, ":"); print a[2]; exit }')"
[[ -n "$PORT" ]] || fail "LumenTunnel's port was not found"
lsof -nP -a -c LumenTunn -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | grep -v '^127\.0\.0\.1:' && fail "LumenTunnel listens elsewhere than on 127.0.0.1"
if curl -s --max-time 10 --socks5-hostname "127.0.0.1:$PORT" http://10.8.0.1:8080/ >/dev/null 2>&1; then fail "a client without credentials got through"; fi
if curl -s --max-time 10 --socks5-hostname "lumen:wrong@127.0.0.1:$PORT" http://10.8.0.1:8080/ >/dev/null 2>&1; then fail "a client with wrong credentials got through"; fi
say "OPENVPN PASS the SOCKS5 port (127.0.0.1:$PORT) refuses a client without credentials and one with wrong ones"

echo "== 4. the server killed"
sudo kill "$(cat "$W/server.pid")"
sudo rm -f "$W/server.pid"
python3 -I "$HERE/openvpn_e2e_check.py" closed "$ADDRESS" "$W/session.txt" | tee -a "$OUT/result.txt"
[[ ${PIPESTATUS[0]} == 0 ]] || fail "a page loaded with the server gone"
for _ in $(seq 1 60); do grep -q "its OpenVPN connection went down" "$W/serve.txt" && break; sleep 1; done
grep -q "its OpenVPN connection went down" "$W/serve.txt" || fail "the profile was not stopped with the tunnel gone"
sleep 4
if pgrep -f "$APP/Contents/MacOS/openvpn" >/dev/null || pgrep -f "$APP/Contents/MacOS/LumenTunnel" >/dev/null; then
  pgrep -fl "$APP/Contents/MacOS/" || true
  fail "OpenVPN or LumenTunnel still runs after the profile was stopped"
fi
say "OPENVPN PASS the server gone: nothing loaded, the profile was stopped and said so, nothing of the tunnel is left"
kill "$SERVE" 2>/dev/null

echo "== 5. the capture"
sleep 2
sudo pkill -INT -f "tcpdump -i pktap" 2>/dev/null
sleep 2
python3 -I "$HERE/openvpn_e2e_check.py" capture "$OUT/capture.txt" "$SERVER_ADDRESS" | tee -a "$OUT/result.txt"
[[ ${PIPESTATUS[0]} == 0 ]] || fail "the capture shows traffic around the tunnel"
say "OPENVPN PASS all of it"
