#!/bin/bash
# Scratch: can OpenVPN 2.7 run unprivileged on macOS with its AF_UNIX tun (--dev-node unix:),
# confined by a sandbox to loopback, reaching its server only through a forwarder?
set -uo pipefail
W="${RUNNER_TEMP:-/tmp}/ovpn"
OUT="$W/out"
mkdir -p "$W/src" "$OUT" "$W/pki" "$W/run"
cd "$W/src"
JOBS=$(sysctl -n hw.ncpu)
sw_vers
which sandbox-exec || echo "NO sandbox-exec"

fetch() {
  curl -fsSL --retry 3 -o "$2" "$1" || { echo "FETCH FAILED $1"; return 1; }
  shasum -a 256 "$2"
}
fetch https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.5/mbedtls-3.6.5.tar.bz2 mbedtls.tar.bz2
fetch https://swupdate.openvpn.org/community/releases/openvpn-2.7.9.tar.gz openvpn.tar.gz \
  || fetch https://github.com/OpenVPN/openvpn/releases/download/v2.7.9/openvpn-2.7.9.tar.gz openvpn.tar.gz
fetch https://www.oberhumer.com/opensource/lzo/download/lzo-2.10.tar.gz lzo.tar.gz
fetch https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz lz4.tar.gz
tar xjf mbedtls.tar.bz2 && tar xzf openvpn.tar.gz && tar xzf lzo.tar.gz && tar xzf lz4.tar.gz
ls

build_arch() {
  local arch=$1 host=$2
  local P="$W/prefix-$arch"
  local CF="-arch $arch -mmacosx-version-min=14.0 -O2"
  mkdir -p "$P"
  (cd mbedtls-3.6.5 && rm -rf build-$arch && cmake -S . -B build-$arch -DCMAKE_BUILD_TYPE=Release \
     -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DCMAKE_OSX_ARCHITECTURES=$arch \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_INSTALL_PREFIX="$P" >/dev/null \
     && cmake --build build-$arch -j $JOBS >/dev/null && cmake --install build-$arch >/dev/null) || { echo "mbedtls $arch failed"; return 1; }
  (cd lzo-2.10 && make distclean >/dev/null 2>&1; ./configure --host=$host --prefix="$P" --disable-shared --enable-static CFLAGS="$CF" >/dev/null \
     && make -j $JOBS >/dev/null && make install >/dev/null) || { echo "lzo $arch failed"; return 1; }
  (cd lz4-1.10.0/lib && make clean >/dev/null 2>&1; make -j $JOBS liblz4.a CFLAGS="$CF" >/dev/null \
     && mkdir -p "$P/include" "$P/lib" && cp lz4.h lz4hc.h lz4frame.h "$P/include/" && cp liblz4.a "$P/lib/") || { echo "lz4 $arch failed"; return 1; }
  (cd openvpn-2.7.9 && make distclean >/dev/null 2>&1; ./configure --host=$host --with-crypto-library=mbedtls \
     --disable-plugins --disable-plugin-auth-pam --disable-plugin-down-root --disable-dco --disable-unit-tests \
     --disable-debug --enable-lzo --enable-lz4 \
     CFLAGS="$CF" LDFLAGS="-arch $arch" \
     MBEDTLS_CFLAGS="-I$P/include" MBEDTLS_LIBS="$P/lib/libmbedtls.a $P/lib/libmbedx509.a $P/lib/libmbedcrypto.a" \
     LZO_CFLAGS="-I$P/include" LZO_LIBS="$P/lib/liblzo2.a" LZ4_CFLAGS="-I$P/include" LZ4_LIBS="$P/lib/liblz4.a" > "$OUT/configure-$arch.log" 2>&1 \
     && make -j $JOBS > "$OUT/make-$arch.log" 2>&1 && cp src/openvpn/openvpn "$W/openvpn-$arch") || { echo "openvpn $arch failed"; tail -40 "$OUT/configure-$arch.log"; tail -40 "$OUT/make-$arch.log"; return 1; }
}
build_arch arm64 aarch64-apple-darwin || exit 1
build_arch x86_64 x86_64-apple-darwin || echo "x86_64 build failed (size estimate only)"
if [ -f "$W/openvpn-x86_64" ]; then lipo -create "$W/openvpn-arm64" "$W/openvpn-x86_64" -output "$W/openvpn-universal"; fi
strip -x "$W/openvpn-arm64" -o "$W/openvpn"
ls -l "$W"/openvpn*
[ -f "$W/openvpn-universal" ] && strip -x "$W/openvpn-universal" -o "$W/openvpn-universal-stripped" && ls -l "$W/openvpn-universal-stripped"
otool -L "$W/openvpn"
"$W/openvpn" --version | head -3
OVPN="$W/openvpn"

# lwipovpn as a stand-in for our stack: does the AF_UNIX tun reach a program on macOS?
git clone -q --recursive https://github.com/OpenVPN/lwipovpn "$W/lwipovpn" && cmake -S "$W/lwipovpn" -B "$W/lwipovpn-build" >/dev/null \
  && cmake --build "$W/lwipovpn-build" -j $JOBS > "$OUT/lwipovpn-build.log" 2>&1 || { echo "lwipovpn build failed"; tail -30 "$OUT/lwipovpn-build.log"; }
ls -l "$W/lwipovpn-build/lwipovpn" || true

