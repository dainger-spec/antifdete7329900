#!/usr/bin/env python3
"""Measures Safari on a real iPhone or iPad (or on a Mac), for the iPhone and iPad generations to be
checked against the device.

    python3 scripts/device_reference.py --name iphone-ios26
    # On the device (same network): open the printed https://<this Mac>.local:<port>/ in Safari,
    # accept the certificate warning, follow the link the page shows (accept the warning again if
    # Safari asks), and keep the second page in view until it reads "sent".
    python3 scripts/device_reference.py --compare scripts/reference/iphone-ios26.json surface-iphone.json

Two pages on two ports, with one certificate made for this run (openssl):
1. `--port`: the device's TLS and HTTP/2, as a server sees them. This listener speaks just enough
   HTTP/2 to answer one navigation. It keeps the ClientHello (JA4) and the client's first frames:
   SETTINGS, WINDOW_UPDATE, PRIORITY and the order of the request's pseudo-headers, which make the
   "Akamai" fingerprint. It answers with a link to the second page. Opened by this Mac's Bonjour
   name (Name.local), Safari sends a server name as it does to a real site; over an IP address it
   sends none, and JA4 then reads "i" and counts one extension less (its hashes compare as they are).
   A resumed TLS session adds the pre-shared-key extension: such a handshake is marked, not compared.
2. `--port` + 1: what a page measures. It runs Resources/fingerprint_probe.js, as
   safari_reference.py does in the Mac's Safari (navigator, screen, WebGL, fonts, codecs, the touch
   interfaces' shape, every global's name), and adds what only the device can tell:
   - the viewport Safari leaves a page: inner sizes at load, and again after scrolling, once
     Safari's bars have settled; the outer sizes and screen position;
   - the pixel ratio and the media queries that follow it; orientation, pointer and hover,
     device-width;
   - the navigator a worker sees;
   - what MediaCapabilities and WebCodecs answer for common codecs (asynchronous, so not in the
     probe).

The script writes scripts/reference/<name>.json. It prints the values a mobile generation declares
(PrivacyScripts: the screen, the pixel ratio, deviceViewportSize) next to the device's, and the TLS
and HTTP/2 values next to this Mac's WebKit's (CI). `--compare` prints every key where two files
differ — a device reference, or a bare probe result: the self-test's surface-<name>.json (CI
artifact "fingerprint-surfaces") or safari_reference.py --out. A device against an iPhone profile's
surface shows what the profile still has of the Mac; for lists (globals, WebGL extensions, codecs)
it prints the items only one side has.

HTTPS: APIs Safari exposes only in a secure context then read as they do on a real site.
"""
import argparse
import hashlib
import http.server
import json
import os
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PROBE = os.path.join(ROOT, "Resources", "fingerprint_probe.js")
REFERENCE_DIR = os.path.join(ROOT, "scripts", "reference")

# What PrivacyScripts declares for each mobile generation (keep in step with shimConfiguration and
# deviceViewportSize; the self-test checks the profile against these).
DECLARED = {
    "iphone": {"screen": "390x844", "pixelRatio": 3, "viewport": "390x739"},
    "ipad": {"screen": "820x1180", "pixelRatio": 2, "viewport": "820x1106"},
}

# This Mac's WebKit (macOS 26.6.2, Safari 26.6.2): a profile and Safari agree (live_compare.py, CI).
MAC_WEBKIT = {
    "ja4": "t13d2013h2_a09f3c656075_7f0f34a4126d",
    "akamai": "2:0;3:100;4:2097152;9:1|10420225|0|m,s,a,p",
}

GREASE = {0x0A0A + 0x1010 * i for i in range(16)}


