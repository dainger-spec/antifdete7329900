# A macro shot of a display showing the product's code: every logical pixel is three vertical stripes
# (subpixels) in three of the brand's blues, unlit ones faintly visible, seen at a slight angle with a
# shallow depth of field and a vignette that falls to the page's black. Output: a WebP for the numbers scene.
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT = sys.argv[1]
W_OUT, H_OUT = int(sys.argv[2]), int(sys.argv[3])
CELL = int(sys.argv[4]) if len(sys.argv) > 4 else 12
SS = 4  # supersampling of the cell kernel

FS = int(sys.argv[8]) if len(sys.argv) > 8 else 11
FONT = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', FS)
LINES = [
    ('', 'cookies(profile) -> own; passwords(profile) -> own; history(profile) -> own'),
    ('  ', 'profile.store { exit: "DE"; lang: "de-DE"; tz: "Europe/Berlin"; proxy: socks5 }'),
    ('      ', 'vault.seal(aes-256-gcm, key: argon2id(master))'),
    ('    ', 'webkit.process(per: profile); window = safari'),
    ('        ', 'warmup(profile, sites: country(proxy)) -> cookies'),
    ('  ', 'tls.handshake == safari; headers.order == safari; http2 == safari'),
    ('    ', 'route(profile) = proxy; direct = closed; udp = closed; webrtc = closed'),
    ('  ', 'profile.ads { exit: "US"; lang: "en-US"; tz: "America/New_York"; proxy: https }'),
]
OFF = int(sys.argv[9]) if len(sys.argv) > 9 else 0

# The plane (in logical pixels) is wider and taller than what the camera sees, for the perspective.
GW = int(W_OUT * 1.25 / CELL) + 2
GH = int(H_OUT * 1.25 / CELL) + 2
LH = round(FS * 1.36)
img = Image.new('L', (GW, GH), 0)
d = ImageDraw.Draw(img)
y = round(-4 * FS / 11)
k = 0
while y < GH:
    ind, line = LINES[(k + OFF) % len(LINES)]
    x = round((-40 + (k * 17) % 31) * FS / 11)
    text = (ind + line + '    ' + line)
    d.text((x, y), text, font=FONT, fill=255)
    y += LH
    k += 1
lum = np.asarray(img, dtype=np.float32) / 255.0
# Text is slightly soft on a real panel; unlit pixels still catch some light.
lum = 0.075 + 0.925 * lum

# Cell kernel: three stripes with a black matrix between them and between rows, soft ends.
c = CELL * SS
yy, xx = np.mgrid[0:c, 0:c].astype(np.float32) + 0.5
sw = c / 3.0
kern = np.zeros((3, c, c), np.float32)
for s in range(3):
    cx = sw * s + sw / 2
    hx = sw * 0.36          # half width of a stripe
    hy = c * 0.40           # half height
    dx = np.abs(xx - cx) - hx
    dy = np.abs(yy - c / 2) - hy
    # rounded rectangle SDF
    r = sw * 0.26
    q = np.sqrt(np.maximum(dx + r, 0) ** 2 + np.maximum(dy + r, 0) ** 2) + np.minimum(np.maximum(dx + r, dy + r), 0) - r
    kern[s] = np.clip(0.5 - q / (SS * 0.9), 0, 1)
# downsample kernel to the cell
kern = kern.reshape(3, CELL, SS, CELL, SS).mean(axis=(2, 4))
# a little inner fall-off, like a lit LCD stripe
kern *= (0.82 + 0.18 * np.cos((np.arange(CELL)[:, None] / CELL - 0.5) * np.pi))[None]

TONES = np.array([[0.30, 0.46, 0.94], [0.55, 0.70, 1.00], [0.80, 0.87, 1.00]], np.float32)  # three blues
plane = np.zeros((GH * CELL, GW * CELL, 3), np.float32)
L = np.repeat(np.repeat(lum, CELL, axis=0), CELL, axis=1)
for s in range(3):
    K = np.tile(kern[s], (GH, GW))
    plane += (L * K)[..., None] * TONES[s][None, None]

# Bloom of lit stripes
pl = Image.fromarray(np.clip(plane * 255 / 1.6, 0, 255).astype(np.uint8))
bloom = np.asarray(pl.filter(ImageFilter.GaussianBlur(CELL * 0.9)), np.float32) / 255 * 1.6
plane = plane + 0.55 * bloom

# Perspective: the camera looks a little up the panel; the far (top) edge is narrower.
P = Image.fromarray(np.clip(plane * 255 / 2.2, 0, 255).astype(np.uint8))
pw, ph = P.size
def coeffs(src, dst):
    m = []
    for (x, y), (u, v) in zip(dst, src):
        m.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        m.append([0, 0, 0, x, y, 1, -v * x, -v * y])
    A = np.array(m, np.float64); B = np.array(src, np.float64).reshape(8)
    return np.linalg.solve(A, B).tolist()
ins = 0.13  # top inset as a share of width
src = [(pw * ins, ph * 0.02), (pw * (1 - ins), ph * 0.02), (pw * 0.98, ph * 0.98), (pw * 0.02, ph * 0.98)]
dst = [(0, 0), (W_OUT, 0), (W_OUT, H_OUT), (0, H_OUT)]
V = P.transform((W_OUT, H_OUT), Image.PERSPECTIVE, coeffs(src, dst), Image.BICUBIC)

# Depth of field: sharp along a band, softer above (farther) and below (nearer).
base = np.asarray(V, np.float32)
radii = [0, 2, 5, 10, 20]
stack = [base] + [np.asarray(V.filter(ImageFilter.GaussianBlur(r)), np.float32) for r in radii[1:]]
yv = np.arange(H_OUT, dtype=np.float32) / H_OUT
focus = float(sys.argv[5]) if len(sys.argv) > 5 else 0.6
dist = np.where(yv < focus, (focus - yv) / focus * 1.3, (yv - focus) / (1 - focus) * 1.0)
idx = np.clip(dist * (len(radii) - 1), 0, len(radii) - 1.001)
i0 = np.floor(idx).astype(int); f = (idx - i0)[:, None, None]
out = np.zeros_like(base)
S = np.stack(stack)  # n, H, W, 3
rows = np.arange(H_OUT)
out = S[i0, rows] * (1 - f) + S[i0 + 1, rows] * f

# Vignette to the page's black (#060709): an ellipse, softer at the sides, gone at top and bottom.
yy, xx = np.mgrid[0:H_OUT, 0:W_OUT].astype(np.float32)
nx = (xx / W_OUT - 0.5) / 0.56; ny = (yy / H_OUT - focus) / 0.7
r = np.sqrt(nx ** 2 + ny ** 2)
vig = np.clip(1 - (r - 0.25) / 0.75, 0, 1) ** 1.6
edge = np.clip(yy / (H_OUT * 0.16), 0, 1) * np.clip((H_OUT - yy) / (H_OUT * 0.10), 0, 1)
gain = float(sys.argv[6]) if len(sys.argv) > 6 else 0.9
fall = np.clip((yy / H_OUT) / focus, 0, 1) ** 3.0 * 0.94 + 0.06
vig = vig * fall
out = out * (vig * edge * gain)[..., None]
bg = np.array([6, 7, 9], np.float32)
out = bg + out * (1 - bg / 255)
Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(OUT, quality=int(sys.argv[7]) if len(sys.argv) > 7 else 80, method=6)
print('ok', OUT)
