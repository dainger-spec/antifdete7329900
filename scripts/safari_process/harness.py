#!/usr/bin/env python3
"""Measuring harness for the Safari-process experiments (docs/SAFARI_PROCESS.md).

Two local servers that any browser process can be pointed at, whatever launched it (`open`,
LaunchServices, a web app's Dock icon, another user's session). Nothing here drives the browser:
the pages report back by themselves, so no WebDriver session (and no `navigator.webdriver`) is
involved.

ReportServer (http://127.0.0.1:<port>)
    /run?inst=A&run=1&seed=1&peers=B,C&tls=<url>
        Reports what the browser already holds for this origin ("pre"), then (seed=1) writes
        instance A's markers: an HttpOnly cookie set by the response, a script cookie,
        localStorage and IndexedDB entries ("seeded"). It then waits until every peer has seeded,
        reads everything again ("final") and finally navigates to <url> (the TLS server).
        Every report carries the Cookie header the server received, so HttpOnly cookies count.
    /report (POST), /await?event=…, /events

TLSServer (https://<inst>.sp-tls.test:<port>, names mapped to 127.0.0.1 in /etc/hosts)
    Peeks at each connection's ClientHello before any TLS happens and records it (JA3, JA4,
    the full non-random structure). With a certificate the browser trusts it then completes the
    handshake and records the HTTP/2 preface (SETTINGS, WINDOW_UPDATE, PRIORITY, header order:
    the Akamai fingerprint) or the HTTP/1.1 header order. Without one, the ClientHello is still
    recorded: the browser sends it before it sees the certificate. The SNI names the instance.
"""
import hashlib
import json
import os
import socket
import ssl
import struct
import threading
import time
import urllib.parse
import http.server

# ---------------------------------------------------------------------------------------------
# ClientHello parsing, JA3 and JA4 (https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md)


def is_grease(value):
    return (value & 0x0F0F) == 0x0A0A and (value >> 8) == (value & 0xFF)


EXTENSION_NAMES = {
    0x0000: "server_name", 0x0005: "status_request", 0x000A: "supported_groups", 0x000B: "ec_point_formats",
    0x000D: "signature_algorithms", 0x0010: "alpn", 0x0012: "signed_certificate_timestamp", 0x0015: "padding",
    0x0017: "extended_master_secret", 0x001B: "compress_certificate", 0x001C: "record_size_limit",
    0x0022: "delegated_credentials", 0x0023: "session_ticket", 0x0029: "pre_shared_key", 0x002A: "early_data",
    0x002B: "supported_versions", 0x002D: "psk_key_exchange_modes", 0x0031: "post_handshake_auth",
    0x0032: "signature_algorithms_cert", 0x0033: "key_share", 0x0039: "quic_transport_parameters",
    0x4469: "application_settings_old", 0x44CD: "application_settings", 0xFE0D: "encrypted_client_hello",
    0xFF01: "renegotiation_info",
}


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, count):
        if self.pos + count > len(self.data):
            raise ValueError("truncated ClientHello")
        chunk = self.data[self.pos:self.pos + count]
        self.pos += count
        return chunk

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack(">H", self.take(2))[0]

    def u24(self):
        high, low = struct.unpack(">BH", self.take(3))
        return (high << 16) | low

    def vector(self, length_bytes):
        length = {1: self.u8, 2: self.u16, 3: self.u24}[length_bytes]()
        return Reader(self.take(length))

    def done(self):
        return self.pos >= len(self.data)

    def u16_list(self):
        values = []
        while not self.done():
            values.append(self.u16())
        return values


def handshake_bytes(records):
    """The ClientHello handshake message from raw TLS records, or None if more bytes are needed."""
    fragments, pos = b"", 0
    while pos + 5 <= len(records):
        content_type, _version, length = struct.unpack(">BHH", records[pos:pos + 5])
        if content_type != 0x16:
            raise ValueError(f"not a TLS handshake record (content type {content_type})")
        if pos + 5 + length > len(records):
            return None
        fragments += records[pos + 5:pos + 5 + length]
        pos += 5 + length
        if len(fragments) >= 4:
            needed = 4 + ((fragments[1] << 16) | (fragments[2] << 8) | fragments[3])
            if len(fragments) >= needed:
                return fragments[:needed]
    return None


