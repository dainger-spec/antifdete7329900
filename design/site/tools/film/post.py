# The promo film v2 («Графит»): post. Puts the stage's DOM layer (capture.mjs, 4K RGBA on a transparent ground)
# into the rendered studio (the plates, video/.cache/plates/, 16-bit) and finishes each frame (spec v2 §2
# "Texture and post"). Everything in float32 linear light, in this order:
#   1. shutter-average the DOM subframes (premultiplied RGBA, 4K) — done as capture.mjs films them (--shutter);
#   2. shot optics on the DOM layers: S17 reeded glass (the page layer only), S18 depth of field from the plane's
#      matrix (per-pixel depth by ray-plane intersection, 8 blur bins);
#   3. the DOM over the plate (Lanczos ×2 to 4K where the plate is 1080p; the record's 2D push; PL-CARD
#      defocused, Gaussian σ 48 px at 4K); on display shots the plate's glass-only reflection added on top of
#      the screen content inside the display (the DOM's own coverage is the display mask);
#   4. Lanczos down to 1920 × 1080;
#   5. vignette × (1 − 0.16·r^2.2) (not on #000 frames);
#   6. grain: luma only, σ 1.2/255 in sRGB code values, blurred 0.6 px, a new seed every frame, half weight
#      below sRGB 6 and above 240;
#   7. triangular dither ±1 LSB, quantise: 8-bit PNG for H.264, and (--master) 16-bit PNG for the ProRes master.
# Until a plate is rendered, a procedural graphite cyc stands in for it (same targets: wall 11–12, horizon band
# 24–28, floor 14–20, R = G = B), so every shot can be composited and judged.
#
#   python3 -I tools/film/post.py ru                        # every captured frame → video/.cache/frames/ru/
#   python3 -I tools/film/post.py ru --frames 540-569       # some
#   python3 -I tools/film/post.py ru --still 9.2 --out x.png  # one frame, anywhere
#   options: --dom DIR (the DOM frames; default video/.cache/dom/<lang>), --master (16-bit frames too, for ProRes),
#            --jobs N (frames in parallel), --placeholder (ignore the plates), --force (redo finished frames)
#   python3 -I tools/film/post.py --shutter                 # (capture.mjs) average subframes from stdin
import io
import json
import os
import struct
import subprocess
import sys
import zlib

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.abspath(os.path.join(HERE, '..', '..'))
CACHE = os.path.join(SITE, 'video', '.cache')
W4, H4 = 3840, 2160
W1, H1 = 1920, 1080


# MARK: Colour

def to_lin(x):
    x = np.asarray(x, dtype=np.float32)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4).astype(np.float32)


def to_srgb(x):
    x = np.clip(np.asarray(x, dtype=np.float32), 0, None)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055).astype(np.float32)


# MARK: PNG in and out (16-bit through ffmpeg; Pillow would drop 16-bit RGB to 8)

def png_info(path):
    with open(path, 'rb') as fh:
        head = fh.read(33)
    w, h, depth, ctype = struct.unpack('>IIBB', head[16:26])
    return w, h, depth, ctype


def read_png(path):
    """float32 0…1, HxWxC (C = 3 or 4), whatever the bit depth."""
    w, h, depth, ctype = png_info(path)
    if depth == 16:
        ch = 4 if ctype in (4, 6) else 3
        fmt = 'rgba64le' if ch == 4 else 'rgb48le'
        raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', fmt, '-'], check=True, capture_output=True).stdout
        return (np.frombuffer(raw, dtype='<u2').reshape(h, w, ch).astype(np.float32) / 65535.0)
    im = Image.open(path)
    im = im.convert('RGBA' if im.mode in ('RGBA', 'LA', 'P') else 'RGB')
    return np.asarray(im, dtype=np.float32) / 255.0


def write_png16(path, a):
    """a: uint16 HxWxC (3 or 4). Written whole or not at all."""
    h, w, ch = a.shape
    be = a.astype('>u2').reshape(h, w * ch)
    raw = np.empty((h, 1 + w * ch * 2), dtype=np.uint8)
    raw[:, 0] = 0
    raw[:, 1:] = be.view(np.uint8).reshape(h, w * ch * 2)
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 16, 6 if ch == 4 else 2, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress(raw.tobytes(), 3)) + chunk(b'IEND', b'')
    with open(path + '.part', 'wb') as fh:
        fh.write(png)
    os.replace(path + '.part', path)


