# The light a lit window throws into a dark room: a Gaussian-blurred rounded rectangle (two widths: a close
# halo and a wide spill, the wide one a little lower), tapered to exactly 0 at the image border, white with
# alpha, dithered. Drawn as ONE stretched image (no 9-slice → no seams).
#   python3 glow2.py OUTDIR
import sys, numpy as np
from PIL import Image

def rrect(w, h, x, y, rw, rh, r):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    cx = np.clip(xx, x + r, x + rw - r); cy = np.clip(yy, y + r, y + rh - r)
    d = np.hypot(xx - cx, yy - cy)
    return np.clip(r + 0.5 - d, 0, 1)

def blur(a, sigma):
    h, w = a.shape
    fy = np.fft.fftfreq(h)[:, None]; fx = np.fft.fftfreq(w)[None, :]
    k = np.exp(-2 * (np.pi ** 2) * (sigma ** 2) * (fx ** 2 + fy ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * k))

def glow(win_w, win_h, top, side, bottom, radius, s1, s2, drop, scale, out):
    # work at full size, padded so the FFT blur does not wrap
    W, H = win_w + 2 * side, win_h + top + bottom
    pad = int(4 * s2)
    Wp, Hp = W + 2 * pad, H + 2 * pad
    a1 = rrect(Wp, Hp, pad + side, pad + top, win_w, win_h, radius)
    a2 = rrect(Wp, Hp, pad + side + 10, pad + top + drop, win_w - 20, win_h, radius)
    g = 0.58 * blur(a1, s1) + 0.42 * blur(a2, s2)
    g = g[pad:pad + H, pad:pad + W]
    g = np.clip(g / g.max(), 0, 1)
    # taper to 0 at the border (smoothstep over the outer band)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float64)
    def ss(e0, e1, x):
        t = np.clip((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)
    band = 0.32
    tx = ss(0, side * band, np.minimum(xx, W - 1 - xx))
    ty = ss(0, top * band, yy) * ss(0, bottom * band, H - 1 - yy)
    g = g * tx * ty
    # downscale (smooth content; the browser scales it back up)
    w2, h2 = int(round(W * scale)), int(round(H * scale))
    img = Image.fromarray((g * 65535).astype(np.uint16)).resize((w2, h2), Image.LANCZOS) if False else None
    from PIL import Image as I
    gi = I.fromarray(g.astype(np.float32), mode='F').resize((w2, h2), I.BILINEAR)
    g2 = np.asarray(gi, dtype=np.float64)
    rng = np.random.default_rng(7)
    noise = (rng.random(g2.shape) - rng.random(g2.shape)) * 2.0   # triangular, ±2 levels
    a = np.clip(np.round(g2 * 255 + noise * (g2 > 0.004)), 0, 255).astype(np.uint8)
    l = np.full_like(a, 255)
    I.fromarray(np.dstack([l, a]), mode='LA').save(out, optimize=True)
    print(out, W, H, '->', w2, h2)

out = sys.argv[1]
# Desktop / tablet: window 960×420, margins top 220, sides 280, bottom 340
glow(960, 420, 220, 280, 340, 18, 50, 120, 36, 0.5, f'{out}/glow.png')
# Phone: window 360×420, margins top 110, sides 130, bottom 170
glow(360, 420, 110, 130, 170, 14, 24, 56, 18, 0.5, f'{out}/glow-phone.png')