def parse_client_hello(handshake):
    reader = Reader(handshake)
    if reader.u8() != 1:
        raise ValueError("not a ClientHello")
    body = reader.vector(3)
    hello = {"legacy_version": body.u16()}
    body.take(32)  # random
    hello["session_id_length"] = len(body.vector(1).data)
    hello["ciphers"] = body.vector(2).u16_list()
    hello["compression"] = list(body.vector(1).data)
    hello["extensions"] = []
    extensions = body.vector(2) if not body.done() else Reader(b"")
    while not extensions.done():
        ext_type = extensions.u16()
        data = extensions.vector(2)
        hello["extensions"].append((ext_type, data.data))
    return hello


def describe(hello):
    """Everything in a ClientHello that is not random per connection, GREASE marked as such."""
    out = {
        "legacy_version": hello["legacy_version"],
        "session_id_length": hello["session_id_length"],
        "ciphers": ["GREASE" if is_grease(c) else f"{c:04x}" for c in hello["ciphers"]],
        "extensions": [],
    }
    for ext_type, data in hello["extensions"]:
        name = "GREASE" if is_grease(ext_type) else EXTENSION_NAMES.get(ext_type, f"{ext_type:04x}")
        out["extensions"].append(name)
        reader = Reader(data)
        try:
            if ext_type == 0x0000 and data:
                names = reader.vector(2)
                names.u8()
                out["sni"] = names.vector(2).data.decode("ascii", "replace")
            elif ext_type == 0x000A:
                out["supported_groups"] = ["GREASE" if is_grease(g) else f"{g:04x}" for g in reader.vector(2).u16_list()]
            elif ext_type == 0x000B:
                out["ec_point_formats"] = list(reader.vector(1).data)
            elif ext_type == 0x000D:
                out["signature_algorithms"] = [f"{a:04x}" for a in reader.vector(2).u16_list()]
            elif ext_type == 0x0010:
                protocols, names = [], reader.vector(2)
                while not names.done():
                    protocols.append(names.vector(1).data.decode("ascii", "replace"))
                out["alpn"] = protocols
            elif ext_type == 0x002B:
                out["supported_versions"] = ["GREASE" if is_grease(v) else f"{v:04x}" for v in reader.vector(1).u16_list()]
            elif ext_type == 0x0033:
                shares, entries = [], reader.vector(2)
                while not entries.done():
                    group = entries.u16()
                    key = entries.vector(2).data
                    shares.append(("GREASE" if is_grease(group) else f"{group:04x}") + f"/{len(key)}")
                out["key_share"] = shares
            elif ext_type == 0x002D:
                out["psk_key_exchange_modes"] = list(reader.vector(1).data)
            elif ext_type == 0x001B:
                out["compress_certificate"] = [f"{a:04x}" for a in reader.vector(1).u16_list()]
            elif ext_type == 0x0005:
                out["status_request"] = data.hex()
            elif ext_type == 0xFF01:
                out["renegotiation_info"] = data.hex()
            elif ext_type == 0x0015:
                out["padding_length"] = len(data)
        except ValueError:
            out.setdefault("malformed", []).append(name)
    return out


def ja3(hello):
    ext_types = [t for t, _ in hello["extensions"] if not is_grease(t)]
    groups, formats = [], []
    for ext_type, data in hello["extensions"]:
        if ext_type == 0x000A:
            groups = [g for g in Reader(data).vector(2).u16_list() if not is_grease(g)]
        elif ext_type == 0x000B:
            formats = list(Reader(data).vector(1).data)
    text = ",".join([
        str(hello["legacy_version"]),
        "-".join(str(c) for c in hello["ciphers"] if not is_grease(c)),
        "-".join(str(t) for t in ext_types),
        "-".join(str(g) for g in groups),
        "-".join(str(f) for f in formats),
    ])
    return text, hashlib.md5(text.encode()).hexdigest()