# PKI
cd "$W/pki"
cat > ca.ext <<'EOF'
basicConstraints=critical,CA:true
keyUsage=critical,keyCertSign,cRLSign
EOF
cat > server.ext <<'EOF'
basicConstraints=CA:false
keyUsage=critical,digitalSignature,keyAgreement
extendedKeyUsage=serverAuth
EOF
cat > client.ext <<'EOF'
basicConstraints=CA:false
keyUsage=critical,digitalSignature,keyAgreement
extendedKeyUsage=clientAuth
EOF
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -new -key ca.key -subj /CN=Spike-CA -out ca.csr
openssl x509 -req -in ca.csr -signkey ca.key -days 30 -extfile ca.ext -out ca.crt
for who in server client; do
  openssl ecparam -name prime256v1 -genkey -noout -out $who.key
  openssl req -new -key $who.key -subj /CN=$who -out $who.csr
  openssl x509 -req -in $who.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile $who.ext -out $who.crt
done
"$OVPN" --genkey tls-crypt ta.key || "$OVPN" --genkey secret ta.key

EN0=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
echo "server address: $EN0"
cat > server.conf <<EOF
port 1194
proto udp
local $EN0
dev tun
ca $W/pki/ca.crt
cert $W/pki/server.crt
key $W/pki/server.key
dh none
tls-crypt $W/pki/ta.key
topology subnet
server 10.8.0.0 255.255.255.0
push "dhcp-option DNS 10.8.0.1"
push "dhcp-option DOMAIN spike.test"
push "redirect-gateway def1"
keepalive 2 10
verb 3
EOF
sudo "$OVPN" --config server.conf --daemon --log "$OUT/server.log" --writepid "$W/run/server.pid"
sleep 3
tail -5 "$OUT/server.log"
ifconfig | grep -A3 utun | head -20

# The forwarder: loopback to the server, the only way out.
cat > "$W/fwd.py" <<'EOF'
import socket, select, sys
listen_port, target_host, target_port = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
a = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); a.bind(("127.0.0.1", listen_port))
b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); b.connect((target_host, target_port))
client = None
while True:
    r, _, _ = select.select([a, b], [], [])
    if a in r:
        data, addr = a.recvfrom(65535)
        if client is None: client = addr
        if addr == client: b.send(data)
    if b in r:
        data = b.recv(65535)
        if client: a.sendto(data, client)
EOF
python3 "$W/fwd.py" 21194 "$EN0" 1194 &
FWD_PID=$!

cat > "$W/tunprog.sh" <<EOF
#!/bin/sh
env | sort > "$OUT/tunprog-env.txt"
exec "$W/lwipovpn-build/lwipovpn"
EOF
chmod +x "$W/tunprog.sh"

cat > "$W/confine.sb" <<'EOF'
(version 1)
(allow default)
(deny network*)
(allow network-outbound (remote ip "localhost:*"))
(allow network-inbound (local ip "localhost:*"))
(allow network-bind (local ip "localhost:*"))
EOF

client_conf() {
cat <<EOF
client
dev tun
proto udp
remote $1 $2
nobind
ca $W/pki/ca.crt
cert $W/pki/client.crt
key $W/pki/client.key
tls-crypt $W/pki/ta.key
remote-cert-tls server
verb 4
script-security 2
dev-node unix:$W/tunprog.sh
connect-retry-max 2
server-poll-timeout 8
EOF
}

echo "=== control: confined client straight to the server must not connect"
client_conf "$EN0" 1194 > "$W/direct.conf"
timeout 20 sandbox-exec -f "$W/confine.sb" "$OVPN" --config "$W/direct.conf" > "$OUT/direct.log" 2>&1
grep -E "Operation not permitted|Initialization Sequence Completed|error" "$OUT/direct.log" | head -5
if grep -q "Initialization Sequence Completed" "$OUT/direct.log"; then echo "CONTROL FAILED: confined client reached the server directly"; else echo "control ok: no direct connection"; fi

echo "=== confined client through the loopback forwarder"
client_conf 127.0.0.1 21194 > "$W/client.conf"
sandbox-exec -f "$W/confine.sb" "$OVPN" --config "$W/client.conf" > "$OUT/client.log" 2>&1 &
CLIENT_PID=$!
for i in $(seq 1 30); do grep -q "Initialization Sequence Completed" "$OUT/client.log" && break; sleep 1; done
grep -E "Initialization Sequence Completed|AF_UNIX|device|PUSH|ERROR|Operation not permitted" "$OUT/client.log" | head -20
echo "=== env given to the tun program"
cat "$OUT/tunprog-env.txt" 2>/dev/null | grep -v -i -E "^(password|username)=" || echo "no env file"
echo "=== through the tunnel"
ping -c 3 -t 5 10.8.0.2 || true
echo hello-through-tunnel | nc -w 3 10.8.0.2 7 || true
curl -s --max-time 8 -o /dev/null -w "httpd: %{http_code}\n" http://10.8.0.2/ || true
echo "=== sandbox denials"
log show --last 3m --style compact --predicate 'sender == "Sandbox"' 2>/dev/null | grep -i -E "openvpn|lwipovpn|tunprog" | head -20

echo "=== kill the server: the client notices"
sudo kill "$(cat "$W/run/server.pid")"
sleep 25
tail -15 "$OUT/client.log"
kill $CLIENT_PID $FWD_PID 2>/dev/null
cp "$W/openvpn" "$OUT/" ; cp "$W/openvpn-universal-stripped" "$OUT/" 2>/dev/null
exit 0
