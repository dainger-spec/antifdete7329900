#!/bin/bash
# VMNetCore against a real TCP/IP stack: Linux's own, in a network namespace.
#
#     scripts/vmnet_interop.sh            (as root, in a privileged Linux container)
#
# The unit tests drive VMNetCore's TCP with a scripted guest. This drives it with the kernel: a
# network namespace "guest" whose only interface is a TAP device, and at the other end of that
# device — where a virtual machine's frames would arrive — vmnet-interop, which is VMNetCore and
# nothing else. Whatever curl, dig and ping do inside the namespace, they do through the stack.
#
# The stack's way out is a test double of a proxy on 127.0.0.1 (SOCKS5, then HTTP CONNECT), which
# sends every host name it is asked for to a test origin on 127.0.0.1. Both are small Python
# programs written out by this script. Nothing here reaches the internet.
#
# One line per check, PASS or FAIL, the throughput of the large download in MB/s, and a non-zero
# exit when anything failed. TAP is used (IFF_TAP | IFF_NO_PI): the script stops with a FAIL line
# when /dev/net/tun cannot be opened.
#
# It needs: ip (iproute2), ping, dig, curl, python3, sha256sum; udhcpc if DHCP is to be checked
# against a real client (without it the namespace is configured by hand and the check is skipped).
# In a fresh swift:6.0-noble container:
#     apt-get install -y python3 curl iproute2 iputils-ping dnsutils udhcpc
# and the program itself: swift build -c release --product vmnet-interop (the script builds it
# when it is not there).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${VMNET_INTEROP_BIN:-$ROOT/.build/release/vmnet-interop}"
WORK="$(mktemp -d /tmp/vmnet-interop.XXXXXX)"
NS=guest
TAP=vmtap0
GUEST_MAC=52:54:00:12:34:56
GUEST_IP=192.168.1.23
GATEWAY=192.168.1.1
ORIGIN_PORT=18080
HALF_PORT=18081
SOCKS_PORT=11080
SOCKS_AUTH_PORT=11081
HTTP_PORT=13128
G="ip netns exec $NS"
FAILED=0
STACK_PID=""
DOUBLES_PID=""

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=$((FAILED + 1)); }
note() { echo "      $1"; }
# check NAME COMMAND...: PASS when the command succeeds.
check() {
    local name="$1"; shift
    if "$@" >"$WORK/last.out" 2>&1; then pass "$name"; else fail "$name"; sed 's/^/      | /' "$WORK/last.out" | head -12; fi
}