def write_png8(path, a):
    Image.fromarray(a, 'RGB').save(path + '.part.png', compress_level=3)
    os.replace(path + '.part.png', path)


# MARK: Filters (no scipy): Gaussian as three box blurs (cumulative sums), Lanczos through Pillow's 'F' images

def _box(a, r, axis):
    if r <= 0:
        return a
    n = a.shape[axis]
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    p = np.pad(a, pad, mode='edge')
    c = np.cumsum(p, axis=axis, dtype=np.float32)
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return (hi - lo) / (2 * r + 1)


def _boxes(sigma, n=3):
    wi = np.sqrt(12 * sigma * sigma / n + 1)
    wl = int(np.floor(wi))
    if wl % 2 == 0:
        wl -= 1
    wu = wl + 2
    m = round((12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4 * wl - 4))
    return [(wl if i < m else wu) // 2 for i in range(n)]


def _gauss_small(a, sigma, axis):
    r = max(1, int(np.ceil(3 * sigma)))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2).astype(np.float32)
    k /= k.sum()
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r, r)
    p = np.pad(a, pad, mode='edge')
    n = a.shape[axis]
    out = np.zeros_like(a)
    for i, w in enumerate(k):
        out += w * np.take(p, np.arange(i, i + n), axis=axis)
    return out


def blur(a, sx, sy=None):
    """Gaussian blur, σ in px along x and y (axis 1 and 0)."""
    sy = sx if sy is None else sy
    for axis, s in ((1, sx), (0, sy)):
        if s <= 0:
            continue
        if s < 2.5:
            a = _gauss_small(a, s, axis)
        else:
            for r in _boxes(s):
                a = _box(a, r, axis)
    return a


def resize(a, w, h, method=Image.LANCZOS):
    chans = [np.asarray(Image.fromarray(np.ascontiguousarray(a[:, :, c]), 'F').resize((w, h), method)) for c in range(a.shape[2])]
    return np.stack(chans, axis=2)


def push(a, s, ox, oy):
    """2D scale s about (ox, oy) (pixels of a), bicubic."""
    if abs(s - 1) < 1e-6:
        return a
    data = (1 / s, 0, ox - ox / s, 0, 1 / s, oy - oy / s)
    h, w = a.shape[:2]
    chans = [np.asarray(Image.fromarray(np.ascontiguousarray(a[:, :, c]), 'F').transform((w, h), Image.AFFINE, data, resample=Image.BICUBIC)) for c in range(a.shape[2])]
    return np.stack(chans, axis=2)


# MARK: Plates

_plate_cache = {}


def placeholder(pid):
    """The graphite cyc stand-in, linear RGB at 4K (sRGB targets: wall 11–12, horizon 24–28, floor 14–20)."""
    y = (np.arange(H4, dtype=np.float32) + 0.5) / H4
    x = (np.arange(W4, dtype=np.float32) + 0.5) / W4 - 0.5
    if pid == 'PL-FLOOR':
        v = 18.5 - 3.5 * y                                   # the floor from above: brighter towards the wall
        col = v[:, None] * (1 - 0.05 * (2 * x[None, :]) ** 2)
    else:
        hz = {'PL-CARD': 0.60, 'R1': 0.58, 'R2': 0.56, 'R3': 0.58, 'PL-W': 0.52, 'PL-D': 0.52}.get(pid, 0.6)
        band = 26.0
        v = np.where(y < hz, 11.5 + (band - 11.5) * np.exp(-((y - hz) / 0.11) ** 2), 17.0 + (band - 17.0) * np.exp(-((y - hz) / 0.09) ** 2))
        col = v[:, None] * (1 - 0.06 * (2 * x[None, :]) ** 2)
        if pid in ('PL-W', 'PL-D'):
            col = col * (0.42 if pid == 'PL-W' else 0.30)
    lin = to_lin(col / 255.0)
    return np.repeat(lin[:, :, None], 3, axis=2)