TLS_VERSIONS = {0x0304: "13", 0x0303: "12", 0x0302: "11", 0x0301: "10", 0x0300: "s3", 0x0002: "s2"}


def _alpn_chars(first):
    if not first:
        return "00"
    def alnum(byte):
        return 0x30 <= byte <= 0x39 or 0x41 <= byte <= 0x5A or 0x61 <= byte <= 0x7A
    if alnum(first[0]) and alnum(first[-1]):
        return chr(first[0]) + chr(first[-1])
    hexed = first.hex()
    return hexed[0] + hexed[-1]


def ja4_parts(ciphers, extensions, sni, versions, legacy_version, alpn_first, sig_algs, quic=False):
    """JA4 from already-extracted fields (lists of ints; GREASE still included)."""
    ciphers = [c for c in ciphers if not is_grease(c)]
    extensions = [e for e in extensions if not is_grease(e)]
    versions = [v for v in versions if not is_grease(v)]
    version = TLS_VERSIONS.get(max(versions) if versions else legacy_version, "00")
    part_a = ("q" if quic else "t") + version + ("d" if sni else "i") + f"{min(len(ciphers), 99):02d}" \
        + f"{min(len(extensions), 99):02d}" + _alpn_chars(alpn_first)
    cipher_list = ",".join(sorted(f"{c:04x}" for c in ciphers))
    part_b = hashlib.sha256(cipher_list.encode()).hexdigest()[:12] if ciphers else "000000000000"
    ext_list = ",".join(sorted(f"{e:04x}" for e in extensions if e not in (0x0000, 0x0010)))
    sig_list = ",".join(f"{s:04x}" for s in sig_algs if not is_grease(s))
    c_input = ext_list + ("_" + sig_list if sig_list else "")
    part_c = hashlib.sha256(c_input.encode()).hexdigest()[:12] if ext_list else "000000000000"
    raw = f"{part_a}_{cipher_list}_{c_input}"
    return f"{part_a}_{part_b}_{part_c}", raw


def ja4(hello):
    ext_types = [t for t, _ in hello["extensions"]]
    versions, alpn_first, sig_algs, sni = [], b"", [], False
    for ext_type, data in hello["extensions"]:
        reader = Reader(data)
        if ext_type == 0x0000:
            sni = True
        elif ext_type == 0x002B:
            versions = reader.vector(1).u16_list()
        elif ext_type == 0x0010:
            names = reader.vector(2)
            alpn_first = names.vector(1).data if not names.done() else b""
        elif ext_type == 0x000D:
            sig_algs = reader.vector(2).u16_list()
    return ja4_parts(hello["ciphers"], ext_types, sni, versions, hello["legacy_version"], alpn_first, sig_algs)


def fingerprint(handshake):
    hello = parse_client_hello(handshake)
    ja3_text, ja3_hash = ja3(hello)
    ja4_hash, ja4_raw = ja4(hello)
    shape = describe(hello)
    # What must be identical between two instances of one browser: GREASE positions are random
    # per connection in BoringSSL, so they are dropped; the padding length follows the SNI length.
    stable = {k: [x for x in v if not str(x).startswith("GREASE")] if isinstance(v, list) else v
              for k, v in shape.items() if k not in ("sni", "padding_length")}
    return {"ja3": ja3_text, "ja3_hash": ja3_hash, "ja4": ja4_hash, "ja4_r": ja4_raw, "shape": shape,
            "stable": stable, "stable_hash": hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest()[:16]}


# ---------------------------------------------------------------------------------------------
# HTTP/2 preface (Akamai fingerprint: SETTINGS|WINDOW_UPDATE|PRIORITY|pseudo-header order)