def lan_address():
    """This Mac's address on the network the device reaches it over (no packet is sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.connect(("192.0.2.1", 9))
            return sock.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def bonjour_name():
    """This Mac's Bonjour name (Name.local), which a device on the same network resolves; None
    elsewhere."""
    try:
        name = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return f"{name}.local" if name else None


def certificate(directory, address, name):
    """A certificate for this run, as iOS accepts a server's (SAN, serverAuth, SHA-256, RSA 2048, short
    validity). A config file rather than -addext, which macOS's LibreSSL may lack."""
    key, cert, config = (os.path.join(directory, file) for file in ("key.pem", "cert.pem", "openssl.cnf"))
    names = [f"IP:{address}", "DNS:localhost"] + ([f"DNS:{name}"] if name else [])
    with open(config, "w", encoding="utf-8") as handle:
        handle.write("[req]\ndistinguished_name = dn\nx509_extensions = ext\nprompt = no\n"
                     "[dn]\nCN = pb-device-reference\n"
                     f"[ext]\nsubjectAltName = {','.join(names)}\nbasicConstraints = CA:FALSE\n"
                     "keyUsage = digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth\n")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1",
                    "-config", config, "-keyout", key, "-out", cert], check=True, capture_output=True)
    return cert, key


# ---- TLS: the ClientHello, read before the handshake --------------------------------------------

def peek_client_hello(sock, timeout=5.0):
    """The bytes of the first TLS handshake record, left in the socket for the handshake."""
    sock.settimeout(timeout)
    data = b""
    try:
        while True:
            data = sock.recv(65536, socket.MSG_PEEK)
            if len(data) >= 5 and data[0] == 0x16:
                length = struct.unpack(">H", data[3:5])[0]
                if len(data) >= 5 + length:
                    break
            elif len(data) >= 5 or not data:
                break
    except (socket.timeout, OSError):
        pass
    finally:
        sock.settimeout(None)
    return data


def parse_client_hello(record):
    """The ClientHello's fields JA4 is made of; None if this is not one."""
    if len(record) < 9 or record[0] != 0x16 or record[5] != 0x01:
        return None
    body = record[9:9 + int.from_bytes(record[6:9], "big")]
    pos = 2 + 32  # legacy_version, random
    pos += 1 + body[pos]  # session id
    count = struct.unpack(">H", body[pos:pos + 2])[0]
    ciphers = [struct.unpack(">H", body[pos + 2 + i:pos + 4 + i])[0] for i in range(0, count, 2)]
    pos += 2 + count
    pos += 1 + body[pos]  # compression methods
    extensions, sni, alpn, versions, signatures = [], False, [], [], []
    if pos + 2 <= len(body):
        end = pos + 2 + struct.unpack(">H", body[pos:pos + 2])[0]
        pos += 2
        while pos + 4 <= end:
            kind, length = struct.unpack(">HH", body[pos:pos + 4])
            data = body[pos + 4:pos + 4 + length]
            pos += 4 + length
            extensions.append(kind)
            if kind == 0x0000:
                sni = True
            elif kind == 0x0010 and len(data) >= 2:
                cursor = 2
                while cursor < len(data):
                    size = data[cursor]
                    alpn.append(data[cursor + 1:cursor + 1 + size].decode("ascii", "replace"))
                    cursor += 1 + size
            elif kind == 0x002B and data:
                versions = [struct.unpack(">H", data[1 + i:3 + i])[0] for i in range(0, data[0], 2)]
            elif kind == 0x000D and len(data) >= 2:
                signatures = [struct.unpack(">H", data[2 + i:4 + i])[0] for i in range(0, struct.unpack(">H", data[:2])[0], 2)]
    return {"legacyVersion": struct.unpack(">H", body[:2])[0], "ciphers": ciphers, "extensions": extensions,
            "sni": sni, "alpn": alpn, "versions": versions, "signatures": signatures}