def plate(pid, frame, defocus=0, force_placeholder=False):
    """The plate's frame as linear RGB at 4K; (array, source) where source names the file or 'placeholder'."""
    key = (pid, frame, defocus, force_placeholder)
    if key in _plate_cache:
        return _plate_cache[key]
    src = 'placeholder'
    a = None
    meta_file = os.path.join(CACHE, 'plates', f'{pid}.json')
    png = os.path.join(CACHE, 'plates', pid, f'{max(0, frame):04d}.png')
    if not force_placeholder and os.path.exists(png):
        rgb = read_png(png)[:, :, :3]
        if rgb.shape[1] != W4 or rgb.shape[0] != H4:
            rgb = np.clip(resize(rgb, W4, H4), 0, 1)
        a = to_lin(rgb)
        src = os.path.relpath(png, SITE)
    if a is None:
        a = placeholder(pid)
    if defocus:
        dcache = os.path.join(CACHE, 'plates', f'{pid}.defocus{defocus}.npy')
        if src != 'placeholder' and os.path.exists(dcache) and os.path.getmtime(dcache) > os.path.getmtime(png):
            a = np.load(dcache).astype(np.float32)
        else:
            a = blur(a, defocus)
            if src != 'placeholder':
                np.save(dcache, a.astype(np.float16))
    if len(_plate_cache) > 6:
        _plate_cache.clear()
    _plate_cache[key] = (a, src)
    return a, src


# MARK: DOM layers

def dom_layer(path):
    """Premultiplied linear RGBA at 4K from a capture (straight-alpha sRGB PNG, 8 or 16 bit)."""
    a = read_png(path)
    if a.shape[2] == 3:
        a = np.concatenate([a, np.ones(a.shape[:2] + (1,), np.float32)], axis=2)
    if a.shape[1] != W4 or a.shape[0] != H4:
        a = np.clip(resize(a, W4, H4), 0, 1)
    al = a[:, :, 3:4]
    return np.concatenate([to_lin(a[:, :, :3]) * al, al], axis=2)


def reeded_glass(B, y0, y1):
    """S17: the page layer behind reeded glass. Spec values at 1080 scale, ×2 here at 4K."""
    k = W4 / W1
    B = blur(B, 2.5 * k)                                              # pre-blur σ 2.5
    pitch = 26 * k
    x = np.arange(W4, dtype=np.float32)
    u = (x % pitch) / pitch
    d = -11 * k * np.sin(np.pi * (u - 0.5))                          # horizontal offset per column
    sx = np.clip(x + d, 0, W4 - 1.001)
    x0 = np.floor(sx).astype(np.int32)
    w = (sx - x0)[None, :, None]
    B = B[:, x0, :] * (1 - w) + B[:, x0 + 1, :] * w                  # bilinear along x
    B = blur(B, 2 * k, 1 * k)                                         # in-rib blur σx 2, σy 1
    shade = np.ones(W4, np.float32)
    shade[(u >= 0.08) & (u < 0.14)] *= 1.07                          # the rib's highlight
    shade[u >= 0.90] *= 0.88                                          # and its shadow
    B = B * (shade * 0.82)[None, :, None]                             # neutral transmission 0.82
    B[:, :, 3] = np.clip(B[:, :, 3] / 0.82 / shade[None, :], 0, 1)    # coverage is not dimmed by the glass
    m = np.zeros((H4, 1, 1), np.float32)
    m[int(y0 * k):int(y1 * k)] = 1
    return B * m


def depth_of_field(D, dof):
    """S18: per-pixel depth by ray-plane intersection; CoC = coc·|1/z − 1/zf| / |1/zfar − 1/zf| in px of the
    4K DOM layer (the optics run before the downscale); `bins` Gaussian blurs of σ = CoC/2, each pixel
    interpolated between its two bins."""
    m = np.array(dof['m'], dtype=np.float64).reshape(4, 4).T          # DOMMatrix column-major → row-major
    P, (ox, oy) = dof['P'], dof['o']
    zf, zfar, cmax, nb = dof['zf'], dof['zfar'], dof['coc'], dof['bins']
    p0 = m @ np.array([0, 0, 0, 1.0])
    e1 = m @ np.array([1.0, 0, 0, 0])
    e2 = m @ np.array([0, 1.0, 0, 0])
    n = np.cross(e1[:3], e2[:3])
    C = np.array([ox, oy, P])
    ys, xs = np.mgrid[0:H1, 0:W1].astype(np.float64) + 0.5
    d = np.stack([xs - ox, ys - oy, -P * np.ones_like(xs)], axis=-1)
    s = (n @ (p0[:3] - C)) / (d @ n)
    z = s * P                                                        # depth along the camera axis
    den = abs(1 / zfar - 1 / zf) or 1e-9
    coc = np.clip(cmax * np.abs(1 / z - 1 / zf) / den, 0, cmax).astype(np.float32)
    coc4 = np.asarray(Image.fromarray(coc, 'F').resize((W4, H4), Image.BILINEAR))
    pos = coc4 / cmax * (nb - 1)
    out = np.zeros_like(D)
    # the bins cascade: each is blurred from the one before by the σ still missing (Gaussians add in quadrature),
    # so every pass is small and fast
    cur, cur_s = D, 0.0
    for b in range(nb):
        sigma4 = (cmax * b / (nb - 1)) / 2
        if sigma4 > cur_s + 1e-6:
            inc = (sigma4 * sigma4 - cur_s * cur_s) ** 0.5
            if inc > 0.05:
                cur = blur(cur, inc)
            cur_s = sigma4
        wgt = np.clip(1 - np.abs(pos - b), 0, 1)
        if wgt.any():
            out += cur * wgt[:, :, None]
    return out