H2_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
STATIC_NAMES = [None, ":authority", ":method", ":method", ":path", ":path", ":scheme", ":scheme", ":status",
                ":status", ":status", ":status", ":status", ":status", ":status", "accept-charset", "accept-encoding",
                "accept-language", "accept-ranges", "accept", "access-control-allow-origin", "age", "allow",
                "authorization", "cache-control", "content-disposition", "content-encoding", "content-language",
                "content-length", "content-location", "content-range", "content-type", "cookie", "date", "etag",
                "expect", "expires", "from", "host", "if-match", "if-modified-since", "if-none-match", "if-range",
                "if-unmodified-since", "last-modified", "link", "location", "max-forwards", "proxy-authenticate",
                "proxy-authorization", "range", "referer", "refresh", "retry-after", "server", "set-cookie",
                "strict-transport-security", "transfer-encoding", "user-agent", "vary", "via", "www-authenticate"]


def header_names(block):
    """Header names of a request's first HPACK block, in order. Uses the hpack package when it is
    installed (Huffman-coded literal names); otherwise names that are Huffman-coded show as '?'."""
    try:
        import hpack  # type: ignore
        return [name.decode() if isinstance(name, bytes) else name for name, _ in hpack.Decoder().decode(block, raw=True)]
    except ImportError:
        pass
    names, dynamic, pos = [], [], 0

    def integer(prefix_bits):
        nonlocal pos
        mask = (1 << prefix_bits) - 1
        value = block[pos] & mask
        pos += 1
        if value < mask:
            return value
        shift = 0
        while True:
            byte = block[pos]
            pos += 1
            value += (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80:
                return value

    def string():
        nonlocal pos
        huffman = block[pos] & 0x80
        length = integer(7)
        raw = block[pos:pos + length]
        pos += length
        return "?" if huffman else raw.decode("latin-1")

    def name_at(index):
        if index < len(STATIC_NAMES):
            return STATIC_NAMES[index]
        offset = index - len(STATIC_NAMES)
        return dynamic[offset] if offset < len(dynamic) else "?"

    while pos < len(block):
        byte = block[pos]
        if byte & 0x80:  # indexed field
            names.append(name_at(integer(7)))
        elif byte & 0x40:  # literal with incremental indexing
            index = integer(6)
            name = name_at(index) if index else string()
            string()
            names.append(name)
            dynamic.insert(0, name)
        elif byte & 0x20:  # dynamic table size update
            integer(5)
        else:  # literal without indexing / never indexed
            index = integer(4)
            name = name_at(index) if index else string()
            string()
            names.append(name)
    return names


SETTING_IDS = {1: "HEADER_TABLE_SIZE", 2: "ENABLE_PUSH", 3: "MAX_CONCURRENT_STREAMS", 4: "INITIAL_WINDOW_SIZE",
               5: "MAX_FRAME_SIZE", 6: "MAX_HEADER_LIST_SIZE", 8: "ENABLE_CONNECT_PROTOCOL", 9: "NO_RFC7540_PRIORITIES"}


def read_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def capture_h2(conn):
    """Reads the client's preface frames up to its first complete HEADERS, answers 200 to it."""
    if read_exact(conn, len(H2_PREFACE)) != H2_PREFACE:
        raise ValueError("no HTTP/2 preface")
    settings, window, priorities, frames, block, stream = [], None, [], [], b"", None
    while True:
        length_high, length_low, frame_type, flags, stream_id = struct.unpack(">BHBBI", read_exact(conn, 9))
        payload = read_exact(conn, (length_high << 16) | length_low)
        stream_id &= 0x7FFFFFFF
        if frame_type == 0x4 and not flags & 0x1:
            pairs = [struct.unpack(">HI", payload[i:i + 6]) for i in range(0, len(payload), 6)]
            settings = [f"{k}:{v}" for k, v in pairs]
            frames.append("SETTINGS[" + ";".join(f"{SETTING_IDS.get(k, k)}={v}" for k, v in pairs) + "]")
        elif frame_type == 0x8:
            increment = struct.unpack(">I", payload[:4])[0] & 0x7FFFFFFF
            if stream_id == 0 and window is None:
                window = increment
            frames.append(f"WINDOW_UPDATE[{stream_id}]+{increment}")
        elif frame_type == 0x2:
            dep, weight = struct.unpack(">IB", payload[:5])
            priorities.append(f"{stream_id}:{(dep >> 31) & 1}:{dep & 0x7FFFFFFF}:{weight + 1}")
            frames.append(f"PRIORITY[{stream_id}]")
        elif frame_type == 0x1:
            body = payload
            if flags & 0x8:  # PADDED
                body = body[1:len(body) - body[0]]
            headers_priority = ""
            if flags & 0x20:  # PRIORITY: listed with the frame, not in the Akamai PRIORITY field
                dep, weight = struct.unpack(">IB", body[:5])
                headers_priority = f" priority={(dep >> 31) & 1}:{dep & 0x7FFFFFFF}:{weight + 1}"
                body = body[5:]
            block, stream = body, stream_id
            frames.append(f"HEADERS[{stream_id}]{headers_priority}")
            if flags & 0x4:
                break
        elif frame_type == 0x9:
            block += payload
            if flags & 0x4:
                break
        else:
            frames.append(f"type{frame_type}")
    names = header_names(block)
    pseudo = "".join(n[1] for n in names if n.startswith(":"))
    akamai = "|".join([";".join(settings), str(window or 0), ",".join(priorities) or "0",
                       ",".join(pseudo)])
    # Answer: our SETTINGS, ACK theirs, then ":status 200" (static index 8) and a tiny body.
    conn.sendall(struct.pack(">BHBBI", 0, 0, 0x4, 0, 0) + struct.pack(">BHBBI", 0, 0, 0x4, 0x1, 0))
    conn.sendall(struct.pack(">BHBBI", 0, 1, 0x1, 0x4, stream) + b"\x88")
    conn.sendall(struct.pack(">BHBBI", 0, 2, 0x0, 0x1, stream) + b"ok")
    return {"akamai": akamai, "frames": " ".join(frames), "header_order": names}


def capture_h1(conn):
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 65536:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    lines = data.split(b"\r\n\r\n")[0].decode("latin-1").split("\r\n")
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    return {"request_line": lines[0] if lines else "", "header_order": [l.split(":", 1)[0] for l in lines[1:]]}


class TLSServer:
    """Records each connection's ClientHello (and, with a trusted certificate, HTTP/2 or HTTP/1.1)."""

    def __init__(self, port=0, cert=None, key=None):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(64)
        self.port = self.sock.getsockname()[1]
        self.records, self.lock = [], threading.Lock()
        self.context = None
        if cert and key:
            self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            self.context.load_cert_chain(cert, key)
            self.context.set_alpn_protocols(["h2", "http/1.1"])
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        record = {"time": time.time()}
        try:
            conn.settimeout(8)
            data, handshake = b"", None
            deadline = time.time() + 8
            while handshake is None and time.time() < deadline:
                data = conn.recv(65536, socket.MSG_PEEK)
                if not data:
                    raise ConnectionError("closed before a ClientHello")
                handshake = handshake_bytes(data)
                if handshake is None:
                    time.sleep(0.02)
            if handshake is None:
                raise ValueError("incomplete ClientHello")
            record.update(fingerprint(handshake))
            record["sni"] = record["shape"].get("sni")
            if self.context:
                try:
                    tls = self.context.wrap_socket(conn, server_side=True)
                    record["negotiated"] = {"version": tls.version(), "cipher": tls.cipher()[0],
                                            "alpn": tls.selected_alpn_protocol()}
                    if tls.selected_alpn_protocol() == "h2":
                        record["http2"] = capture_h2(tls)
                    else:
                        record["http1"] = capture_h1(tls)
                    conn = tls
                    time.sleep(0.3)
                except (ssl.SSLError, OSError, ValueError, ConnectionError) as exc:
                    record["handshake_error"] = str(exc)
        except Exception as exc:  # noqa: BLE001 - a broken connection is a record too
            record["error"] = str(exc)
        finally:
            with self.lock:
                self.records.append(record)
            try:
                conn.close()
            except OSError:
                pass

    def for_host(self, host):
        with self.lock:
            return [r for r in self.records if r.get("sni") == host]

    def close(self):
        self.sock.close()


# ---------------------------------------------------------------------------------------------
# Report server: storage markers written and read by the page itself

RUN_PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>sp-run</title></head>
<body><pre id="log">running…</pre><script>
(async () => {
  const P = new URLSearchParams(location.search);
  const inst = P.get('inst'), run = P.get('run') || '1', seed = P.get('seed') === '1';
  const peers = (P.get('peers') || '').split(',').filter(Boolean);
  const log = (t) => { document.getElementById('log').textContent += '\n' + t; };
  const idb = () => new Promise((resolve, reject) => {
    const open = indexedDB.open('sp', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('kv');
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
  async function idbKeys() {
    try {
      const db = await idb();
      return await new Promise((resolve, reject) => {
        const request = db.transaction('kv').objectStore('kv').getAllKeys();
        request.onsuccess = () => resolve(request.result.map(String).sort());
        request.onerror = () => reject(request.error);
      });
    } catch (e) { return ['error:' + e]; }
  }
  async function idbPut(key, value) {
    const db = await idb();
    await new Promise((resolve, reject) => {
      const tx = db.transaction('kv', 'readwrite');
      tx.objectStore('kv').put(value, key);
      tx.oncomplete = resolve; tx.onerror = () => reject(tx.error);
    });
  }
  const read = async () => ({
    documentCookie: document.cookie,
    localStorage: Object.keys(localStorage).filter((k) => k.startsWith('sp_')).sort(),
    indexedDB: await idbKeys(),
  });
  const env = () => ({
    userAgent: navigator.userAgent,
    webdriver: navigator.webdriver,
    standalone: navigator.standalone,
    displayModeStandalone: matchMedia('(display-mode: standalone)').matches,
    applePaySession: typeof window.ApplePaySession,
    pushManager: typeof window.PushManager,
    notification: typeof window.Notification === 'function' ? Notification.permission : 'absent',
    windowSafari: typeof window.safari,
    ownWindowProps: Object.getOwnPropertyNames(window).length,
    windowProps: Object.getOwnPropertyNames(window).sort(),
    referrer: document.referrer,
    historyLength: history.length,
  });
  const page = Math.random().toString(36).slice(2, 10);
  const report = (phase, data) => fetch('/report', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, cache: 'no-store',
    body: JSON.stringify({ inst, run, phase, page, ...data }),
  });
  try {
    // A web app may reopen the page it showed last instead of its start page: go where this
    // instance's current launch is planned to go.
    const planned = await fetch(`/current?inst=${encodeURIComponent(inst)}`, { cache: 'no-store' }).then((r) => r.text());
    const plannedParams = planned ? new URL(planned).searchParams : null;
    if (plannedParams && (plannedParams.get('inst') !== inst || plannedParams.get('run') !== run)) {
      location.replace(planned);
      return;
    }
    await report('pre', { ...(await read()), env: env() });
    log('pre reported');
    if (seed) {
      document.cookie = `sp_js_${inst}=${inst}; path=/; max-age=86400; SameSite=Lax`;
      localStorage.setItem(`sp_${inst}`, inst);
      await idbPut(`sp_${inst}`, inst);
      await report('seeded', await read());
      log('seeded');
      for (const peer of peers) {
        log('waiting for ' + peer);
        await fetch(`/await?event=${encodeURIComponent(peer + ':seeded')}&timeout=240`, { cache: 'no-store' });
      }
      await report('final', await read());
      log('final reported');
    }
  } catch (e) {
    await report('error', { error: String(e) });
  }
  // The TLS host is measured with a fetch from this page, so a web app (whose top-level
  // navigations outside its scope open in the default browser) is measured by its own process.
  const tls = P.get('tls');
  if (tls) {
    let outcome = 'ok';
    try { await fetch(tls + '?via=fetch', { mode: 'no-cors', cache: 'no-store' }); } catch (e) { outcome = String(e); }
    await report('tls', { outcome });
    if (P.get('navtls') === '1') setTimeout(() => { location.href = tls + '?via=navigation'; }, 300);
  }
})();
</script></body></html>"""


def marker_tags(cookie_header, document_cookie, local_storage, indexed_db):
    """Which instances' markers a report shows, per storage kind."""
    def from_cookies(text, prefix):
        tags = set()
        for part in (text or "").split(";"):
            name = part.strip().split("=", 1)[0]
            if name.startswith(prefix):
                tags.add(name[len(prefix):])
        return sorted(tags)
    return {
        "httpOnlyCookie": from_cookies(cookie_header, "sp_http_"),
        "scriptCookie": from_cookies(cookie_header, "sp_js_"),
        "documentCookie": from_cookies(document_cookie, "sp_js_"),
        "localStorage": sorted(k[3:] for k in local_storage or [] if k.startswith("sp_")),
        "indexedDB": sorted(k[3:] for k in indexed_db or [] if k.startswith("sp_")),
    }


class ReportServer:
    def __init__(self, port=0):
        self.events, self.reports, self.window_props = set(), [], {}
        # What each launch is planned to run: per web app name (its start page redirects there), per
        # instance, and which web app an instance ran in. A page that is not the current plan of its
        # instance or app (a tab restored from an earlier run) is sent to the current one, unseeded.
        self.plan, self.plan_by_inst, self.app_of_inst = {}, {}, {}
        self.condition = threading.Condition()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, content_type, body, extra=()):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                for name, value in extra:
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                url = urllib.parse.urlsplit(self.path)
                query = dict(urllib.parse.parse_qsl(url.query))
                if url.path == "/run":
                    inst = query.get("inst", "x")
                    current = owner.current(inst)
                    if current and not owner.is_current(current, inst, query.get("run", "1")):
                        owner._record({"inst": inst, "run": query.get("run", "1"), "phase": "stale-navigation",
                                       "redirect": current})
                        self._send(302, "text/plain", b"", [("Location", current)])
                        return
                    extra = []
                    if query.get("seed") == "1":
                        extra.append(("Set-Cookie", f"sp_http_{inst}={inst}; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax"))
                    owner._record({"inst": inst, "run": query.get("run", "1"), "phase": "navigation",
                                   "cookieHeader": self.headers.get("Cookie", ""),
                                   "headerOrder": [k for k, _ in self.headers.items()]})
                    self._send(200, "text/html; charset=utf-8", RUN_PAGE.encode(), extra)
                elif url.path == "/app":
                    # A web app's start URL is fixed when it is created; the experiment decides
                    # what each launch runs by planning a redirect for that app's name.
                    name = query.get("name", "x")
                    with owner.condition:
                        target = owner.plan.get(name)
                    owner._record({"inst": name, "phase": "app-start", "planned": target,
                                   "cookieHeader": self.headers.get("Cookie", "")})
                    if target:
                        self._send(302, "text/plain", b"", [("Location", target)])
                    else:
                        page = (f"<!doctype html><html><head><meta charset='utf-8'><title>SPWA-{name}</title>"
                                f"</head><body><h1>SPWA-{name}</h1></body></html>").encode()
                        self._send(200, "text/html; charset=utf-8", page)
                elif url.path == "/current":
                    self._send(200, "text/plain", owner.current(query.get("inst", "")).encode())
                elif url.path == "/await":
                    event, timeout = query.get("event", ""), float(query.get("timeout", "60"))
                    with owner.condition:
                        owner.condition.wait_for(lambda: event in owner.events, timeout=timeout)
                        ok = event in owner.events
                    self._send(200 if ok else 408, "text/plain", b"ok" if ok else b"timeout")
                elif url.path == "/events":
                    with owner.condition:
                        body = json.dumps({"events": sorted(owner.events), "reports": owner.reports}).encode()
                    self._send(200, "application/json", body)
                else:
                    self._send(404, "text/plain", b"not found")

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                try:
                    data = json.loads(self.rfile.read(length) or b"{}")
                except ValueError:
                    data = {"error": "bad json"}
                data["cookieHeader"] = self.headers.get("Cookie", "")
                owner._record(data)
                self._send(200, "text/plain", b"ok")

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def _record(self, data):
        data["time"] = time.time()
        if data.get("phase") in ("pre", "seeded", "final", "navigation"):
            data["tags"] = marker_tags(data.get("cookieHeader"), data.get("documentCookie"),
                                       data.get("localStorage"), data.get("indexedDB"))
        with self.condition:
            self.reports.append(data)
            if data.get("phase") == "seeded":
                self.events.add(f"{data.get('inst')}:seeded")
            self.condition.notify_all()

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def set_plan(self, name, target):
        """The next launch of web app `name` runs `target`."""
        with self.condition:
            if not target:
                self.plan.pop(name, None)
                return
            self.plan[name] = target
            inst = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(target).query)).get("inst")
            if inst:
                self.app_of_inst[inst] = name
                self.plan_by_inst[inst] = target

    def set_current(self, inst, target):
        """Instance `inst`'s current launch runs `target` (set before every launch)."""
        with self.condition:
            self.plan_by_inst[inst] = target

    def current(self, inst):
        with self.condition:
            app = self.app_of_inst.get(inst)
            return (self.plan.get(app) if app else None) or self.plan_by_inst.get(inst, "")

    @staticmethod
    def is_current(target, inst, run):
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(target).query))
        return query.get("inst") == inst and query.get("run", "1") == str(run)

    def release(self, event):
        """Marks an event as happened, e.g. a peer that never started, so pages stop waiting for it."""
        with self.condition:
            self.events.add(event)
            self.condition.notify_all()

    def wait(self, inst, phase, run="1", timeout=60):
        deadline = time.time() + timeout
        with self.condition:
            while True:
                found = [r for r in self.reports if r.get("inst") == inst and r.get("phase") == phase
                         and str(r.get("run")) == str(run)]
                if found:
                    return found[-1]
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self.condition.wait(remaining)

    def close(self):
        self.server.shutdown()