cleanup() {
    [ -n "$STACK_PID" ] && kill "$STACK_PID" 2>/dev/null
    [ -n "$DOUBLES_PID" ] && kill "$DOUBLES_PID" 2>/dev/null
    wait 2>/dev/null
    ip netns del "$NS" 2>/dev/null
    rm -rf /etc/netns/"$NS"
    [ "${VMNET_INTEROP_KEEP:-0}" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

for tool in ip ping dig curl python3 sha256sum; do
    command -v "$tool" >/dev/null || { echo "FAIL  the script needs '$tool' (see its header)"; exit 2; }
done
[ "$(id -u)" = 0 ] || { echo "FAIL  the script needs root (network namespaces, a TAP device)"; exit 2; }
if [ ! -x "$BIN" ]; then
    echo "building vmnet-interop (release)…"
    (cd "$ROOT" && swift build -c release --product vmnet-interop >"$WORK/build.log" 2>&1) || { tail -20 "$WORK/build.log"; echo "FAIL  build"; exit 2; }
fi
# The guest's programs must go where the guest's routes send them: a proxy set in this shell's
# environment (a CI runner's own) is not the guest's.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
[ -c /dev/net/tun ] || { mkdir -p /dev/net && mknod /dev/net/tun c 10 200 2>/dev/null; }
[ -c /dev/net/tun ] || { echo "FAIL  no /dev/net/tun: the container needs --privileged (or --cap-add NET_ADMIN --device /dev/net/tun)"; exit 2; }

# ---------------------------------------------------------------------------------------------
# The test doubles: an origin, a server for half-closed connections, two proxies.
# ---------------------------------------------------------------------------------------------
cat >"$WORK/doubles.py" <<'PYTHON'
import hashlib, http.server, os, socket, socketserver, sys, threading, time, base64

work, origin_port, half_port, socks_port, socks_auth_port, http_port = sys.argv[1], *map(int, sys.argv[2:7])
log_lock = threading.Lock()

def log(name, line):
    with log_lock:
        with open(os.path.join(work, name), "a") as f:
            f.write(line + "\n")

class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def do_GET(self):
        path = {"/big": "big.bin", "/mid": "mid.bin"}.get(self.path)
        if path:
            full = os.path.join(work, path)
            self.send_response(200)
            self.send_header("Content-Length", str(os.path.getsize(full)))
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            with open(full, "rb") as f:
                while True:
                    chunk = f.read(1 << 20)
                    if not chunk: break
                    self.wfile.write(chunk)
        else:
            body = b"hello from the origin\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            if self.headers.get("Connection", "").lower() == "close":
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            self.wfile.write(body)
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        digest = hashlib.sha256()
        slow = self.path == "/slowupload"
        left = length
        while left > 0:
            chunk = self.rfile.read(min(left, 256 * 1024))
            if not chunk: break
            digest.update(chunk)
            left -= len(chunk)
            if slow: time.sleep(0.04)
        body = (digest.hexdigest() + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 256

def serve(port, handler):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(256)
    def loop():
        while True:
            connection, _ = listener.accept()
            threading.Thread(target=guarded, args=(handler, connection), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()

def guarded(handler, connection):
    try:
        handler(connection)
    except Exception as error:
        log("doubles.err", repr(error))
    finally:
        try: connection.close()
        except OSError: pass

# Reads to the end of what the client sends, then answers with its SHA-256: only a client whose
# FIN arrives while the connection stays open the other way gets an answer.
def half_close(connection):
    digest = hashlib.sha256()
    while True:
        chunk = connection.recv(65536)
        if not chunk: break
        digest.update(chunk)
    connection.sendall((digest.hexdigest() + "\n").encode())

def exactly(connection, count):
    data = b""
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk: raise EOFError("closed")
        data += chunk
    return data

def pump(source, sink):
    try:
        while True:
            chunk = source.recv(262144)
            if not chunk: break
            sink.sendall(chunk)
    except OSError:
        pass
    try: sink.shutdown(socket.SHUT_WR)
    except OSError: pass

# Every name goes to the origin; port 7001 to the half-close server.
def relay(connection, port, ready):
    target = socket.create_connection(("127.0.0.1", half_port if port == 7001 else origin_port))
    target.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    connection.sendall(ready)
    back = threading.Thread(target=pump, args=(target, connection), daemon=True)
    back.start()
    pump(connection, target)
    back.join()
    target.close()

def socks(credentials, name):
    def handler(connection):
        version, count = exactly(connection, 2)
        methods = exactly(connection, count)
        if credentials:
            if 2 not in methods:
                connection.sendall(b"\x05\xff"); return
            connection.sendall(b"\x05\x02")
            exactly(connection, 1)
            user = exactly(connection, exactly(connection, 1)[0])
            password = exactly(connection, exactly(connection, 1)[0])
            if (user.decode(), password.decode()) != credentials:
                log(name, "auth rejected")
                connection.sendall(b"\x01\x01"); return
            log(name, "auth ok")
            connection.sendall(b"\x01\x00")
        else:
            connection.sendall(b"\x05\x00")
        version, command, _, kind = exactly(connection, 4)
        if kind == 3:
            host = exactly(connection, exactly(connection, 1)[0]).decode()
            what = "name"
        elif kind == 1:
            host = socket.inet_ntoa(exactly(connection, 4))
            what = "addr"
        else:
            connection.sendall(b"\x05\x08\x00\x01" + bytes(6)); return
        port = int.from_bytes(exactly(connection, 2), "big")
        log(name, "%s %s:%d" % (what, host, port))
        if host == "refused.test":
            connection.sendall(b"\x05\x05\x00\x01" + bytes(6)); return
        if host == "silent.test":
            time.sleep(60); return
        relay(connection, port, b"\x05\x00\x00\x01" + bytes(6))
    return handler

def http_connect(credentials, name):
    def handler(connection):
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = connection.recv(4096)
            if not chunk: return
            head += chunk
        lines = head.split(b"\r\n")
        method, authority, _ = lines[0].decode().split(" ")
        headers = {l.split(b":", 1)[0].strip().lower(): l.split(b":", 1)[1].strip() for l in lines[1:] if b":" in l}
        host, port = authority.rsplit(":", 1)
        log(name, "%s %s host=%s" % (method, authority, headers.get(b"host", b"").decode()))
        if credentials:
            expected = b"Basic " + base64.b64encode(("%s:%s" % credentials).encode())
            if headers.get(b"proxy-authorization") != expected:
                log(name, "auth rejected")
                connection.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\nContent-Length: 0\r\n\r\n"); return
            log(name, "auth ok")
        if host == "refused.test":
            connection.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"); return
        relay(connection, int(port), b"HTTP/1.1 200 Connection established\r\n\r\n")
    return handler

serve(half_port, half_close)
serve(socks_port, socks(None, "socks.log"))
serve(socks_auth_port, socks(("user", "secret"), "socks-auth.log"))
serve(http_port, http_connect(("user", "secret"), "http.log"))
origin = Threaded(("127.0.0.1", origin_port), Origin)
open(os.path.join(work, "doubles.ready"), "w").close()
origin.serve_forever()
PYTHON

# What a guest's programs do that curl cannot: half-close, a slow reader, UDP.
cat >"$WORK/guest.py" <<'PYTHON'
import hashlib, socket, sys, time

def half_close(host, port, path):
    data = open(path, "rb").read()
    s = socket.create_connection((host, port), timeout=20)
    s.sendall(data)
    s.shutdown(socket.SHUT_WR)
    answer = b""
    while True:
        chunk = s.recv(4096)
        if not chunk: break
        answer += chunk
    print(answer.decode().strip())

# A reader slower than the sender, with a small receive buffer: its window shuts again and again.
def slow_reader(host, path):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
    s.settimeout(30)
    s.connect((host, 80))
    s.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % (path, host)).encode())
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
        time.sleep(0.004)
    body = data.split(b"\r\n\r\n", 1)[1]
    print(hashlib.sha256(body).hexdigest())

def udp(host, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    s.connect((host, port))
    started = time.time()
    try:
        s.send(b"is anybody there")
        s.recv(100)
        print("answered")
    except ConnectionRefusedError:
        print("refused after %.2f s" % (time.time() - started))
    except socket.timeout:
        print("timeout")

# What connect() itself says: "refused" is the stack's reset, as from a closed port.
def connect(host, port):
    started = time.time()
    try:
        socket.create_connection((host, port), timeout=10).close()
        print("connected after %.2f s" % (time.time() - started))
    except ConnectionRefusedError:
        print("refused after %.2f s" % (time.time() - started))
    except socket.timeout:
        print("timeout after %.2f s" % (time.time() - started))
    except OSError as error:
        print("failed after %.2f s: %s" % (time.time() - started, error))

# Reads a page to the server's FIN and then keeps its own side open for a while, as a browser
# keeps a connection it may use again.
def stay(host, seconds):
    s = socket.create_connection((host, 80), timeout=20)
    s.sendall(("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % host).encode())
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
    print("got the page" if b"hello from the origin" in data else "no page")
    sys.stdout.flush()
    time.sleep(seconds)
    s.close()

if sys.argv[1] == "half": half_close(sys.argv[2], int(sys.argv[3]), sys.argv[4])
elif sys.argv[1] == "stay": stay(sys.argv[2], float(sys.argv[3]))
elif sys.argv[1] == "connect": connect(sys.argv[2], int(sys.argv[3]))
elif sys.argv[1] == "slow": slow_reader(sys.argv[2], sys.argv[3])
elif sys.argv[1] == "udp": udp(sys.argv[2], int(sys.argv[3]))
PYTHON

# udhcpc's script: note what the lease says, and configure the interface from it.
cat >"$WORK/udhcpc.sh" <<EOF
#!/bin/sh
[ "\$1" = bound ] || exit 0
echo "ip=\$ip router=\$router dns=\$dns subnet=\$subnet lease=\$lease serverid=\$serverid mtu=\$mtu" >"$WORK/lease"
ip addr add "\$ip/\$mask" dev "\$interface"
ip route add default via "\$router"
EOF
chmod +x "$WORK/udhcpc.sh"

echo "preparing test data (64 MB, 32 MB, 8 MB)…"
head -c $((64 * 1024 * 1024)) /dev/urandom >"$WORK/big.bin"
head -c $((8 * 1024 * 1024)) /dev/urandom >"$WORK/mid.bin"
head -c $((32 * 1024 * 1024)) /dev/urandom >"$WORK/up.bin"
head -c $((1024 * 1024)) /dev/urandom >"$WORK/half.bin"
BIG_SHA=$(sha256sum <"$WORK/big.bin" | cut -d' ' -f1)
MID_SHA=$(sha256sum <"$WORK/mid.bin" | cut -d' ' -f1)
UP_SHA=$(sha256sum <"$WORK/up.bin" | cut -d' ' -f1)
HALF_SHA=$(sha256sum <"$WORK/half.bin" | cut -d' ' -f1)

python3 "$WORK/doubles.py" "$WORK" $ORIGIN_PORT $HALF_PORT $SOCKS_PORT $SOCKS_AUTH_PORT $HTTP_PORT >"$WORK/doubles.out" 2>&1 &
DOUBLES_PID=$!
for _ in $(seq 100); do [ -e "$WORK/doubles.ready" ] && break; sleep 0.1; done
[ -e "$WORK/doubles.ready" ] || { cat "$WORK/doubles.out"; echo "FAIL  the test doubles did not start"; exit 2; }

ip netns del "$NS" 2>/dev/null
ip netns add "$NS"
mkdir -p /etc/netns/"$NS"
echo "nameserver $GATEWAY" >/etc/netns/"$NS"/resolv.conf

# start_stack UPSTREAM [more options]: the stack on a new TAP device, the device in the namespace.
start_stack() {
    local upstream="$1"; shift
    rm -f "$WORK/go" "$WORK/lease"
    : >"$WORK/stack.out"
    "$BIN" --tap "$TAP" --upstream "$upstream" --guest-mac "$GUEST_MAC" --block blocked.test --wait-file "$WORK/go" --verbose "$@" \
        >"$WORK/stack.out" 2>&1 &
    STACK_PID=$!
    for _ in $(seq 100); do grep -q '^READY' "$WORK/stack.out" && break; sleep 0.05; done
    grep -q '^READY' "$WORK/stack.out" || { cat "$WORK/stack.out"; fail "the stack did not open its TAP device"; exit 1; }
    ip link set "$TAP" netns "$NS"
    ip -n "$NS" link set lo up
    ip -n "$NS" link set "$TAP" address "$GUEST_MAC"
    ip -n "$NS" link set "$TAP" up
    touch "$WORK/go"
    for _ in $(seq 100); do grep -q '^STARTED' "$WORK/stack.out" && break; sleep 0.05; done
    if command -v udhcpc >/dev/null; then
        $G udhcpc -i "$TAP" -n -q -f -t 5 -T 1 -s "$WORK/udhcpc.sh" >"$WORK/udhcpc.out" 2>&1
    fi
    if [ ! -s "$WORK/lease" ]; then
        ip -n "$NS" addr add "$GUEST_IP/24" dev "$TAP"
        ip -n "$NS" route add default via "$GATEWAY"
    fi
}

# stop_stack: ends the program; its counters are in $COUNTERS.
stop_stack() {
    kill -TERM "$STACK_PID" 2>/dev/null
    wait "$STACK_PID" 2>/dev/null
    STACK_STATUS=$?
    STACK_PID=""
    COUNTERS="$(grep '^COUNTERS' "$WORK/stack.out")"
    cp "$WORK/stack.out" "$WORK/stack.$(date +%s%N).log"
}
counter() { echo "$COUNTERS" | tr ' ' '\n' | grep "^$1=" | cut -d= -f2; }

sha_of() { sha256sum <"$1" | cut -d' ' -f1; }
# The CPU time the stack has used so far, in clock ticks (user + system).
stack_ticks() { awk '{ print $14 + $15 }' "/proc/$STACK_PID/stat"; }
# quiet_for SECONDS: PASS when the stack used next to no CPU meanwhile (at most 3 ticks: 30 ms).
quiet_for() {
    local before after
    before=$(stack_ticks)
    sleep "$1"
    after=$(stack_ticks)
    echo "CPU ticks used in $1 s: $((after - before))"
    [ $((after - before)) -le 3 ]
}
# refused_fast LIMIT HOST: a connection that must be refused, and fast. PASS when connect() fails
# with ECONNREFUSED (the stack's reset) and curl gives up with "couldn't connect" (exit 7), each
# within LIMIT seconds — a timeout, or any other failure, is a FAIL.
refused_fast() {
    local limit="$1" host="$2" started ended status answer
    answer="$($G python3 "$WORK/guest.py" connect "$host" 80)"
    echo "connect(): $answer"
    started=$(date +%s.%N)
    $G curl -sS --max-time 20 -o /dev/null "http://$host/" 2>"$WORK/curl.err"
    status=$?
    ended=$(date +%s.%N)
    cat "$WORK/curl.err"
    echo "curl: exit $status after $(python3 -c "print('%.2f' % ($ended - $started))") s"
    echo "$answer" | grep -q '^refused' || return 1
    [ $status = 7 ] || return 1
    python3 -c "import sys; sys.exit(0 if $ended - $started < $limit and float('$answer'.split()[2]) < $limit else 1)"
}

# ---------------------------------------------------------------------------------------------
echo "== SOCKS5 proxy =="
start_stack "socks5://127.0.0.1:$SOCKS_PORT"

if [ -s "$WORK/lease" ]; then
    LEASE="$(cat "$WORK/lease")"
    check "DHCP: a real client (udhcpc) gets the guest's address, the gateway as router and DNS, a day's lease" \
        test "$LEASE" = "ip=$GUEST_IP router=$GATEWAY dns=$GATEWAY subnet=255.255.255.0 lease=86400 serverid=$GATEWAY mtu=1500"
    note "$LEASE"
else
    echo "SKIP  DHCP against a real client: udhcpc is not installed (the namespace was configured by hand)"
fi

check "ping the gateway" $G ping -c 3 -i 0.2 -W 2 "$GATEWAY"
check "ping anything else gets no answer" bash -c "! $G ping -c 1 -W 1 8.8.8.8"

FAKE=$($G dig +short +time=2 +tries=1 A big.test @"$GATEWAY")
check "dig A: an address from the fake pool ($FAKE)" bash -c "echo '$FAKE' | grep -qE '^198\.1[89]\.[0-9]+\.[0-9]+$'"
check "dig A again: the same address" test "$($G dig +short +time=2 +tries=1 A BIG.test @"$GATEWAY")" = "$FAKE"
check "dig AAAA: no error, no answer" bash -c "$G dig +time=2 +tries=1 AAAA big.test @$GATEWAY | grep -q 'status: NOERROR' && $G dig +time=2 +tries=1 AAAA big.test @$GATEWAY | grep -q 'ANSWER: 0'"
check "dig HTTPS (type 65): no error, no answer" bash -c "$G dig +time=2 +tries=1 TYPE65 big.test @$GATEWAY | grep -q 'status: NOERROR' && $G dig +time=2 +tries=1 TYPE65 big.test @$GATEWAY | grep -q 'ANSWER: 0'"
check "dig a blocked name: NXDOMAIN" bash -c "$G dig +time=2 +tries=1 A www.blocked.test @$GATEWAY | grep -q 'status: NXDOMAIN'"
check "dig @8.8.8.8 A: the same fake address, from the stack" test "$($G dig +short +time=2 +tries=1 A big.test @8.8.8.8)" = "$FAKE"
check "dig @8.8.8.8 AAAA: no error, no answer" bash -c "$G dig +time=2 +tries=1 AAAA big.test @8.8.8.8 | grep -q 'status: NOERROR' && $G dig +time=2 +tries=1 AAAA big.test @8.8.8.8 | grep -q 'ANSWER: 0'"
check "dig @8.8.8.8 a blocked name: NXDOMAIN" bash -c "$G dig +time=2 +tries=1 A www.blocked.test @8.8.8.8 | grep -q 'status: NXDOMAIN'"
check "the system resolver (resolv.conf) gets the fake address" bash -c "$G getent ahostsv4 big.test | grep -q '^$FAKE '"

check "a small page through the stack" bash -c "$G curl -sS --max-time 20 http://small.test/ | grep -q 'hello from the origin'"
check "the proxy was asked for the NAME, not an address" grep -qx "name small.test:80" "$WORK/socks.log"

SPEED=$($G curl -sS --max-time 300 -o "$WORK/big.out" -w '%{speed_download}' http://big.test/big 2>"$WORK/curl.err")
check "download 64 MB: SHA-256 matches" test "$(sha_of "$WORK/big.out")" = "$BIG_SHA"
MBPS=$(python3 -c "print('%.1f' % (float('${SPEED:-0}') / 1e6))")
echo "      throughput (64 MB download, guest kernel → stack → SOCKS5 double → origin): $MBPS MB/s"
rm -f "$WORK/big.out"

check "upload 32 MB (POST): the origin's SHA-256 matches" \
    test "$($G curl -sS --max-time 300 -H 'Expect:' --data-binary @"$WORK/up.bin" http://up.test/upload)" = "$UP_SHA"

seq 64 | xargs -P 64 -I{} $G curl -sS --max-time 300 -o "$WORK/par.{}" "http://par{}.test/mid" 2>"$WORK/par.err"
PAR_OK=0
for i in $(seq 64); do [ "$(sha_of "$WORK/par.$i" 2>/dev/null)" = "$MID_SHA" ] && PAR_OK=$((PAR_OK + 1)); done
check "64 parallel downloads of 8 MB: all 64 match ($PAR_OK)" test "$PAR_OK" = 64
rm -f "$WORK"/par.*

check "half-close: the guest's FIN goes through and the answer still comes back" \
    test "$($G python3 "$WORK/guest.py" half half.test 7001 "$WORK/half.bin")" = "$HALF_SHA"
check "a slow reader with a small buffer (the guest's window shuts): 8 MB match" \
    test "$($G python3 "$WORK/guest.py" slow slow.test /mid)" = "$MID_SHA"
check "a slow origin (the stack's window shuts): 32 MB upload matches" \
    test "$($G curl -sS --max-time 300 -H 'Expect:' --data-binary @"$WORK/up.bin" http://slowup.test/slowupload)" = "$UP_SHA"

check "a name the proxy refuses: connection refused, fast" refused_fast 3 refused.test
check "a literal private address (10.1.2.3): refused fast" refused_fast 3 10.1.2.3
check "a literal link-local address (169.254.169.254): refused fast" refused_fast 3 169.254.169.254
check "a fake-pool address nobody was given (198.19.200.200): refused fast" refused_fast 3 198.19.200.200
check "a literal public address goes to the proxy as an address" bash -c "$G curl -sS --max-time 20 http://93.184.216.34/ | grep -q 'hello from the origin' && grep -qx 'addr 93.184.216.34:80' '$WORK/socks.log'"
check "the refused addresses never reached the proxy" bash -c "! grep -qE '10\.1\.2\.3|169\.254|198\.19\.200' '$WORK/socks.log'"

UDP="$($G python3 "$WORK/guest.py" udp 93.184.216.34 4433)"
check "UDP to a public address: ICMP port unreachable ($UDP)" bash -c "echo '$UDP' | grep -q '^refused'"

echo "== load =="
seq 1000 | xargs -P 32 -I{} $G curl -sS --max-time 60 -o "$WORK/churn.{}" "http://churn{}.test/" 2>"$WORK/churn.err"
CHURN_OK=$(cat "$WORK"/churn.* 2>/dev/null | grep -c 'hello from the origin')
check "1000 short connections, 32 at a time: all answered ($CHURN_OK)" test "$CHURN_OK" = 1000
rm -f "$WORK"/churn.*

head -c $((4 * 1024 * 1024)) /dev/urandom >"$WORK/up4.bin"
UP4_SHA=$(sha_of "$WORK/up4.bin")
seq 64 | xargs -P 64 -I{} sh -c "$G curl -sS --max-time 300 -H 'Expect:' --data-binary @'$WORK/up4.bin' 'http://pup{}.test/upload' >'$WORK/pup.{}' 2>>'$WORK/pup.err'"
PUP_OK=$(cat "$WORK"/pup.[0-9]* 2>/dev/null | grep -c "^$UP4_SHA\$")
check "64 parallel uploads of 4 MB: all 64 match ($PUP_OK)" test "$PUP_OK" = 64
rm -f "$WORK"/pup.*

# Downloads and uploads at once, and transfers cut off by the guest in the middle of them.
(seq 8 | xargs -P 8 -I{} $G curl -sS --max-time 300 -o "$WORK/mix.{}" "http://mix{}.test/mid" 2>>"$WORK/mix.err") &
MIX_PID=$!
for i in $(seq 20); do $G curl -sS --max-time 0.05 -o /dev/null "http://cut$i.test/big" 2>/dev/null; done
MIXUP="$($G curl -sS --max-time 300 -H 'Expect:' --data-binary @"$WORK/up.bin" http://mixup.test/upload)"
wait $MIX_PID
MIX_OK=0
for i in $(seq 8); do [ "$(sha_of "$WORK/mix.$i" 2>/dev/null)" = "$MID_SHA" ] && MIX_OK=$((MIX_OK + 1)); done
check "8 downloads and a 32 MB upload at once, among 20 transfers the guest cut off: all match ($MIX_OK)" \
    bash -c "[ '$MIX_OK' = 8 ] && [ '$MIXUP' = '$UP_SHA' ]"
rm -f "$WORK"/mix.*

# A client that keeps its side open after the server closed: the stack waits without spinning.
$G python3 "$WORK/guest.py" stay stay.test 3 >"$WORK/stay.out" 2>&1 &
STAY_PID=$!
sleep 0.5
check "a connection the server closed and the guest keeps: the stack sleeps" quiet_for 2
wait $STAY_PID
check "…and the guest had its page" grep -qx "got the page" "$WORK/stay.out"
check "an idle stack uses no CPU" quiet_for 2

check "the stack is still running" kill -0 "$STACK_PID"
stop_stack
note "$COUNTERS"
check "the stack ended cleanly on SIGTERM" test "$STACK_STATUS" = 0
check "counters: at least the 64 MB + 64 × 8 MB + 8 MB went to the guest" test "$(counter bytesToGuest)" -ge $((64 * 1048576 + 65 * 8 * 1048576))
check "counters: at least 2 × 32 MB + 1 MB came from the guest" test "$(counter bytesFromGuest)" -ge $((65 * 1048576))
check "counters: failed connections counted (the refused name)" test "$(counter connectionsFailed)" -ge 1
check "counters: no connection left open" test "$(counter connectionsActive)" = 0
check "counters: the blocked name counted" test "$(counter dnsBlocked)" -ge 2
check "counters: the UDP datagram counted" test "$(counter datagramsDropped)" -ge 1
check "the log names no host and no address" bash -c "! grep '^LOG' '$WORK/stack.out' | grep -qE 'big\.test|small\.test|refused\.test|198\.1[89]\.|93\.184|127\.0\.0\.1'"

# ---------------------------------------------------------------------------------------------
echo "== a wire that loses 1 % of the frames each way =="
start_stack "socks5://127.0.0.1:$SOCKS_PORT" --loss-to-guest 0.01 --loss-from-guest 0.01
STARTED_AT=$(date +%s.%N)
$G curl -sS --max-time 300 -o "$WORK/mid.out" http://lossy.test/mid 2>"$WORK/curl.err"
check "download 8 MB over the lossy wire: SHA-256 matches" test "$(sha_of "$WORK/mid.out")" = "$MID_SHA"
check "upload 32 MB over the lossy wire: SHA-256 matches" \
    test "$($G curl -sS --max-time 300 -H 'Expect:' --data-binary @"$WORK/up.bin" http://lossyup.test/upload)" = "$UP_SHA"
note "both took $(python3 -c "import time; print('%.1f' % (time.time() - $STARTED_AT))") s"
stop_stack

# ---------------------------------------------------------------------------------------------
echo "== SOCKS5 proxy with a user name and password =="
start_stack "socks5://user:secret@127.0.0.1:$SOCKS_AUTH_PORT"
check "a page through a proxy that asks for a sign-in" bash -c "$G curl -sS --max-time 20 http://auth.test/ | grep -q 'hello from the origin' && grep -qx 'auth ok' '$WORK/socks-auth.log'"
stop_stack
check "the log does not hold the user name or the password" bash -c "! grep -qE 'secret|user:' '$WORK/stack.out'"
start_stack "socks5://user:wrong@127.0.0.1:$SOCKS_AUTH_PORT"
check "a wrong password: refused fast" refused_fast 3 auth.test
stop_stack

# ---------------------------------------------------------------------------------------------
echo "== HTTP CONNECT proxy (with a user name and password) =="
start_stack "http://user:secret@127.0.0.1:$HTTP_PORT"
SPEED=$($G curl -sS --max-time 300 -o "$WORK/big.out" -w '%{speed_download}' http://big.test/big 2>"$WORK/curl.err")
check "download 64 MB through HTTP CONNECT: SHA-256 matches" test "$(sha_of "$WORK/big.out")" = "$BIG_SHA"
echo "      throughput (64 MB download through the HTTP CONNECT double): $(python3 -c "print('%.1f' % (float('${SPEED:-0}') / 1e6))") MB/s"
rm -f "$WORK/big.out"
check "the proxy saw CONNECT with the name, a Host header and the sign-in" bash -c "grep -qx 'CONNECT big.test:80 host=big.test:80' '$WORK/http.log' && grep -qx 'auth ok' '$WORK/http.log'"
check "upload 32 MB through HTTP CONNECT: SHA-256 matches" \
    test "$($G curl -sS --max-time 300 -H 'Expect:' --data-binary @"$WORK/up.bin" http://up.test/upload)" = "$UP_SHA"
check "a name the proxy refuses (403): refused fast" refused_fast 3 refused.test
stop_stack

# ---------------------------------------------------------------------------------------------
echo "== no proxy: nothing connects =="
touch "$WORK/socks.log" "$WORK/socks-auth.log" "$WORK/http.log"
SOCKS_LINES=$(cat "$WORK/socks.log" "$WORK/socks-auth.log" "$WORK/http.log" | wc -l)
start_stack none
check "upstream none: a name is refused fast" refused_fast 3 big.test
check "upstream none: a literal public address is refused fast" refused_fast 3 93.184.216.34
check "upstream none: DNS still answers" bash -c "$G dig +short +time=2 +tries=1 A big.test @$GATEWAY | grep -qE '^198\.1[89]\.'"
check "upstream none: ping of the gateway still answers" $G ping -c 1 -W 2 "$GATEWAY"
stop_stack
check "upstream none: no proxy heard anything" test "$(cat "$WORK/socks.log" "$WORK/socks-auth.log" "$WORK/http.log" | wc -l)" = "$SOCKS_LINES"
check "upstream none: both connections counted as failed, none opened" bash -c "[ '$(counter connectionsFailed)' -ge 2 ] && [ '$(counter connectionsOpened)' = 0 ]"

if [ -s "$WORK/doubles.err" ]; then note "the doubles' errors:"; sed 's/^/      | /' "$WORK/doubles.err" | head -5; fi
echo
if [ "$FAILED" = 0 ]; then echo "vmnet interop: all checks passed (frames over a TAP device)"; else echo "vmnet interop: $FAILED check(s) FAILED"; fi
[ "$FAILED" = 0 ]
