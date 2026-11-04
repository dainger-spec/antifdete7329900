"""16-bit PNG for the film's float plates (tools/film/plates.mjs writes through it; post.py reads with it).

Pillow cannot hold 16-bit RGB (it reads a 48-bit PNG as 8-bit RGB), so this writes and reads the files itself
with numpy and zlib: RGB, 16 bits a channel, sRGB-encoded (the renderer's tonemapped output), one IDAT, every
row with the PNG "Up" filter, so reading back is one vectorised pass.

As a writer (plates.mjs keeps one running and streams frames to it):
    python3 -I tools/film/png16.py
  stdin, repeated: a line "<path> <w> <h> <channels>[ <preview.png>[ <coverage.png>]]\\n", then
  w * h * channels little-endian uint16 values, top row first (channels 3 = RGB, 4 = RGB + coverage). Writes
  <path> as 16-bit RGB PNG atomically (<path>.part, then rename); optionally an 8-bit preview of the same
  picture (rounded, no dither: for looking at, not for the film) and the coverage (alpha) as 8-bit grey.
  Prints "WROTE <path>" for each file.

As a module (post.py runs with python3 -I, which leaves the script's folder off sys.path, so load it by path):
    import importlib.util, pathlib
    spec = importlib.util.spec_from_file_location('png16', pathlib.Path(__file__).with_name('png16.py'))
    png16 = importlib.util.module_from_spec(spec); spec.loader.exec_module(png16)
    rgb = png16.read(path)          # (h, w, 3) uint16; / 65535 for float sRGB
    png16.write(path, rgb_uint16)   # (h, w, 3) uint16
"""
import os
import struct
import subprocess
import sys
import zlib

import numpy as np

SIG = b'\x89PNG\r\n\x1a\n'


def _chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)


def encode(rgb, level=4):
    """(h, w, 3) uint16 -> PNG bytes (16-bit RGB, Up filter)."""
    rgb = np.ascontiguousarray(rgb, dtype=np.uint16)
    h, w, c = rgb.shape
    assert c == 3
    rows = rgb.astype('>u2').view(np.uint8).reshape(h, w * 6)
    up = rows.copy()
    up[1:] -= rows[:-1]                                   # uint8 arithmetic wraps, as the filter wants
    body = np.empty((h, w * 6 + 1), np.uint8)
    body[:, 0] = 2
    body[:, 1:] = up
    ihdr = struct.pack('>IIBBBBB', w, h, 16, 2, 0, 0, 0)
    return SIG + _chunk(b'IHDR', ihdr) + _chunk(b'IDAT', zlib.compress(body.tobytes(), level)) + _chunk(b'IEND', b'')


def write(path, rgb, level=4):
    """Write atomically: <path>.part, then rename."""
    data = encode(rgb, level)
    tmp = str(path) + '.part'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)


def read(path):
    """A 16-bit RGB PNG -> (h, w, 3) uint16. Files from write() decode here directly; any other PNG goes through
    ffmpeg (rgb48le)."""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:8] != SIG:
        raise ValueError(f'{path}: not a PNG')
    pos, idat, ihdr = 8, [], None
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat.append(body)
        elif kind == b'IEND':
            break
        pos += 12 + n
    w, h, depth, ctype, _, _, interlace = ihdr
    if depth == 16 and ctype == 2 and interlace == 0:
        raw = np.frombuffer(zlib.decompress(b''.join(idat)), np.uint8).reshape(h, w * 6 + 1)
        filt = raw[:, 0]
        if np.all((filt == 2) | (filt == 0)):
            rows = raw[:, 1:].copy()
            if np.all(filt == 2):
                rows = np.cumsum(rows, axis=0, dtype=np.uint8)   # undo Up: a running sum, mod 256
            else:
                for y in range(1, h):
                    if filt[y] == 2:
                        rows[y] += rows[y - 1]
            return rows.view('>u2').reshape(h, w, 3).astype(np.uint16)
    out = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-'], check=True, capture_output=True).stdout
    return np.frombuffer(out, '<u2').reshape(h, w, 3).copy()


def _serve():
    from PIL import Image
    inp = sys.stdin.buffer
    while True:
        line = inp.readline()
        if not line:
            break
        parts = line.decode().split()
        path, w, h, ch = parts[0], int(parts[1]), int(parts[2]), int(parts[3])
        n = w * h * ch * 2
        buf = inp.read(n)
        if len(buf) != n:
            sys.exit(f'png16: short read for {path}')
        a = np.frombuffer(buf, '<u2').reshape(h, w, ch)
        write(path, a[:, :, :3])
        if len(parts) > 4:
            Image.fromarray(((a[:, :, :3].astype(np.float32) / 257.0) + 0.5).astype(np.uint8), 'RGB').save(parts[4])
        if len(parts) > 5 and ch == 4:
            Image.fromarray(((a[:, :, 3].astype(np.float32) / 257.0) + 0.5).astype(np.uint8), 'L').save(parts[5])
        print(f'WROTE {path}', flush=True)


if __name__ == '__main__':
    _serve()
