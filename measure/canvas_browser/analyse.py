#!/usr/bin/env python3
"""Reads the probe's lines (probe.swift) and says, against the formulas of
ios-measure/canvas-alpha/README.md and the engine's own put/get table:
  - TABLE: how many of the 65,536 (value, alpha) pairs the engine's put/get gives as the formulas;
  - per run: D1 (q2's PNG drawn back), D2 (the PNG's own bytes against getImageData), D4, D5, D7,
    D10, D6 (values the engine's own put/get never returns), the canvas hash and its stability.
Standard library only.

    python3 measure/canvas_browser/analyse.py build/cb/probe.txt
"""
import base64
import json
import struct
import sys
import zlib


def premul(v, a):
    return (v * a + 127) // 255


def unpremul(p, a):
    return (min(p, a) * 255 + (a >> 1)) // a


def png_rgba(data_url):
    raw = base64.b64decode(data_url.split(",", 1)[1])
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, width = 8, b"", None
    while pos < len(raw):
        length, kind = struct.unpack(">I4s", raw[pos:pos + 8])
        chunk = raw[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    if depth != 8 or colour not in (2, 6):
        return None, f"PNG depth {depth} colour type {colour}"
    channels = 4 if colour == 6 else 3
    stride = width * channels
    data = zlib.decompress(idat)
    out, previous = bytearray(), bytearray(stride)
    for y in range(height):
        kind = data[y * (stride + 1)]
        line = bytearray(data[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            corner = previous[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + left) & 255
            elif kind == 2:
                line[i] = (line[i] + up) & 255
            elif kind == 3:
                line[i] = (line[i] + ((left + up) >> 1)) & 255
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        previous = line
        out += line if channels == 4 else bytearray(b for x in range(width) for b in (*line[x * 3:x * 3 + 3], 255))
    return bytes(out), f"PNG {width}x{height} colour type {colour}"


def main():
    runs, table = {}, None
    for line in open(sys.argv[1], encoding="utf-8"):
        if line.startswith("CANVAS "):
            _, label, payload = line.rstrip("\n").split(" ", 2)
            runs[label] = json.loads(payload)
        elif not line.startswith("BROWSER"):
            print(line.rstrip())
    n = runs.get("N", {})
    if "table" in n:
        t = base64.b64decode(n["table"])
        table = {}
        mismatch, examples = 0, []
        for a in range(256):
            for v in range(256):
                i = (a * 256 + v) * 4
                sent = (v, (7 * v + a) & 255, 255 - v)
                for k in range(3):
                    expected = 0 if a == 0 else sent[k] if a == 255 else unpremul(premul(sent[k], a), a)
                    got = t[i + k]
                    table[(sent[k], a)] = got
                    if got != expected:
                        mismatch += 1
                        if len(examples) < 8:
                            examples.append(f"(v {sent[k]}, a {a}) engine {got} formula {expected}")
                if t[i + 3] != a:
                    mismatch += 1
                    if len(examples) < 8:
                        examples.append(f"alpha {a} read as {t[i + 3]}")
        print(f"TABLE engine put/get vs the formulas: {mismatch} of {256 * 256 * 4} values differ" + (f"; e.g. {examples}" if examples else ""))
    elif n:
        print(f"TABLE missing: {n.get('error')}")
    for label, r in runs.items():
        if "error" in r:
            print(f"RUN {label}: error {r['error']}")
            continue
        read = base64.b64decode(r["read"])
        decoded, note = png_rgba(r["png"])
        d2 = sum(1 for a, b in zip(decoded, read) if a != b) if decoded else note
        d6 = "no table"
        if table is not None:
            d6 = 0
            for i in range(0, len(read), 4):
                a = read[i + 3]
                if 0 < a < 255 and any(table.get((read[i + k], a), read[i + k]) != read[i + k] for k in range(3)):
                    d6 += 1
        print(f"RUN {label}: hash {r['hash']} stable {r['stable']} semi {r['semi']} | D1 {r['D1']} D2 {d2} D4 {r['D4']} D5 {r['D5']} D6 {d6} D7 {r['D7']} D10 {r['D10']} ({note})")


if __name__ == "__main__":
    main()
