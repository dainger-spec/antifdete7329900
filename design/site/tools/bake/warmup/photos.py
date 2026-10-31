# Procedural "photographs" for the mock Swedish sites. They are only ever seen through heavy frosting,
# so what matters is believable tone and structure: skies, water, tree lines, city lights, people-shapes.
import sys, numpy as np
from PIL import Image, ImageFilter, ImageDraw

OUT = sys.argv[1]
rng = np.random.default_rng(7)

def grad(h, w, stops):
    """Vertical gradient through (pos, (r,g,b)) stops."""
    y = np.linspace(0, 1, h)[:, None]
    out = np.zeros((h, w, 3))
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        m = (y >= p0) & (y <= p1)
        t = np.clip((y - p0) / max(1e-6, p1 - p0), 0, 1)
        col = np.array(c0)[None, None, :] * (1 - t[..., None]) + np.array(c1)[None, None, :] * t[..., None]
        out = np.where(m[..., None], col, out)
    return out

def noise(h, w, scale, octaves=4):
    acc = np.zeros((h, w)); amp = 1; tot = 0
    for o in range(octaves):
        sh, sw = max(2, int(h / scale * 2 ** o)), max(2, int(w / scale * 2 ** o))
        n = rng.random((sh, sw))
        im = Image.fromarray((n * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
        acc += np.asarray(im) / 255 * amp; tot += amp; amp *= 0.5
    return acc / tot

def ridge(w, base, amp, scale):
    n = noise(1, w, scale, 5)[0] if False else None
    x = np.arange(w)
    y = base + amp * (np.sin(x / scale * 1.3) * 0.4 + np.sin(x / scale * 0.37 + 1) * 0.6)
    y += (noise(8, w, scale / 3, 4)[4] - 0.5) * amp * 1.2
    return y

def save(a, name):
    Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).save(f'{OUT}/{name}.png')

W, H = 960, 600

# 1. Lake at dusk: warm horizon, dark spruce line, still water
def lake():
    a = grad(H, W, [(0, (38, 52, 84)), (0.42, (176, 132, 112)), (0.52, (222, 168, 120)), (0.53, (60, 58, 62)), (1, (24, 28, 38))])
    tl = ridge(W, H * 0.47, 22, 40)
    spikes = (noise(4, W, 3, 2)[1] - 0.5) * 30
    yy = np.arange(H)[:, None]
    trees = (yy > (tl + spikes)[None, :] - 10) & (yy < H * 0.53)
    a[trees] = a[trees] * 0.12 + np.array([14, 18, 20]) * 0.88
    # reflection
    refl = (yy > H * 0.53)
    sky = a[::-1].copy()
    a = np.where(refl[..., None], a * 0.5 + sky * 0.35, a)
    a += (noise(H, W, 60) - 0.5)[..., None] * 18
    save(a, 'lake')

# 2. Old town at night: warm windows on dark facades
def town():
    a = grad(H, W, [(0, (18, 24, 40)), (0.5, (34, 36, 52)), (1, (20, 18, 22))])
    im = Image.fromarray(a.astype(np.uint8)); d = ImageDraw.Draw(im)
    x = 0
    while x < W:
        bw = int(rng.integers(70, 150)); top = int(rng.integers(120, 260))
        col = tuple(int(c) for c in rng.integers(40, 70, 3))
        d.rectangle([x, top, x + bw, H], fill=(col[0] + 10, col[1], col[2] - 5))
        for wy in range(top + 20, H - 60, 38):
            for wx in range(x + 12, x + bw - 16, 26):
                if rng.random() < 0.55:
                    c = (230, 180, 110) if rng.random() < 0.8 else (250, 220, 170)
                    d.rectangle([wx, wy, wx + 10, wy + 16], fill=c)
        x += bw + int(rng.integers(0, 6))
    d.rectangle([0, H - 70, W, H], fill=(28, 26, 30))
    a = np.asarray(im).astype(float)
    a += (noise(H, W, 50) - 0.5)[..., None] * 14
    save(a, 'town')

# 3. Autumn forest: ochre, rust, dark trunks
def forest():
    a = grad(H, W, [(0, (150, 140, 110)), (0.4, (160, 112, 60)), (1, (70, 56, 36))])
    n = noise(H, W, 30)
    a = a * (0.6 + 0.6 * n[..., None])
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)); d = ImageDraw.Draw(im)
    for _ in range(26):
        x = int(rng.integers(0, W)); w = int(rng.integers(6, 22))
        d.rectangle([x, 0, x + w, H], fill=(36, 30, 26))
    a = np.asarray(im).astype(float)
    save(a, 'forest')