def ja4(hello):
    """JA4 (FoxIO) of a ClientHello over TCP, and its raw form."""
    ciphers = [c for c in hello["ciphers"] if c not in GREASE]
    extensions = [e for e in hello["extensions"] if e not in GREASE]
    versions = [v for v in hello["versions"] if v not in GREASE] or [hello["legacyVersion"]]
    version = {0x0304: "13", 0x0303: "12", 0x0302: "11", 0x0301: "10", 0x0300: "s3"}.get(max(versions), "00")
    first = hello["alpn"][0] if hello["alpn"] else ""
    alpn = (first[0] + first[-1]) if first else "00"
    head = f"t{version}{'d' if hello['sni'] else 'i'}{min(len(ciphers), 99):02d}{min(len(extensions), 99):02d}{alpn}"
    cipher_text = ",".join(f"{c:04x}" for c in sorted(ciphers))
    extension_text = ",".join(f"{e:04x}" for e in sorted(e for e in extensions if e not in (0x0000, 0x0010)))
    signature_text = ",".join(f"{s:04x}" for s in hello["signatures"] if s not in GREASE)
    hashed = extension_text + ("_" + signature_text if signature_text else "")
    sha = lambda text: hashlib.sha256(text.encode()).hexdigest()[:12] if text else "000000000000"
    return {"ja4": f"{head}_{sha(cipher_text)}_{sha(hashed)}",
            "ja4_r": f"{head}_{cipher_text}_{hashed}", "alpn": hello["alpn"],
            # pre_shared_key: a resumed session, whose ClientHello is not the one a site first sees.
            "resumed": 0x0029 in extensions}


# ---- HTTP/2: the client's first frames ----------------------------------------------------------

SETTING_IDS = (1, 2, 3, 4, 5, 6, 8, 9)
# HPACK's static table: the pseudo-headers, as indexed names (RFC 7541, appendix A).
PSEUDO = {1: "a", 2: "m", 3: "m", 4: "p", 5: "p", 6: "s", 7: "s"}