# MARK: A frame

def compose(rec, dom_dir, placeholder_only=False):
    """The finished frame as sRGB float code values (0…255), 1920 × 1080 × 3, plus notes on what was used."""
    notes = []
    k = W4 / W1
    if rec.get('ground') == 'black' or not rec.get('plate'):
        base = np.zeros((H4, W4, 3), np.float32)
        notes.append('black')
    else:
        p = rec['plate']
        base, src = plate(p['id'], p.get('frame', 0), p.get('defocus', 0), placeholder_only)
        notes.append(f"{p['id']}#{p.get('frame', 0)}:{src}")
        s, ox, oy = rec.get('push', [1, 960, 540])
        base = push(base, s, ox * k, oy * k)
    files = rec.get('files') or {}
    out = base
    if 'behind' in files:
        Bh = dom_layer(os.path.join(dom_dir, files['behind']))
        g = rec.get('glass') or {'y0': 0, 'y1': H1}
        Bh = reeded_glass(Bh, g['y0'], g['y1'])
        out = Bh[:, :, :3] + out * (1 - Bh[:, :, 3:4])
    for layer in ('dom', 'front'):
        if layer not in files:
            continue
        D = dom_layer(os.path.join(dom_dir, files[layer]))
        if rec.get('dof'):
            D = depth_of_field(D, rec['dof'])
        al = D[:, :, 3:4]
        # the glass reflection only from a rendered plate (a placeholder has no glass: it would lift the screen)
        refl = float(rec.get('reflect') or 0) if rec.get('plate') and not notes[0].endswith('placeholder') else 0.0
        out = D[:, :, :3] + out * (1 - al) + (base * al * refl if refl > 0 else 0)
    img = resize(out, W1, H1)
    img = np.clip(img, 0, None)
    if rec.get('vignette', True) and rec.get('ground') != 'black':
        ys, xs = np.mgrid[0:H1, 0:W1].astype(np.float32)
        r = np.hypot(xs + 0.5 - W1 / 2, ys + 0.5 - H1 / 2) / np.hypot(W1 / 2, H1 / 2)
        img *= (1 - 0.16 * r ** 2.2)[:, :, None]
    srgb = to_srgb(img) * 255.0
    # grain: luma only
    rng = np.random.default_rng(int(rec['f']) * 7919 + 17)
    g = blur(rng.standard_normal((H1, W1)).astype(np.float32), 0.6)
    g *= 1.2 / (g.std() or 1)
    luma = srgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    wgt = np.where((luma < 6) | (luma > 240), 0.5, 1.0).astype(np.float32) * float(rec.get('grain', 1))
    srgb = srgb + (g * wgt)[:, :, None]
    return srgb, notes, rng


def finish8(srgb, rng):
    d = rng.triangular(-1, 0, 1, size=srgb.shape[:2]).astype(np.float32)
    return np.clip(np.rint(srgb + d[:, :, None]), 0, 255).astype(np.uint8)


def finish16(srgb, rng):
    d = rng.triangular(-1, 0, 1, size=srgb.shape[:2]).astype(np.float32)
    return np.clip(np.rint(srgb * 257.0 + d[:, :, None]), 0, 65535).astype(np.uint16)


# MARK: The shutter (capture.mjs streams a frame's subframes here)