# ---------------------------------------------------------------------------------------------
# A forwarding HTTP CONNECT proxy that remembers which hosts went through it


class ConnectProxy:
    def __init__(self, port=0):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(64)
        self.port = self.sock.getsockname()[1]
        self.log, self.lock = [], threading.Lock()
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        try:
            conn.settimeout(15)
            data = b""
            while b"\r\n\r\n" not in data and len(data) < 65536:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk
            head, rest = data.split(b"\r\n\r\n", 1)
            request_line = head.split(b"\r\n")[0].decode("latin-1")
            method, target = (request_line.split(" ") + ["", ""])[:2]
            with self.lock:
                self.log.append({"time": time.time(), "request": request_line})
            if method != "CONNECT":
                conn.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
                return
            host, _, port = target.rpartition(":")
            upstream = socket.create_connection((host, int(port)), timeout=15)
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            if rest:
                upstream.sendall(rest)
            conn.settimeout(None)
            upstream.settimeout(None)

            def pipe(source, sink):
                try:
                    while True:
                        chunk = source.recv(65536)
                        if not chunk:
                            break
                        sink.sendall(chunk)
                except OSError:
                    pass
                finally:
                    for s_ in (source, sink):
                        try:
                            s_.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
            threading.Thread(target=pipe, args=(upstream, conn), daemon=True).start()
            pipe(conn, upstream)
        except Exception:  # noqa: BLE001 - a failed tunnel is only a missing log line
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def hosts(self):
        with self.lock:
            return [entry["request"] for entry in self.log]

    def close(self):
        self.sock.close()