def hpack_integer(block, pos, prefix):
    value = block[pos] & ((1 << prefix) - 1)
    pos += 1
    if value < (1 << prefix) - 1:
        return value, pos
    shift = 0
    while True:
        byte = block[pos]
        pos += 1
        value += (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, pos


def pseudo_header_order(block):
    """The request's pseudo-headers in order ("m,s,a,p"), from their HPACK static-table names."""
    order, pos = [], 0
    while pos < len(block):
        byte = block[pos]
        if byte & 0x80:  # indexed field
            index, pos = hpack_integer(block, pos, 7)
        elif byte & 0x40:  # literal, incremental indexing
            index, pos = hpack_integer(block, pos, 6)
        elif byte & 0x20:  # dynamic table size update
            _, pos = hpack_integer(block, pos, 5)
            continue
        else:  # literal without indexing, never indexed
            index, pos = hpack_integer(block, pos, 4)
        if not byte & 0x80:
            if index == 0:  # a literal name: skip it
                length, pos = hpack_integer(block, pos, 7)
                pos += length
            length, pos = hpack_integer(block, pos, 7)
            pos += length
        if index in PSEUDO:
            order.append(PSEUDO[index])
    return ",".join(order)


def read_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def h2_capture(conn):
    """Reads the client's connection preface and frames up to its first request's HEADERS."""
    conn.settimeout(10)  # a connection Safari opens ahead and never uses
    if read_exact(conn, 24) != b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":
        raise ConnectionError("no HTTP/2 preface")
    settings, window, priorities, headers_priority, block = [], 0, [], None, b""
    while True:
        length, kind, flags, stream = struct.unpack(">IBBI", b"\x00" + read_exact(conn, 9))
        stream &= 0x7FFFFFFF
        payload = read_exact(conn, length)
        if kind == 0x4 and not flags & 0x1:  # SETTINGS
            settings += [struct.unpack(">HI", payload[i:i + 6]) for i in range(0, len(payload), 6)]
        elif kind == 0x8 and stream == 0:  # WINDOW_UPDATE
            window = struct.unpack(">I", payload[:4])[0] & 0x7FFFFFFF
        elif kind == 0x2:  # PRIORITY
            dependency, weight = struct.unpack(">IB", payload[:5])
            priorities.append(f"{stream}:{dependency >> 31}:{dependency & 0x7FFFFFFF}:{weight + 1}")
        elif kind in (0x1, 0x9):  # HEADERS, CONTINUATION
            fragment = payload
            if kind == 0x1 and flags & 0x8:  # PADDED
                fragment = fragment[1:len(fragment) - fragment[0]]
            if kind == 0x1 and flags & 0x20:  # PRIORITY
                dependency, weight = struct.unpack(">IB", fragment[:5])
                headers_priority = f"{dependency >> 31}:{dependency & 0x7FFFFFFF}:{weight + 1}"
                fragment = fragment[5:]
            block += fragment
            if flags & 0x4:  # END_HEADERS
                break
    akamai = "|".join([";".join(f"{key}:{value}" for key, value in settings), str(window),
                       ",".join(priorities) or "0", pseudo_header_order(block)])
    return {"akamai": akamai, "headersPriority": headers_priority}


def h2_respond(conn, html):
    """SETTINGS, the ACK of the client's, and one 200 response on stream 1, then GOAWAY."""
    def frame(kind, flags, stream, payload=b""):
        return struct.pack(">I", len(payload))[1:] + struct.pack(">BBI", kind, flags, stream) + payload
    content_type = b"text/html; charset=utf-8"
    # :status 200 (static index 8); content-type, literal without indexing, name index 31.
    block = b"\x88" + b"\x0f\x10" + bytes([len(content_type)]) + content_type
    goaway = struct.pack(">II", 1, 0)
    conn.sendall(frame(0x4, 0, 0) + frame(0x4, 0x1, 0) + frame(0x1, 0x4, 1, block)
                 + frame(0x0, 0x1, 1, html) + frame(0x7, 0, 0, goaway))
    # Read what the client still sends (its ACK of our SETTINGS) until it closes: closing with
    # unread data resets the connection, and the client may then drop the response.
    conn.settimeout(3)
    try:
        while conn.recv(65536):
            pass
    except (OSError, ssl.SSLError):
        pass


# ---- The measurement page -------------------------------------------------------------------------

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>PB device reference</title></head>
<body style="font: 17px -apple-system, sans-serif; margin: 16px">
<p id="status">Measuring… keep this page in view.</p>
<div style="height: 3000px"></div>
<script>
const probe = function () {
__PROBE__
};
const sizes = () => ({
  inner: innerWidth + 'x' + innerHeight,
  outer: outerWidth + 'x' + outerHeight,
  screenPosition: screenX + ',' + screenY,
  visualViewport: window.visualViewport ? Math.round(visualViewport.width) + 'x' + Math.round(visualViewport.height) : 'none',
  documentClient: document.documentElement.clientWidth + 'x' + document.documentElement.clientHeight,
});
// MediaCapabilities and WebCodecs answer asynchronously: supported/smooth/powerEfficient, or why not.
const asyncCodecs = async () => {
  const video = (contentType) => ({ type: 'file', video: { contentType, width: 1920, height: 1080, bitrate: 8000000, framerate: 30 } });
  const configs = {
    h264: 'video/mp4; codecs="avc1.640028"', hevc: 'video/mp4; codecs="hvc1.1.6.L120.B0"',
    av1: 'video/mp4; codecs="av01.0.08M.08"', vp9: 'video/webm; codecs="vp09.00.40.08"',
  };
  const out = { decodingInfo: {}, videoDecoder: {} };
  for (const [name, type] of Object.entries(configs)) {
    try {
      const info = await navigator.mediaCapabilities.decodingInfo(video(type));
      out.decodingInfo[name] = [info.supported, info.smooth, info.powerEfficient].map((b) => (b ? 'y' : 'n')).join('');
    } catch (e) { out.decodingInfo[name] = 'error: ' + e.name; }
  }
  const codecs = { h264: 'avc1.640028', hevc: 'hvc1.1.6.L120.B0', av1: 'av01.0.08M.08', vp9: 'vp09.00.40.08', vp8: 'vp8' };
  for (const [name, codec] of Object.entries(codecs)) {
    try {
      const answer = await VideoDecoder.isConfigSupported({ codec, codedWidth: 1920, codedHeight: 1080 });
      out.videoDecoder[name] = answer.supported ? 'y' : 'n';
    } catch (e) { out.videoDecoder[name] = typeof VideoDecoder === 'undefined' ? 'absent' : 'error: ' + e.name; }
  }
  return out;
};
(async () => {
  const out = { atLoad: sizes() };
  try { out.probe = probe(); } catch (e) { out.probe = { error: String(e) }; }
  const media = (query) => matchMedia(query).matches;
  out.media = {
    resolution: [1, 2, 3].filter((r) => media('(resolution: ' + r + 'dppx)')),
    pointerCoarse: media('(pointer: coarse)'), pointerFine: media('(pointer: fine)'),
    hoverNone: media('(hover: none)'), portrait: media('(orientation: portrait)'),
    deviceWidth: [320, 375, 390, 393, 402, 414, 428, 430, 440, 744, 768, 810, 820, 834, 1024]
      .filter((w) => media('(device-width: ' + w + 'px)')),
  };
  out.codecs = await asyncCodecs();
  out.worker = await new Promise((resolve) => {
    const code = "postMessage([navigator.platform, navigator.hardwareConcurrency, navigator.userAgent, navigator.languages.join(',')].join('|'))";
    const worker = new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
    worker.onmessage = (e) => resolve(String(e.data));
    worker.onerror = () => resolve('error');
    setTimeout(() => resolve('timeout'), 3000);
  });
  window.scrollTo(0, 400);
  await new Promise((resolve) => setTimeout(resolve, 2000));
  out.afterScroll = sizes();
  const response = await fetch('result?name=' + encodeURIComponent(__NAME__), { method: 'POST', body: JSON.stringify(out) });
  document.getElementById('status').textContent = response.ok ? 'sent' : 'not sent: ' + response.status;
})();
</script></body></html>
"""

ENTRY = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>PB device reference</title></head><body style="font: 17px -apple-system, sans-serif; margin: 16px">
<p>TLS and HTTP/2 noted. Now the page measurements:</p>
<p><a id="next" href="#" style="font-size: 22px">Continue</a></p>
<p>Accept the certificate warning again if Safari asks, and keep that page in view until it reads "sent".</p>
<script>document.getElementById('next').href = 'https://' + location.hostname + ':__PORT__/';</script>
</body></html>
"""


def same_hashes(ja4_value, reference):
    """JA4's cipher and extension hashes, which a missing server name does not change."""
    return ja4_value.split("_")[1:] == reference.split("_")[1:]


def summary(name, result):
    kind = "ipad" if "ipad" in name.lower() else "iphone"
    declared = DECLARED[kind]
    probe = result.get("probe", {})
    screen = str(probe.get("screen", "?")).split("x")
    print(f"DEVICE-REFERENCE [{name}] UA {probe.get('ua')}")
    print(f"  screen {'x'.join(screen[:2])} (declared {declared['screen']}), pixel ratio "
          f"{screen[4] if len(screen) > 4 else '?'} (declared {declared['pixelRatio']})")
    print(f"  viewport at load {result.get('atLoad', {}).get('inner')}, after scrolling "
          f"{result.get('afterScroll', {}).get('inner')} (declared {declared['viewport']})")
    print(f"  outer {result.get('atLoad', {}).get('outer')}, screen position {result.get('atLoad', {}).get('screenPosition')}")
    print(f"  media {json.dumps(result.get('media'))}")
    print(f"  worker {result.get('worker')}")
    for key in ["MediaSource", "ManagedMediaSource", "Notification", "document.fullscreenEnabled",
                "Element.prototype.webkitRequestFullscreen", "PushManager", "ApplePaySession", "window.ontouchstart"]:
        print(f"  features.{key} = {probe.get('features', {}).get(key)}")
    print(f"  touch {probe.get('touch')}; shape {json.dumps(probe.get('touchShape'))[:600]}")
    print(f"  globals {len(str(probe.get('windowNames', '')).split(','))}")
    families = probe.get("fontFamilies") or {}
    print(f"  font families {families.get('present')}")
    print(f"  generic fonts {families.get('generics')}")
    print(f"  WebGL {json.dumps(probe.get('webgl'))[:600]}")
    print(f"  codecs {json.dumps(probe.get('codecs'))[:600]}")
    print(f"  async codecs {json.dumps(result.get('codecs'))}")
    network = result.get("network", {})
    for tls in network.get("tls", []):
        verdict = ("a resumed session: not the ClientHello a site first sees" if tls.get("resumed")
                   else "hashes as this Mac's WebKit" if same_hashes(tls["ja4"], MAC_WEBKIT["ja4"])
                   else "hashes differ from this Mac's WebKit")
        print(f"  TLS (port {tls.get('port')}) JA4 {tls['ja4']}, ALPN {','.join(tls.get('alpn', []))}: {verdict} "
              f"({MAC_WEBKIT['ja4']})")
    for h2 in network.get("h2", []):
        akamai = h2.get("akamai")
        print(f"  HTTP/2 {akamai}: {'as' if akamai == MAC_WEBKIT['akamai'] else 'differs from'} this Mac's WebKit "
              f"({MAC_WEBKIT['akamai']})")
    for error in network.get("errors", []):
        print(f"  network error {error}")
    if not network.get("tls"):
        print("  TLS: no ClientHello noted for the address that sent the result")


# ---- --compare ------------------------------------------------------------------------------------

def load(path):
    """A device reference, or a bare probe result (a surface the self-test wrote, safari_reference.py --out)."""
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    return data if "probe" in data else {"probe": data}


def text(value):
    """Values as JavaScript prints them, as the self-test writes them."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (list, dict)):
        return json.dumps(value, sort_keys=True)
    return "null" if value is None else str(value)


def flat(value, prefix=""):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            out.update(flat(item, f"{prefix}{key}."))
        return out
    return {prefix[:-1]: text(value)}


def difference(a, b, name_a, name_b):
    """For lists (globals, WebGL extensions, codecs): the items only one side has."""
    left, right = a.split(","), b.split(",")
    if min(len(left), len(right)) < 4:
        return None
    only_a, only_b = [x for x in left if x not in right], [x for x in right if x not in left]
    if not only_a and not only_b:
        return "  the same items, in another order"
    return f"  only in {name_a}: {','.join(only_a) or '-'}\n  only in {name_b}: {','.join(only_b) or '-'}"


def compare(path_a, path_b):
    left, right = flat(load(path_a)), flat(load(path_b))
    name_a, name_b = os.path.basename(path_a), os.path.basename(path_b)
    same, one_sided = 0, {name_a: 0, name_b: 0}
    for key in sorted(set(left) | set(right)):
        if key not in right or key not in left:
            one_sided[name_a if key in left else name_b] += 1
            continue
        a, b = left[key], right[key]
        if a == b:
            same += 1
            continue
        print(f"{key}:")
        print(difference(a, b, name_a, name_b) or f"  {name_a}: {a[:300]}\n  {name_b}: {b[:300]}")
    print(f"DEVICE-REFERENCE compare: {same} keys identical; keys only in one file: "
          + ", ".join(f"{name} {count}" for name, count in one_sided.items()))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", help="reference name, e.g. iphone-ios26, ipad-ipados26 or mac-safari")
    parser.add_argument("--port", type=int, default=8443, help="the TLS/HTTP/2 page; the measurement page is on the next port")
    parser.add_argument("--probe", default=PROBE)
    parser.add_argument("--compare", nargs=2, metavar="JSON", help="print where two references differ, and exit")
    args = parser.parse_args()
    if args.compare:
        return compare(*args.compare)
    if not args.name or not all(c.isalnum() or c in "-_." for c in args.name):
        parser.error("--name: letters, digits, '-', '_' and '.' only")

    with open(args.probe, encoding="utf-8") as handle:
        page = PAGE.replace("__PROBE__", handle.read()).replace("__NAME__", json.dumps(args.name)).encode()
    entry_page = ENTRY.replace("__PORT__", str(args.port + 1)).encode()
    os.makedirs(REFERENCE_DIR, exist_ok=True)
    address, name = lan_address(), bonjour_name()
    network = {}  # per client address: each distinct ClientHello and HTTP/2 preface it sent
    lock = threading.Lock()
    done = threading.Event()

    def note(client, key, value):
        with lock:
            seen = network.setdefault(client, {}).setdefault(key, [])
            if value not in seen:
                seen.append(value)

    def note_hello(sock, client, port):
        hello = parse_client_hello(peek_client_hello(sock))
        if hello:
            note(client, "tls", dict(ja4(hello), port=port))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(page)

        def do_POST(self):
            length = min(int(self.headers.get("Content-Length") or 0), 4 * 1024 * 1024)
            body = self.rfile.read(length)
            try:
                result = json.loads(body)
            except ValueError:
                self.send_response(400)
                self.end_headers()
                return
            with lock:
                result["network"] = json.loads(json.dumps(network.get(self.client_address[0], {})))
            path = os.path.join(REFERENCE_DIR, args.name + ".json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(result, handle, indent=1, sort_keys=True)
            self.send_response(204)
            self.end_headers()
            summary(args.name, result)
            print(f"DEVICE-REFERENCE written: {os.path.relpath(path, ROOT)}")
            done.set()

        def log_message(self, *_):
            pass

    def tls_context(cert, key, protocols):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        context.set_alpn_protocols(protocols)
        return context

    class PageServer(http.server.ThreadingHTTPServer):
        daemon_threads = True

        def finish_request(self, request, client_address):
            # In the request's thread: a client that stalls (or refuses the certificate, as Safari
            # does until the warning is accepted) holds up only itself.
            note_hello(request, client_address[0], args.port + 1)
            request.settimeout(30)
            conn = self.context.wrap_socket(request, server_side=True)
            try:
                self.RequestHandlerClass(conn, client_address, self)
            finally:
                conn.close()

        def handle_error(self, request, client_address):
            note(client_address[0], "errors", f"port {args.port + 1}: {sys.exc_info()[1]}")

    class EntryHandler(socketserver.BaseRequestHandler):
        def handle(self):
            sock, client = self.request, self.client_address[0]
            note_hello(sock, client, args.port)
            try:
                sock.settimeout(30)
                conn = self.server.context.wrap_socket(sock, server_side=True)
                if conn.selected_alpn_protocol() == "h2":
                    note(client, "h2", h2_capture(conn))
                    h2_respond(conn, entry_page)
                else:
                    conn.recv(65536)
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n"
                                 + f"Content-Length: {len(entry_page)}\r\n\r\n".encode() + entry_page)
                    note(client, "h2", {"akamai": "none: the browser did not offer h2"})
                conn.close()
            except (ssl.SSLError, ConnectionError, OSError, struct.error, IndexError) as error:
                note(client, "errors", f"port {args.port}: {error}")

    with tempfile.TemporaryDirectory(prefix="pb-device-reference-") as directory:
        cert, key = certificate(directory, address, name)
        socketserver.ThreadingTCPServer.allow_reuse_address = True
        entry = socketserver.ThreadingTCPServer(("0.0.0.0", args.port), EntryHandler)
        entry.daemon_threads = True
        entry.context = tls_context(cert, key, ["h2", "http/1.1"])
        pages = PageServer(("0.0.0.0", args.port + 1), Handler)
        pages.context = tls_context(cert, key, ["http/1.1"])
        for server in (entry, pages):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        if name:
            print(f"Open https://{name}:{args.port}/ in Safari on the device (accept the certificate warning).")
            print(f"If that name does not open, https://{address}:{args.port}/ — without a server name, JA4 reads "
                  "\"i\" and counts one extension less; its hashes still compare.")
        else:
            print(f"Open https://{address}:{args.port}/ in Safari on the device (accept the certificate warning).")
        try:
            done.wait()
        except KeyboardInterrupt:
            return 1
        finally:
            entry.shutdown()
            pages.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
