# Reeded (fluted) glass, baked. Each vertical reed is a small cylindrical lens: it shows a mirrored, squeezed
# sliver of the page behind it. The reeds bend light only sideways, so
#   - the page is blurred only along x (a little frost), and stays crisp along y: text lines, picture edges
#     and rules come through as sharp horizontal bands broken into slivers, which is what reads as glass;
#   - what a reed shows at a height depends only on the page at that height, so the page can scroll under
#     the glass by moving the baked picture while the reeds' light and shade (drawn in CSS) stay put.
# usage: python3 -I flute.py RAW_DIR OUT_DIR [S] [sigma_x]
import sys, os, math
import numpy as np
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
S = float(sys.argv[3]) if len(sys.argv) > 3 else 1.7        # how much page one reed gathers, in reeds
SX = float(sys.argv[4]) if len(sys.argv) > 4 else 0.85      # frost along x, in reed widths
os.makedirs(dst, exist_ok=True)
# tag: (output width, reeds across, quality)
CFG = {'d': (1600, 40, 74, 1800, 1200), 'm': (720, 12, 74, 2400, 350)}   # width, reeds, quality, max height, css width
only = sys.argv[5].split(',') if len(sys.argv) > 5 else ['google', 'afton', 'svt', 'dn']

def blur1d(a, sigma, axis):
    if sigma <= 0.05: return a
    r = max(1, int(math.ceil(sigma * 3)))
    k = np.exp(-(np.arange(-r, r + 1) ** 2) / (2 * sigma * sigma)); k /= k.sum()
    pad = [(0, 0)] * a.ndim; pad[axis] = (r, r)
    p = np.pad(a, pad, mode='edge')
    out = np.zeros_like(a)
    n = a.shape[axis]
    for i, kv in enumerate(k):
        sl = [slice(None)] * a.ndim; sl[axis] = slice(i, i + n)
        out += kv * p[tuple(sl)]
    return out

for name in only:
    for tag, (W, N, q, HMAX, CSSW) in CFG.items():
        im = Image.open(f'{src}/{name}-{tag}.png').convert('RGB')
        if im.size[0] != W:
            im = im.resize((W, round(im.size[1] * W / im.size[0])), Image.LANCZOS)
        if im.size[1] > HMAX: im = im.crop((0, 0, W, HMAX))         # a reader never gets further down
        a = (np.asarray(im).astype(np.float32) / 255) ** 2.2          # linear light
        w = W / N
        a = blur1d(a, SX * w, 1)                                     # frost along x only
        a = blur1d(a, 1.4 * W / CSSW, 0)                             # a slight softening along y (1.4 css px)
        x = np.arange(W) + 0.5
        k = np.floor(x / w); xc = (k + 0.5) * w
        u = (x - xc) / (w / 2)                                       # -1 … 1 across a reed
        # mirrored and squeezed; steeper toward the reed's edges (a round profile bends more there)
        g = np.sin(u * math.pi / 2) * 0.82 + u ** 3 * 0.18
        sx = np.clip(xc - (w / 2) * S * g, 0, W - 1.001)
        x0 = np.floor(sx).astype(int); f = (sx - x0)[None, :, None]
        out = a[:, x0] * (1 - f) + a[:, np.minimum(x0 + 1, W - 1)] * f
        # glass: a touch of its own light in the darks, a cool cast, whites kept luminous (≈ #E8EBEF)
        tint = np.array([0.80, 0.82, 0.85], np.float32)
        out = 0.012 + out * tint
        lum = out.mean(axis=2, keepdims=True)
        out = lum + (out - lum) * 1.12                                # colour kept alive
        out = np.clip(out, 0, 1) ** (1 / 2.2)
        res = Image.fromarray(np.clip(out * 255 + 0.5, 0, 255).astype(np.uint8))
        res.save(f'{dst}/{name}-{tag}.webp', quality=q, method=6)
        print(name, tag, res.size, os.path.getsize(f'{dst}/{name}-{tag}.webp'))
    # the light the page throws on the wall: its first screen, tiny
    im = Image.open(f'{src}/{name}-d.png').convert('RGB')
    top = im.crop((0, 0, im.size[0], round(im.size[0] * 0.47)))
    glow = top.resize((64, 28), Image.BOX)
    glow.save(f'{dst}/{name}-glow.webp', quality=80)