def shutter():
    inp = sys.stdin.buffer
    while True:
        head = inp.readline()
        if not head:
            break
        file, n = head.decode().split()
        n = int(n)
        acc = None
        for _ in range(n):
            size = int(inp.readline())
            a = np.asarray(Image.open(io.BytesIO(inp.read(size))).convert('RGBA'), dtype=np.float32) / 255.0
            al = a[:, :, 3:4]
            pm = np.concatenate([to_lin(a[:, :, :3]) * al, al], axis=2)
            acc = pm if acc is None else acc + pm
        acc /= n
        al = acc[:, :, 3:4]
        rgb = np.where(al > 1e-6, acc[:, :, :3] / np.maximum(al, 1e-6), 0)
        straight = np.concatenate([to_srgb(np.clip(rgb, 0, 1)), np.clip(al, 0, 1)], axis=2)
        write_png16(file, np.rint(straight * 65535).astype(np.uint16))


# MARK: Main

def main():
    args = sys.argv[1:]
    if args and args[0] == '--shutter':
        return shutter()
    lang = args[0] if args and not args[0].startswith('--') else 'ru'
    def opt(k, d=None):
        return args[args.index(k) + 1] if k in args else d
    dom_dir = os.path.abspath(opt('--dom', os.path.join(CACHE, 'dom', lang)))
    ph = '--placeholder' in args
    master = '--master' in args
    if '--still' in args:
        f = round(float(opt('--still')) * 60)
        rec = json.load(open(os.path.join(dom_dir, f'{f:04d}.json')))
        srgb, notes, rng = compose(rec, dom_dir, ph)
        out = os.path.abspath(opt('--out', os.path.join(CACHE, 'stills-v2', f'{lang}-{f:04d}.png')))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        write_png8(out, finish8(srgb, rng))
        print(f'WROTE {out} (frame {f}, {rec["shot"]}; {", ".join(notes)})')
        return
    out_dir = os.path.abspath(opt('--out-dir', os.path.join(CACHE, 'frames', lang)))
    mdir = os.path.join(CACHE, 'master', lang)
    os.makedirs(out_dir, exist_ok=True)
    if master:
        os.makedirs(mdir, exist_ok=True)
    recs = sorted(x for x in os.listdir(dom_dir) if x.endswith('.json'))
    if '--frames' in args:
        a, b = (int(v) for v in opt('--frames').split('-'))
        recs = [x for x in recs if a <= int(x[:4]) <= b]
    def done(f, x):
        """A finished frame is newer than everything it is made of: its record, its DOM layers and its plate
        frame. (So v1's frames in the same folder, or a frame posted before its plate was rendered, are redone.)"""
        outs = [os.path.join(out_dir, f'{f:04d}.png')] + ([os.path.join(mdir, f'{f:04d}.png')] if master else [])
        if '--force' in args or not all(os.path.exists(o) for o in outs):
            return False
        rec = json.load(open(os.path.join(dom_dir, x)))
        deps = [os.path.join(dom_dir, x)] + [os.path.join(dom_dir, n) for n in (rec.get('files') or {}).values()]
        p = rec.get('plate')
        if p and not ph:
            deps.append(os.path.join(CACHE, 'plates', p['id'], f"{max(0, p.get('frame', 0)):04d}.png"))
        newest = max(os.path.getmtime(d) for d in deps if os.path.exists(d))
        return min(os.path.getmtime(o) for o in outs) >= newest
    todo = []
    for x in recs:
        f = int(x[:4])
        if done(f, x):
            continue
        todo.append((x, dom_dir, out_dir, mdir if master else None, ph))
    jobs = int(opt('--jobs', '1'))
    if jobs > 1:
        import multiprocessing as mp
        with mp.Pool(jobs) as pool:
            for line in pool.imap_unordered(one, todo):
                print(line, flush=True)
    else:
        for t in todo:
            print(one(t), flush=True)


def one(task):
    x, dom_dir, out_dir, mdir, ph = task
    f = int(x[:4])
    rec = json.load(open(os.path.join(dom_dir, x)))
    srgb, notes, rng = compose(rec, dom_dir, ph)
    write_png8(os.path.join(out_dir, f'{f:04d}.png'), finish8(srgb, rng))
    if mdir:
        write_png16(os.path.join(mdir, f'{f:04d}.png'), finish16(srgb, np.random.default_rng(f * 7919 + 18)))
    return f'frame {f} {rec["shot"]}: {", ".join(notes)}'


if __name__ == '__main__':
    main()