# 4. Winter: pale field, grey sky, a dark figure
def winter():
    a = grad(H, W, [(0, (170, 182, 196)), (0.55, (205, 212, 220)), (0.56, (226, 230, 236)), (1, (200, 206, 214))])
    im = Image.fromarray(a.astype(np.uint8)); d = ImageDraw.Draw(im)
    d.ellipse([560, 260, 600, 300], fill=(60, 50, 48)); d.rectangle([555, 295, 607, 420], fill=(120, 40, 36))
    d.rectangle([560, 420, 600, 500], fill=(40, 40, 46))
    for x in range(0, W, 7):
        h = int(40 + 30 * np.sin(x / 31) + rng.integers(0, 30))
        d.line([x, 330 - h, x, 330], fill=(70, 80, 88), width=3)
    a = np.asarray(im).astype(float)
    save(a, 'winter')

# 5. Portrait: a person against a dark background
def portrait():
    a = grad(H, W, [(0, (40, 46, 56)), (1, (22, 24, 30))])
    im = Image.fromarray(a.astype(np.uint8)); d = ImageDraw.Draw(im)
    d.ellipse([360, 330, 640, 760], fill=(46, 58, 82))                       # shoulders, navy
    d.ellipse([410, 120, 560, 320], fill=(200, 156, 130))                     # face
    d.ellipse([400, 96, 572, 220], fill=(92, 70, 52))                         # hair
    a = np.asarray(im).astype(float)
    save(a, 'portrait')

# 6. Football: green pitch, players
def pitch():
    a = grad(H, W, [(0, (30, 36, 46)), (0.32, (60, 70, 80)), (0.33, (52, 110, 62)), (1, (40, 92, 50))])
    im = Image.fromarray(a.astype(np.uint8)); d = ImageDraw.Draw(im)
    for i in range(0, W, 120): d.rectangle([i, 200, i + 60, H], fill=(48, 104, 58))
    for (x, c) in [(260, (240, 240, 244)), (420, (230, 196, 40)), (520, (240, 240, 244)), (700, (230, 196, 40))]:
        d.ellipse([x, 270, x + 26, 296], fill=(190, 150, 120)); d.rectangle([x - 4, 296, x + 30, 360], fill=c); d.rectangle([x, 360, x + 26, 420], fill=(30, 40, 90))
    d.rectangle([0, 0, W, 190], fill=(46, 52, 64))
    a = np.asarray(im).astype(float) + (noise(H, W, 40) - 0.5)[..., None] * 16
    save(a, 'pitch')

# 7. News studio: deep blue set, a presenter
def studio():
    a = grad(H, W, [(0, (16, 30, 60)), (1, (8, 14, 30))])
    im = Image.fromarray(a.astype(np.uint8)); d = ImageDraw.Draw(im)
    for i in range(6): d.rectangle([60 + i * 150, 80, 160 + i * 150, 300], fill=(30 + i * 4, 60, 110))
    d.rectangle([0, 420, W, H], fill=(24, 30, 44))
    d.ellipse([430, 180, 530, 300], fill=(196, 150, 124)); d.ellipse([360, 290, 600, 560], fill=(30, 34, 40))
    a = np.asarray(im).astype(float)
    save(a, 'studio')

# 8. Sea: archipelago, grey-blue
def sea():
    a = grad(H, W, [(0, (120, 140, 162)), (0.48, (176, 188, 198)), (0.49, (70, 92, 112)), (1, (40, 58, 76))])
    yy = np.arange(H)[:, None]
    isl = ridge(W, H * 0.47, 10, 70)
    m = (yy > isl[None, :]) & (yy < H * 0.49) & ((np.arange(W) % 400) < 230)[None, :]
    a[m] = (40, 48, 44)
    a += (noise(H, W, 20) - 0.5)[..., None] * 20 * (yy / H)[..., None]
    save(a, 'sea')

# 9. Kitchen / interior: warm wood, white walls (classifieds)
def interior():
    a = grad(H, W, [(0, (226, 222, 214)), (0.6, (210, 204, 194)), (0.61, (150, 112, 76)), (1, (120, 88, 60))])
    im = Image.fromarray(a.astype(np.uint8)); d = ImageDraw.Draw(im)
    d.rectangle([300, 180, 620, 380], fill=(60, 70, 64)); d.rectangle([660, 120, 760, 380], fill=(236, 236, 232))
    a = np.asarray(im).astype(float)
    save(a, 'interior')

# 10. Politics: a crowd/podium in warm light
def podium():
    a = grad(H, W, [(0, (70, 60, 56)), (1, (30, 26, 26))])
    im = Image.fromarray(a.astype(np.uint8)); d = ImageDraw.Draw(im)
    d.rectangle([380, 340, 580, H], fill=(120, 96, 70))
    d.ellipse([440, 170, 520, 260], fill=(206, 166, 140)); d.ellipse([400, 250, 560, 420], fill=(36, 40, 56))
    for i in range(14): d.ellipse([i * 70, 480 + (i % 3) * 14, i * 70 + 60, 560 + (i % 3) * 14], fill=(50 + (i * 13) % 40, 44, 46))
    a = np.asarray(im).astype(float) + (noise(H, W, 50) - 0.5)[..., None] * 12
    save(a, 'podium')

for f in (lake, town, forest, winter, portrait, pitch, studio, sea, interior, podium): f()
print('ok')
